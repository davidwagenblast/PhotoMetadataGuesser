import SwiftUI
import DateGuessCore

struct ScanView: View {
    @Environment(AppState.self) private var state
    var goNext: () -> Void

    @State private var albumSearch = ""
    @State private var newRuleLabel = "Scanning session"
    @State private var newRuleStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var newRuleEnd = Date()

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(step: 1, title: "Find photos without a date",
                           subtitle: "We’ll look through your whole library — even hundreds of thousands of photos — and set aside only the ones that don’t have a real date. Photos that already have one are skipped.",
                           systemImage: "magnifyingglass")

                scanCard

                Card(title: "What counts as “undated”?", systemImage: "questionmark.circle") {
                    Toggle(isOn: .constant(true)) {
                        Text("Photos with no date, an impossible date, or a camera’s factory-default date (like Jan 1, 1970)")
                    }
                    .disabled(true)
                    Toggle(isOn: $state.settings.scan.deepCheck) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Photos whose file has no capture date")
                            Text("Scans and imported files get the date they were scanned or imported. We read just the top of each file to tell — nothing is changed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Group {
                        Toggle("Trust photos that have a GPS location (phones and GPS cameras keep good dates)", isOn: $state.settings.scan.skipGPSTagged)
                        Toggle("Download originals from iCloud when they aren’t on this Mac (slow; uses bandwidth)", isOn: $state.settings.scan.allowICloudDownloads)
                    }
                    .disabled(!state.settings.scan.deepCheck)
                    .padding(.leading, 20)
                    Toggle("Include screenshots", isOn: $state.settings.scan.includeScreenshots)
                }

                albumsCard
                rulesCard
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    // MARK: Scan card

    private var scanCard: some View {
        Card {
            if let p = state.scanProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(p.phase).font(.headline)
                        Spacer()
                        Button("Stop") { state.cancelScan() }
                    }
                    ProgressView(value: p.fraction)
                    HStack {
                        if p.total > 0 { Text("\(p.done.formatted()) of \(p.total.formatted())") }
                        Spacer()
                        Text("\(p.found.formatted()) need a date so far")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let last = state.scan.lastScan {
                            Text("\(state.undatedSorted.count.formatted()) photos need a date")
                                .font(.title2.weight(.semibold))
                            Text("Checked \(state.scan.totalAssets.formatted()) photos on \(last.formatted(date: .abbreviated, time: .shortened)).")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready when you are")
                                .font(.title2.weight(.semibold))
                            Text("A first scan of a very large library can take a while. You can stop and come back — checked photos are remembered.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        state.startScan()
                    } label: {
                        Label(state.scan.lastScan == nil ? "Scan Library" : "Scan Again", systemImage: "magnifyingglass")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if !state.undatedSorted.isEmpty {
                        Button("Next: Group Photos", action: goNext)
                            .controlSize(.large)
                    }
                }
                if state.scan.lastScan != nil {
                    resultsSummary
                }
            }
        }
    }

    private var resultsSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            let counts = Dictionary(grouping: state.undatedSorted, by: \.reason).mapValues(\.count)
            ForEach(UndatedReason.allCases, id: \.self) { reason in
                if let n = counts[reason] {
                    HStack {
                        Text(reason.explanation)
                        Spacer()
                        Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if state.scan.unverifiableCount > 0 {
                Label("\(state.scan.unverifiableCount.formatted()) photos couldn’t be checked because their originals are only in iCloud. Turn on “Download originals from iCloud” below to include them.",
                      systemImage: "icloud")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !state.undatedSorted.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(state.undatedSorted.prefix(40)) { photo in
                            AssetThumbnail(assetID: photo.id, side: 72, cornerRadius: 8)
                                .help(photo.filename)
                        }
                    }
                }
                .frame(height: 76)
            }
        }
    }

    // MARK: Albums

    private var albumsCard: some View {
        Card(title: "Albums that are all undated (optional)", systemImage: "rectangle.stack") {
            Text("If you keep scans in albums like “Shoebox scans”, tick them and every photo inside will be treated as undated — even if it has a date from the scanner.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if state.albums.isEmpty {
                Text("No albums found.").foregroundStyle(.secondary)
            } else {
                TextField("Search albums", text: $albumSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                let filtered = state.albums.filter { albumSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(albumSearch) }
                List(filtered) { album in
                    Toggle(isOn: albumBinding(album.id)) {
                        HStack {
                            Text(album.title)
                            Spacer()
                            Text(album.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func albumBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.settings.scan.undatedAlbumIDs.contains(id) },
            set: { on in
                var ids = state.settings.scan.undatedAlbumIDs.filter { $0 != id }
                if on { ids.append(id) }
                state.settings.scan.undatedAlbumIDs = ids
            })
    }

    // MARK: Date-range rules

    private var rulesCard: some View {
        Card(title: "Scanning sessions (optional)", systemImage: "calendar.badge.exclamationmark") {
            Text("Scanned a box of prints over a weekend? Add those days here and anything dated within them is treated as undated.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(state.settings.scan.dateRangeRules) { rule in
                HStack {
                    Image(systemName: "calendar")
                    Text(rule.label).fontWeight(.medium)
                    Text("\(rule.start.shortDay) – \(rule.end.shortDay)").foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        state.settings.scan.dateRangeRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Label", text: $newRuleLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                DatePicker("From", selection: $newRuleStart, displayedComponents: .date)
                DatePicker("To", selection: $newRuleEnd, displayedComponents: .date)
                Button("Add") {
                    let cal = Calendar.current
                    let start = cal.startOfDay(for: min(newRuleStart, newRuleEnd))
                    let endDay = cal.startOfDay(for: max(newRuleStart, newRuleEnd))
                    let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDay
                    state.settings.scan.dateRangeRules.append(DateRangeRule(label: newRuleLabel, start: start, end: end))
                }
            }
        }
    }
}
