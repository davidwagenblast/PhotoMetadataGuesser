import SwiftUI
import DateGuessCore

struct ReviewView: View {
    @Environment(AppState.self) private var state

    var _filter = State<Filter>(initialValue: .toReview)
    private var filter: Filter { get { _filter.wrappedValue } nonmutating set { _filter.wrappedValue = newValue } }
    var _sort = State<Sort>(initialValue: .library)
    private var sort: Sort { get { _sort.wrappedValue } nonmutating set { _sort.wrappedValue = newValue } }
    var _groupFilter = State<UUID?>(initialValue: nil)
    private var groupFilter: UUID? { get { _groupFilter.wrappedValue } nonmutating set { _groupFilter.wrappedValue = newValue } }
    var _search = State<String>(initialValue: "")
    private var search: String { get { _search.wrappedValue } nonmutating set { _search.wrappedValue = newValue } }
    var _detailID = State<String?>(initialValue: nil)
    private var detailID: String? { get { _detailID.wrappedValue } nonmutating set { _detailID.wrappedValue = newValue } }
    var _confirmApply = State<Bool>(initialValue: false)
    private var confirmApply: Bool { get { _confirmApply.wrappedValue } nonmutating set { _confirmApply.wrappedValue = newValue } }

    enum Filter: String, CaseIterable, Identifiable {
        case toReview = "To review"
        case selected = "Checked"
        case high = "High confidence"
        case medium = "Medium"
        case low = "Low"
        case ignored = "Keeping current date"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case library = "Library order"
        case confidence = "Most confident first"
        case year = "Estimated year"
        case filename = "Filename"
        var id: String { rawValue }
    }

    private var visibleIDs: [String] {
        var items = state.undatedSorted.filter { state.estimates[$0.id] != nil }
        if let g = groupFilter, let group = state.groups.first(where: { $0.id == g }) {
            let ids = Set(group.assetIDs)
            items = items.filter { ids.contains($0.id) }
        }
        if !search.isEmpty {
            items = items.filter { $0.filename.localizedCaseInsensitiveContains(search) || $0.albums.contains { $0.localizedCaseInsensitiveContains(search) } }
        }
        items = items.filter { photo in
            let d = state.decision(photo.id)
            let level = state.effectiveEstimate(photo.id)?.confidenceLevel
            switch filter {
            case .toReview: return !d.ignored
            case .selected: return d.selected && !d.ignored
            case .high: return !d.ignored && level == .high
            case .medium: return !d.ignored && level == .medium
            case .low: return !d.ignored && level == .low
            case .ignored: return d.ignored
            }
        }
        switch sort {
        case .library: break
        case .confidence:
            items.sort { (state.estimates[$0.id]?.estimate.confidence ?? 0) > (state.estimates[$1.id]?.estimate.confidence ?? 0) }
        case .year:
            items.sort { (state.effectiveEstimate($0.id)?.year ?? 0) < (state.effectiveEstimate($1.id)?.year ?? 0) }
        case .filename:
            items.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
        return items.map(\.id)
    }

    var body: some View {
        let ids = visibleIDs
        let selectedCount = state.selectedForApply.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(step: 5, title: "Review and apply",
                           subtitle: "Check the photos whose guesses look right. Adjust the year or season if you know better. When you click Apply, only the checked photos get their new date.",
                           systemImage: "checkmark.circle")
                toolbar(ids)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(ids, id: \.self) { id in
                        ReviewCard(assetID: id, onOpen: { detailID = id })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 90)
            }
            .overlay {
                if state.estimates.isEmpty {
                    ContentUnavailableView("Nothing to review yet", systemImage: "sparkles",
                                           description: Text("Scan your library and estimate dates first."))
                } else if ids.isEmpty {
                    ContentUnavailableView("No photos match", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Try a different filter."))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { applyBar(selectedCount) }
        .sheet(item: Binding(get: { detailID.map(IdentifiedString.init) }, set: { detailID = $0?.id })) { item in
            PhotoDetailSheet(assetID: item.id)
        }
        .alert("Apply \(selectedCount.formatted()) new dates?", isPresented: _confirmApply.projectedValue) {
            Button("Apply Dates") { state.applySelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos will update each photo’s date the same way Image ▸ Adjust Date and Time does. The photos themselves aren’t replaced, and their other details (places, people, albums, edits) stay the same. You can undo this from History.")
        }
    }

    /// Filters on one row when there's room, two rows when the window is narrow.
    private func toolbar(_ ids: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                filterControls
                searchField
                Spacer(minLength: 8)
                checkMenu(ids)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    filterControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    searchField
                    Spacer(minLength: 8)
                    checkMenu(ids)
                }
            }
        }
    }

    @ViewBuilder private var filterControls: some View {
        Picker("Show", selection: _filter.projectedValue) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
        Picker("Group", selection: _groupFilter.projectedValue) {
            Text("All photos").tag(UUID?.none)
            ForEach(state.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
        }
        .frame(maxWidth: 200)
        Picker("Sort", selection: _sort.projectedValue) {
            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }

    private var searchField: some View {
        TextField("Search", text: _search.projectedValue)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, maxWidth: 200)
    }

    private func checkMenu(_ ids: [String]) -> some View {
        Menu("Check…") {
            Button("Check all \(ids.count.formatted()) shown") { state.select(ids, true) }
            Button("Check shown with high confidence") {
                state.select(ids.filter { state.effectiveEstimate($0)?.confidenceLevel == .high }, true)
            }
            Button("Check shown with medium or high confidence") {
                state.select(ids.filter { state.effectiveEstimate($0)?.confidenceLevel != .low }, true)
            }
            Divider()
            Button("Uncheck all shown") { state.select(ids, false) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func applyBar(_ selectedCount: Int) -> some View {
        HStack(spacing: 14) {
            if let p = state.applyProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .frame(maxWidth: 220)
                Text("Updating \(p.done.formatted()) of \(p.total.formatted())…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(selectedCount == 0 ? "Check the photos you want to update" : "\(selectedCount.formatted()) photos checked")
                    .fontWeight(.medium)
            }
            Spacer()
            Button {
                confirmApply = true
            } label: {
                Label("Apply \(selectedCount.formatted()) Dates", systemImage: "calendar.badge.checkmark")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedCount == 0 || state.isApplying)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

struct IdentifiedString: Identifiable {
    var id: String
}

struct ReviewCard: View {
    @Environment(AppState.self) private var state
    var assetID: String
    var onOpen: () -> Void
    var _showWhy = State<Bool>(initialValue: false)
    private var showWhy: Bool { get { _showWhy.wrappedValue } nonmutating set { _showWhy.wrappedValue = newValue } }

    var body: some View {
        if let computed = state.estimates[assetID], let estimate = state.effectiveEstimate(assetID), let photo = state.photo(assetID) {
            let decision = state.decision(assetID)
            let overridden = decision.overrideYear != nil || decision.overrideSeason != nil
            VStack(alignment: .leading, spacing: 8) {
                AssetThumbnail(assetID: assetID, side: 250, height: 180)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        Toggle("", isOn: Binding(get: { decision.selected }, set: { state.setSelected(assetID, $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .disabled(decision.ignored)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let g = computed.groupName {
                            Label(g, systemImage: "square.stack.3d.up")
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                    .onTapGesture(count: 2, perform: onOpen)

                HStack(spacing: 6) {
                    SeasonIcon(season: estimate.season)
                    Text(estimate.displayString)
                        .font(.headline)
                    if overridden {
                        Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary).help("You changed this guess")
                    }
                    Spacer()
                    ConfidenceBadge(estimate: computed.estimate)
                }
                Text(subtitle(computed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Now: \(photo.libraryDate?.shortDay ?? "no date") · \(photo.filename)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Stepper(value: Binding(
                        get: { estimate.year },
                        set: { state.setOverride(assetID, year: $0, season: decision.overrideSeason) }),
                        in: YearBounds.earliestPhotoYear...YearBounds.currentYear()) {
                        Text(String(estimate.year)).monospacedDigit()
                    }
                    .fixedSize()
                    Menu {
                        ForEach(Season.allCases) { s in
                            Button {
                                state.setOverride(assetID, year: decision.overrideYear, season: s)
                            } label: {
                                Label("\(s.displayName) (\(DateEstimate.monthNames[s.representativeMonth - 1]))", systemImage: s.symbolName)
                            }
                        }
                        if overridden {
                            Divider()
                            Button("Use the original guess") { state.setOverride(assetID, year: nil, season: nil) }
                        }
                    } label: {
                        Text(estimate.season.displayName)
                    }
                    .fixedSize()
                    Spacer()
                    Button("Why?") { showWhy = true }
                        .popover(isPresented: _showWhy.projectedValue, arrowEdge: .bottom) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Why \(estimate.displayString)?").font(.headline)
                                    Text("Most likely \(computed.estimate.rangeText) · about \(Int(computed.estimate.confidence * 100))% confident within ±2 years")
                                        .font(.caption).foregroundStyle(.secondary)
                                    EvidenceList(evidence: computed.evidence)
                                }
                                .padding(16)
                            }
                            .frame(width: 420, height: 380)
                        }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(decision.selected ? Theme.accent : .clear, lineWidth: 2)
            )
            .opacity(decision.ignored ? 0.55 : 1)
            .contextMenu {
                Button("Show Details") { onOpen() }
                if decision.ignored {
                    Button("Review This Photo Again") { state.setIgnored(assetID, false) }
                } else {
                    Button("Keep Current Date (Don’t Show Again)") { state.setIgnored(assetID, true) }
                }
            }
        }
    }

    private func subtitle(_ c: ComputedEstimate) -> String {
        let e = c.estimate
        if !e.hasAnyEvidence { return "No clues found — please set the year yourself" }
        let used = c.evidence.filter { $0.hasYearInfo }.count
        var text = "Likely \(e.rangeText) · \(used) clue\(used == 1 ? "" : "s")"
        if e.seasonIsDefault { text += " · season unknown" }
        return text
    }
}

struct PhotoDetailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var assetID: String

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            AssetPreview(assetID: assetID, maxSide: 520)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let estimate = state.effectiveEstimate(assetID), let computed = state.estimates[assetID] {
                        HStack {
                            SeasonIcon(season: estimate.season)
                            Text(estimate.displayString).font(.title.weight(.semibold))
                            ConfidenceBadge(estimate: computed.estimate)
                        }
                        Text("Likely between \(computed.estimate.rangeText)").foregroundStyle(.secondary)
                    }
                    if let photo = state.photo(assetID) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.filename).font(.headline)
                            Text("Currently dated: \(photo.libraryDate?.formatted(date: .long, time: .shortened) ?? "no date")")
                            Text(photo.reason.explanation)
                            if !photo.albums.isEmpty { Text("Albums: \(photo.albums.joined(separator: ", "))") }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if let analysis = state.analyses[assetID], let err = analysis.aiError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    Divider()
                    EvidenceList(evidence: state.estimates[assetID]?.evidence ?? [])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 1000, height: 620)
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(16)
        }
    }
}
