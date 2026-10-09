import CoreGraphics
import Foundation
import Photos
import DateGuessCore

struct EstimationProgress: Equatable {
    var phase = ""
    var done = 0
    var total = 0
    var aiFailures = 0
    var usage = AIUsage()

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Gathers clues for each undated photo: on-device clues always, plus Claude's visual analysis when enabled.
/// Photos the user grouped are sent to Claude together so it can judge them consistently.
struct EstimationEngine {
    var photos: [UndatedPhoto]
    var groups: [PhotoGroup]
    var people: [PersonInfo]
    var ai: AISettings
    var apiKey: String?

    private var library: PhotoLibraryService { .shared }

    struct WorkUnit {
        var photos: [UndatedPhoto]
        var group: PhotoGroup?
    }

    func run(progress: @escaping @Sendable (EstimationProgress) async -> Void,
             deliver: @escaping @Sendable ([PhotoAnalysis]) async -> Void) async {
        let useAI = ai.enabled && !(apiKey ?? "").isEmpty
        let units = makeUnits(batchSize: useAI ? max(1, ai.photosPerRequest) : 8)
        var state = EstimationProgress(phase: useAI ? "Preparing reference photos…" : "Analyzing photos…", total: photos.count)
        await progress(state)

        let client = useAI ? ClaudeClient(apiKey: apiKey ?? "", settings: ai) : nil
        var references: [AIReferenceImage] = []
        if useAI { references = await referenceImages() }
        state.phase = useAI ? "Analyzing photos with on-device checks and Claude…" : "Analyzing photos on this Mac…"
        await progress(state)

        let width = useAI ? max(1, ai.concurrentRequests) : 4
        await withTaskGroup(of: ([PhotoAnalysis], AIUsage, Bool).self) { group in
            var iterator = units.makeIterator()
            for _ in 0..<width {
                guard let unit = iterator.next() else { break }
                group.addTask { await self.process(unit, client: client, references: references) }
            }
            while let (analyses, usage, aiFailed) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                await deliver(analyses)
                state.done += analyses.count
                state.usage.add(usage)
                if aiFailed { state.aiFailures += analyses.count }
                await progress(state)
                if let next = iterator.next() {
                    group.addTask { await self.process(next, client: client, references: references) }
                }
            }
        }
        state.phase = Task.isCancelled ? "Stopped" : "Done"
        await progress(state)
    }

    func makeUnits(batchSize: Int) -> [WorkUnit] {
        var remaining = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var units: [WorkUnit] = []
        for g in groups {
            let members = g.assetIDs.compactMap { remaining.removeValue(forKey: $0) }
            for chunk in members.chunked(into: batchSize) { units.append(WorkUnit(photos: chunk, group: g)) }
        }
        // Neighbors by filename tend to be related scans; keep them together for consistent judgement.
        let rest = remaining.values.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        for chunk in rest.chunked(into: batchSize) { units.append(WorkUnit(photos: chunk, group: nil)) }
        return units
    }

    /// Analyzes one unit: on-device clues for each photo, then one Claude request for the whole unit.
    func process(_ unit: WorkUnit, client: ClaudeClient?, references: [AIReferenceImage]) async -> ([PhotoAnalysis], AIUsage, Bool) {
        let edge = max(ai.imageMaxEdge, 512)
        var analyses: [PhotoAnalysis] = []
        var inputs: [AIPhotoInput] = []
        var promptIDs: [String: String] = [:]

        for (i, photo) in unit.photos.enumerated() {
            if Task.isCancelled { break }
            var local = LocalClues.evidence(for: photo)
            var observations: [String] = []
            if let asset = library.asset(for: photo.id), let image = await library.analysisImage(for: asset, maxEdge: edge) {
                if let stats = ImageAnalyzer.statistics(image) {
                    local += VisualClues.evidence(from: stats)
                    observations = VisualClues.observations(from: stats)
                }
                local += SceneClues.evidence(fromLabels: ImageAnalyzer.sceneLabels(image))
                if client != nil, let jpeg = ImageAnalyzer.jpegData(image, maxEdge: ai.imageMaxEdge) {
                    let promptID = "P\(i + 1)"
                    promptIDs[promptID] = photo.id
                    inputs.append(AIPhotoInput(promptID: promptID, context: promptContext(photo, observations: observations), jpegData: jpeg))
                }
            }
            analyses.append(PhotoAnalysis(assetID: photo.id, localEvidence: local, aiEvidence: [], aiError: nil,
                                          usedAI: false, analyzedAt: Date()))
        }

        guard let client, !inputs.isEmpty, !Task.isCancelled else { return (analyses, AIUsage(), false) }
        do {
            let (results, usage) = try await client.analyze(photos: inputs, references: references,
                                                            groupContext: unit.group.map { groupContext($0) })
            for (promptID, assetID) in promptIDs {
                guard let idx = analyses.firstIndex(where: { $0.assetID == assetID }) else { continue }
                if let r = results[promptID] {
                    let photo = unit.photos.first { $0.id == assetID }
                    analyses[idx].aiEvidence = AIEvidenceMapper.evidence(from: r, people: people, libraryDate: photo?.libraryDate)
                    analyses[idx].usedAI = true
                } else {
                    analyses[idx].aiError = "Claude didn't return a result for this photo"
                }
            }
            return (analyses, usage, false)
        } catch {
            let message = error.localizedDescription
            for i in analyses.indices { analyses[i].aiError = message }
            return (analyses, AIUsage(), true)
        }
    }

    // MARK: Prompt context

    func promptContext(_ photo: UndatedPhoto, observations: [String]) -> String {
        var lines: [String] = []
        lines.append("Filename: \(photo.filename)")
        if !photo.albums.isEmpty { lines.append("Albums: \(photo.albums.joined(separator: "; "))") }
        if let d = photo.libraryDate {
            lines.append("Date currently in the library (often the scan/import date, NOT when it was taken): \(Self.dayFormatter.string(from: d))")
        }
        lines.append("Why it's considered undated: \(photo.reason.explanation)")
        let format = photo.format.promptDescription
        if !format.isEmpty { lines.append("File: \(format)") }
        if !observations.isEmpty { lines.append("On-device look: \(observations.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    func groupContext(_ g: PhotoGroup) -> String {
        var text = "The user grouped the following photos together as “\(g.name)”. "
        switch g.kind {
        case .sameEvent: text += "They are from the same event, so they should share one date. "
        case .sameEra: text += "They are from roughly the same period; date each one but keep them consistent. "
        }
        if !g.hint.isEmpty { text += "The user's notes: \(g.hint). " }
        if let from = g.yearFrom, let to = g.yearTo { text += "The user believes they're from \(from)–\(to). " }
        else if let from = g.yearFrom { text += "The user believes they're from \(from) or later. " }
        else if let to = g.yearTo { text += "The user believes they're from \(to) or earlier. " }
        if let season = g.season { text += "Season: \(season.displayName). " }
        let names = g.people.compactMap { hint -> String? in
            guard let p = people.first(where: { $0.id == hint.personID }) else { return nil }
            return hint.approximateAge.map { "\(p.name) (about \($0) years old)" } ?? p.name
        }
        if !names.isEmpty { text += "People the user says appear in these photos: \(names.joined(separator: ", ")). " }
        return text
    }

    // MARK: References

    /// Up to two face crops per person, labeled with their age in that photo when its date is trustworthy.
    func referenceImages() async -> [AIReferenceImage] {
        var out: [AIReferenceImage] = []
        let undatedIDs = Set(photos.map(\.id))
        for person in people {
            for id in person.referenceAssetIDs.prefix(2) {
                guard let asset = library.asset(for: id), let image = await library.analysisImage(for: asset, maxEdge: 1024) else { continue }
                let face = ImageAnalyzer.largestFaceCrop(image)
                guard let jpeg = ImageAnalyzer.jpegData(face, maxEdge: 512) else { continue }
                var note = ""
                if !undatedIDs.contains(id), let date = asset.creationDate {
                    let year = Calendar.current.component(.year, from: date)
                    let age = year - person.birthYear
                    if age >= 0 && age < 110 { note = "about \(age) years old in this photo (\(year))" }
                }
                out.append(AIReferenceImage(personName: person.name, note: note, jpegData: jpeg))
            }
        }
        return out
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Clues that need no image: filename, albums and file format.
enum LocalClues {
    static func evidence(for photo: UndatedPhoto) -> [DateEvidence] {
        var out: [DateEvidence] = []
        if let name = photo.format.originalFilename { out += TextClues.evidence(fromFilename: name) }
        for album in photo.albums { out += TextClues.evidence(fromAlbumName: album) }
        out += FormatClues.evidence(for: photo.format)
        return out
    }
}

/// Clues the user gave for a group, applied to every photo in it.
enum GroupClues {
    static func evidence(for group: PhotoGroup, people: [PersonInfo]) -> [DateEvidence] {
        var out = TextClues.evidence(fromHint: group.name) + TextClues.evidence(fromHint: group.hint)
        if group.yearFrom != nil || group.yearTo != nil {
            out.append(DateEvidence(source: .groupHint, summary: "You said these are from \(group.yearRangeText)",
                                    yearLow: group.yearFrom, yearHigh: group.yearTo, weight: 0.9))
        }
        if let season = group.season {
            out.append(DateEvidence(source: .groupHint, summary: "You said these are from \(season.displayName.lowercased())",
                                    season: season, seasonWeight: 1))
        }
        for hint in group.people {
            guard let person = people.first(where: { $0.id == hint.personID }) else { continue }
            out.append(PeopleClues.presence(of: person))
            if let age = hint.approximateAge {
                out.append(PeopleClues.age(of: person, ageLow: age, ageHigh: age, matchConfidence: 1, userProvided: true))
            }
        }
        return out
    }
}

extension PhotoGroup {
    var yearRangeText: String {
        switch (yearFrom, yearTo) {
        case let (a?, b?): return "\(a)–\(b)"
        case let (a?, nil): return "\(a) or later"
        case let (nil, b?): return "\(b) or earlier"
        default: return ""
        }
    }
}
