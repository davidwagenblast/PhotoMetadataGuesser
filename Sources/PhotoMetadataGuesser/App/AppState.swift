import Foundation
import Observation
import Photos
import DateGuessCore

/// The app's single source of truth. Long-running work (scan, estimate, apply) runs in background
/// tasks and reports back here on the main actor.
@MainActor
@Observable
final class AppState {
    private let store = JSONStore.shared
    private let library = PhotoLibraryService.shared

    // MARK: Persistent state

    var settings: AppSettings {
        didSet {
            store.save(settings, to: "settings")
            if oldValue.allowExactMonth != settings.allowExactMonth { scheduleRecompute() }
        }
    }
    var scan: ScanSnapshot
    var groups: [PhotoGroup] { didSet { store.save(groups, to: "groups"); scheduleRecompute() } }
    var people: [PersonInfo] { didSet { store.save(people, to: "people"); scheduleRecompute() } }
    var analyses: [String: PhotoAnalysis]
    var decisions: [String: ReviewDecision] { didSet { scheduleDecisionSave() } }
    var journal: [ApplyBatch] { didSet { store.save(journal, to: "journal") } }

    // MARK: Session state

    var authorization: PHAuthorizationStatus
    var hasAPIKey: Bool
    var albums: [AlbumInfo] = []
    var undatedSorted: [UndatedPhoto] = []
    var estimates: [String: ComputedEstimate] = [:]

    var scanProgress: ScanProgress?
    var isScanning = false
    var estimationProgress: EstimationProgress?
    var isEstimating = false
    var applyProgress: (done: Int, total: Int)?
    var isApplying = false
    var banner: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var analysesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var decisionsSaveTask: Task<Void, Never>?

    init() {
        settings = store.load(AppSettings.self, from: "settings") ?? AppSettings()
        scan = store.load(ScanSnapshot.self, from: "scan") ?? ScanSnapshot()
        groups = store.load([PhotoGroup].self, from: "groups") ?? []
        people = store.load([PersonInfo].self, from: "people") ?? []
        analyses = store.load([String: PhotoAnalysis].self, from: "analyses") ?? [:]
        decisions = store.load([String: ReviewDecision].self, from: "decisions") ?? [:]
        journal = store.load([ApplyBatch].self, from: "journal") ?? []
        authorization = PhotoLibraryService.shared.authorizationStatus
        hasAPIKey = !(Keychain.readAPIKey() ?? "").isEmpty
        refreshUndatedList()
        recomputeEstimates()
        if isAuthorized { loadAlbums() }
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    // MARK: Authorization

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        if isAuthorized { loadAlbums() }
    }

    func loadAlbums() {
        Task.detached(priority: .utility) {
            let albums = PhotoLibraryService.shared.userAlbums()
            await MainActor.run { self.albums = albums }
        }
    }

    // MARK: Derived

    var appliedIDs: Set<String> {
        var ids = Set<String>()
        for batch in journal where !batch.undone { ids.formUnion(batch.entries.map(\.assetID)) }
        return ids
    }

    var ignoredIDs: Set<String> { Set(decisions.filter { $0.value.ignored }.map(\.key)) }

    func photo(_ id: String) -> UndatedPhoto? { scan.undated[id] }

    func groupFor(_ assetID: String) -> PhotoGroup? { groups.first { $0.assetIDs.contains(assetID) } }

    /// The estimate after the user's overrides.
    func effectiveEstimate(_ id: String) -> DateEstimate? {
        guard let base = estimates[id]?.estimate else { return nil }
        let d = decisions[id] ?? ReviewDecision()
        if d.overrideYear == nil && d.overrideSeason == nil { return base }
        return base.overridden(year: d.overrideYear, season: d.overrideSeason)
    }

    var pendingAnalysisIDs: [String] { undatedSorted.map(\.id).filter { analyses[$0] == nil } }
    var aiFailedIDs: [String] { undatedSorted.map(\.id).filter { analyses[$0]?.aiError != nil } }

    func refreshUndatedList() {
        let applied = appliedIDs
        undatedSorted = scan.undated.values
            .filter { !applied.contains($0.id) }
            .sorted { a, b in
                switch (a.libraryDate, b.libraryDate) {
                case let (x?, y?) where x != y: return x < y
                default: return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
                }
            }
    }

    // MARK: Scan

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        banner = nil
        scanProgress = ScanProgress(phase: "Starting…")
        let scanner = LibraryScanner(options: settings.scan, previous: scan, excludedIDs: appliedIDs.union(ignoredIDs))
        scanTask = Task {
            do {
                // `run` is nonisolated, so it executes off the main thread; awaiting it directly keeps cancellation working.
                let result = try await scanner.run { p in await MainActor.run { self.scanProgress = p } }
                self.scan = result
                self.store.save(result, to: "scan")
                self.refreshUndatedList()
                self.recomputeEstimates()
                self.banner = "Found \(result.undated.count.formatted()) photos that need a date out of \(result.totalAssets.formatted())."
            } catch is CancellationError {
                self.banner = "Scan stopped."
            } catch {
                self.banner = "Scan failed: \(error.localizedDescription)"
            }
            self.isScanning = false
            self.scanProgress = nil
        }
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Estimate

    /// - Parameter ids: photos to analyze; defaults to those not analyzed yet.
    func startEstimation(ids: [String]? = nil) {
        guard !isEstimating else { return }
        let targets = (ids ?? pendingAnalysisIDs).compactMap { scan.undated[$0] }
        guard !targets.isEmpty else { banner = "Nothing to analyze."; return }
        isEstimating = true
        banner = nil
        let engine = EstimationEngine(photos: targets, groups: groups, people: people, ai: settings.ai,
                                      apiKey: settings.ai.enabled ? Keychain.readAPIKey() : nil)
        estimationProgress = EstimationProgress(phase: "Starting…", total: targets.count)
        estimateTask = Task {
            await engine.run(
                progress: { p in await MainActor.run { self.estimationProgress = p } },
                deliver: { results in await MainActor.run { self.receive(results) } })
            self.isEstimating = false
            self.saveAnalysesNow()
            self.recomputeEstimates()
            if let p = self.estimationProgress {
                var text = "Estimated \(p.done.formatted()) photos."
                if p.aiFailures > 0 { text += " Claude couldn't analyze \(p.aiFailures) (on-device clues were used instead)." }
                self.banner = text
            }
        }
    }

    func cancelEstimation() { estimateTask?.cancel() }

    private func receive(_ results: [PhotoAnalysis]) {
        for r in results { analyses[r.assetID] = r }
        scheduleAnalysesSave()
        scheduleRecompute(delay: 1.5)
    }

    // MARK: Fusion

    func scheduleRecompute(delay: Double = 0.3) {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            recomputeEstimates()
        }
    }

    @ObservationIgnored private var recomputeGeneration = 0

    func recomputeEstimates() {
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let undated = scan.undated, analyses = self.analyses, groups = self.groups, people = self.people
        let exact = settings.allowExactMonth
        Task.detached(priority: .userInitiated) {
            let result = AppState.computeEstimates(undated: undated, analyses: analyses, groups: groups,
                                                   people: people, allowExactMonth: exact)
            await MainActor.run {
                if generation == self.recomputeGeneration { self.estimates = result }
            }
        }
    }

    nonisolated static func computeEstimates(undated: [String: UndatedPhoto], analyses: [String: PhotoAnalysis],
                                             groups: [PhotoGroup], people: [PersonInfo],
                                             allowExactMonth: Bool) -> [String: ComputedEstimate] {
        let options = EvidenceFusion.Options(allowExactMonth: allowExactMonth)
        var result: [String: ComputedEstimate] = [:]
        var grouped = Set<String>()

        for g in groups {
            let members = g.assetIDs.filter { undated[$0] != nil && analyses[$0] != nil && !grouped.contains($0) }
            guard !members.isEmpty else { continue }
            let groupEvidence = GroupClues.evidence(for: g, people: people)
            let fusion = members.map { id in
                GroupFusion.Member(assetID: id, evidence: analyses[id]!.localEvidence + analyses[id]!.aiEvidence)
            }
            let estimates = GroupFusion.estimates(members: fusion, groupEvidence: groupEvidence, kind: g.kind, options: options)
            let note = DateEvidence(source: .group, summary: members.count > 1
                ? "Combined with \(members.count - 1) other photo\(members.count == 2 ? "" : "s") in “\(g.name)” (\(g.kind == .sameEvent ? "same event" : "same era"))"
                : "In the group “\(g.name)”")
            for m in fusion {
                guard let e = estimates[m.assetID] else { continue }
                result[m.assetID] = ComputedEstimate(estimate: e, evidence: [note] + groupEvidence + m.evidence, groupName: g.name)
            }
            grouped.formUnion(members)
        }

        for (id, a) in analyses where undated[id] != nil && !grouped.contains(id) {
            let evidence = a.localEvidence + a.aiEvidence
            result[id] = ComputedEstimate(estimate: EvidenceFusion.estimate(from: evidence, options: options),
                                          evidence: evidence, groupName: nil)
        }
        return result
    }

    // MARK: Review decisions

    func decision(_ id: String) -> ReviewDecision { decisions[id] ?? ReviewDecision() }

    func setSelected(_ id: String, _ selected: Bool) {
        var d = decision(id)
        d.selected = selected
        decisions[id] = d
    }

    func setOverride(_ id: String, year: Int?, season: Season?) {
        var d = decision(id)
        d.overrideYear = year
        d.overrideSeason = season
        d.selected = true
        decisions[id] = d
    }

    func setIgnored(_ id: String, _ ignored: Bool) {
        var d = decision(id)
        d.ignored = ignored
        if ignored { d.selected = false }
        decisions[id] = d
    }

    func select(_ ids: [String], _ selected: Bool) {
        var copy = decisions
        for id in ids {
            var d = copy[id] ?? ReviewDecision()
            d.selected = selected && !d.ignored
            copy[id] = d
        }
        decisions = copy
    }

    var selectedForApply: [String] {
        undatedSorted.map(\.id).filter { id in
            let d = decision(id)
            return d.selected && !d.ignored && effectiveEstimate(id) != nil
        }
    }

    // MARK: Apply & undo

    func applySelected() {
        guard !isApplying else { return }
        let changes: [DateWriter.Change] = selectedForApply.compactMap { id in
            guard let date = effectiveEstimate(id)?.date() else { return nil }
            return DateWriter.Change(assetID: id, date: date)
        }
        guard !changes.isEmpty else { return }
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let batch = await DateWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            self.finishWrite(batch, verb: "Updated")
        }
    }

    func undo(_ batch: ApplyBatch) {
        guard !isApplying, !batch.undone else { return }
        isApplying = true
        applyProgress = (0, batch.entries.count)
        Task {
            let result = await DateWriter.undo(batch) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            if let idx = self.journal.firstIndex(where: { $0.id == batch.id }) {
                self.journal[idx].undone = true
            }
            self.isApplying = false
            self.applyProgress = nil
            self.refreshUndatedList()
            self.banner = "Restored the previous dates of \(result.entries.count.formatted()) photos"
                + (result.failures.isEmpty ? "." : " (\(result.failures.count) couldn't be restored).")
        }
    }

    private func finishWrite(_ batch: ApplyBatch, verb: String) {
        if !batch.entries.isEmpty { journal.insert(batch, at: 0) }
        var copy = decisions
        for entry in batch.entries { copy[entry.assetID]?.selected = false }
        decisions = copy
        isApplying = false
        applyProgress = nil
        refreshUndatedList()
        banner = "\(verb) \(batch.entries.count.formatted()) photos in your Photos library."
            + (batch.failures.isEmpty ? "" : " \(batch.failures.count) couldn't be changed.")
    }

    // MARK: Groups

    @discardableResult
    func createGroup(name: String, assetIDs: [String], kind: GroupKind = .sameEra) -> PhotoGroup {
        let ids = Set(assetIDs)
        // A photo belongs to one group at a time.
        for i in groups.indices { groups[i].assetIDs.removeAll { ids.contains($0) } }
        let group = PhotoGroup(name: name, kind: kind, assetIDs: assetIDs)
        groups.append(group)
        return group
    }

    func add(_ assetIDs: [String], to groupID: UUID) {
        let ids = Set(assetIDs)
        for i in groups.indices where groups[i].id != groupID { groups[i].assetIDs.removeAll { ids.contains($0) } }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let existing = Set(groups[idx].assetIDs)
        groups[idx].assetIDs += assetIDs.filter { !existing.contains($0) }
    }

    func remove(_ assetIDs: [String], from groupID: UUID) {
        let ids = Set(assetIDs)
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].assetIDs.removeAll { ids.contains($0) }
    }

    func groupSuggestions() -> [GroupSuggestion] {
        let alreadyGrouped = Set(groups.flatMap(\.assetIDs))
        let candidates = undatedSorted.filter { !alreadyGrouped.contains($0.id) }.map {
            GroupCandidate(assetID: $0.id, filename: $0.format.originalFilename, libraryDate: $0.libraryDate, albums: $0.albums)
        }
        return GroupSuggester.suggest(candidates)
    }

    // MARK: Settings

    func saveAPIKey(_ key: String) {
        Keychain.saveAPIKey(key)
        hasAPIKey = !(Keychain.readAPIKey() ?? "").isEmpty
    }

    // MARK: Saving

    private func scheduleAnalysesSave() {
        guard analysesSaveTask == nil else { return }
        analysesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.saveAnalysesNow()
        }
    }

    func saveAnalysesNow() {
        analysesSaveTask?.cancel()
        analysesSaveTask = nil
        store.save(analyses, to: "analyses")
    }

    private func scheduleDecisionSave() {
        decisionsSaveTask?.cancel()
        decisionsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.decisions, to: "decisions")
        }
    }

    func saveEverything() {
        store.save(analyses, to: "analyses")
        store.save(decisions, to: "decisions")
        store.flush()
    }
}
