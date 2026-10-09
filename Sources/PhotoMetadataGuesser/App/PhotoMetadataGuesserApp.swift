import AppKit
import SwiftUI

@main
struct PhotoMetadataGuesserApp: App {
    @State private var state = AppState()

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

        Settings {
            SettingsView()
                .environment(state)
                .tint(Theme.accent)
        }
    }
}
