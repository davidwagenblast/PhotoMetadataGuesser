import SwiftUI
import DateGuessCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case scan, groups, people, estimate, review, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Find Undated Photos"
        case .groups: return "Group Photos"
        case .people: return "People & Birthdays"
        case .estimate: return "Estimate Dates"
        case .review: return "Review & Apply"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .scan: return "magnifyingglass"
        case .groups: return "square.stack.3d.up"
        case .people: return "person.2"
        case .estimate: return "sparkles"
        case .review: return "checkmark.circle"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var step: Int? {
        switch self {
        case .scan: return 1
        case .groups: return 2
        case .people: return 3
        case .estimate: return 4
        case .review: return 5
        case .history: return nil
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarItem? = .scan

    var body: some View {
        Group {
            if state.isAuthorized {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                }
            } else {
                WelcomeView()
            }
        }
        .overlay(alignment: .bottom) { BannerView() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Photo Date Guesser")
                    .font(.headline)
                Text("Finding when your memories happened")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .selectionDisabled()

            Section("Steps") {
                ForEach(SidebarItem.allCases.filter { $0.step != nil }) { item in
                    NavigationLink(value: item) {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.icon)
                        }
                        .badge(badge(for: item))
                    }
                }
            }
            Section {
                NavigationLink(value: SidebarItem.history) {
                    Label(SidebarItem.history.title, systemImage: SidebarItem.history.icon)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .scan: return state.undatedSorted.count
        case .groups: return state.groups.count
        case .people: return state.people.count
        case .estimate: return state.pendingAnalysisIDs.count
        case .review: return state.selectedForApply.count
        case .history: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .scan {
        case .scan: ScanView(goNext: { selection = .groups })
        case .groups: GroupsView(goNext: { selection = .people })
        case .people: PeopleView(goNext: { selection = .estimate })
        case .estimate: EstimateView(goNext: { selection = .review })
        case .review: ReviewView()
        case .history: HistoryView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            Text("Hi! Let’s find the dates of your old photos.")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Photo Date Guesser looks through your Photos library for pictures that don’t have a real date — like scanned prints — and makes a careful guess for each one. You review every guess before anything changes.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            if state.authorization == .denied || state.authorization == .restricted {
                VStack(spacing: 8) {
                    Text("Photos access is turned off for this app.")
                        .font(.headline)
                    Text("Open System Settings ▸ Privacy & Security ▸ Photos and turn on Photo Date Guesser, then reopen the app.")
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else {
                Button {
                    Task { await state.requestAccess() }
                } label: {
                    Label("Allow Access to Photos", systemImage: "photo.on.rectangle.angled")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Text("Your photos stay in your library. Dates are changed only when you click Apply, and every change can be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct BannerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let text = state.banner {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Theme.accent)
                Text(text)
                    .lineLimit(3)
                Button {
                    state.banner = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
