import AppKit
import SwiftUI
import DateGuessCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var keyDraft = ""
    @State private var confirmReset = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Claude visual analysis") {
                Toggle("Use Claude to analyze photos", isOn: $state.settings.ai.enabled)
                HStack {
                    SecureField("Anthropic API key", text: $keyDraft, prompt: Text(state.hasAPIKey ? "Saved in your Keychain" : "sk-ant-…"))
                    Button("Save") {
                        state.saveAPIKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty)
                    if state.hasAPIKey {
                        Button("Remove", role: .destructive) { state.saveAPIKey("") }
                    }
                }
                Link("Get an API key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
                Picker("Model", selection: $state.settings.ai.model) {
                    ForEach(AIModelOption.all) { option in
                        Text("\(option.name) — \(option.blurb)").tag(option.id)
                    }
                }
                Picker("Thoroughness", selection: $state.settings.ai.effort) {
                    Text("Quick").tag("low")
                    Text("Balanced").tag("medium")
                    Text("Thorough").tag("high")
                }
                Picker("Image detail", selection: $state.settings.ai.imageMaxEdge) {
                    Text("Standard (768 px)").tag(768)
                    Text("High (1024 px)").tag(1024)
                    Text("Very high (1568 px)").tag(1568)
                }
                Stepper("Photos per request: \(state.settings.ai.photosPerRequest)", value: $state.settings.ai.photosPerRequest, in: 1...10)
                Stepper("Requests at once: \(state.settings.ai.concurrentRequests)", value: $state.settings.ai.concurrentRequests, in: 1...8)
                Text("Higher detail and thoroughness are more accurate but cost more. Larger batches are cheaper per photo; grouped photos are always sent together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dates") {
                Toggle("Use the exact month when a clear date or holiday is found", isOn: $state.settings.allowExactMonth)
                Text("Otherwise each guess uses the season’s month: January (winter), March (spring), June (summer) or September (fall). Dates are set to noon on the 1st (or the exact day, when a full date is found).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Button("Show Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([JSONStore.shared.directory])
                    }
                    Button("Clear All Estimates…", role: .destructive) { confirmReset = true }
                }
                Text("Scan results, groups, people, estimates and the undo history are stored on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
        .alert("Clear all estimates?", isPresented: $confirmReset) {
            Button("Clear", role: .destructive) {
                state.analyses = [:]
                state.saveAnalysesNow()
                state.recomputeEstimates()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your groups, people and history are kept. You’ll need to run Estimate Dates again.")
        }
    }
}
