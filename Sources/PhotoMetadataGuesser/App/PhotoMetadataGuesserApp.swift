import AppKit
import SwiftUI

@main
struct PhotoMetadataGuesserApp: App {
    var _state = State<AppState>(initialValue: AppState())
    private var state: AppState { get { _state.wrappedValue } nonmutating set { _state.wrappedValue = newValue } }

    var body: some Scene {
        WindowGroup("Photo Date Guesser") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1020, minHeight: 700)
                .tint(Theme.accent)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    state.saveEverything()
                }
        }
        .windowToolbarStyle(.unified)
        .commands { SidebarCommands() }

        Settings {
            SettingsView()
                .environment(state)
                .tint(Theme.accent)
        }
    }
}
