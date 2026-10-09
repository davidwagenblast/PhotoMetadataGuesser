import SwiftUI
import DateGuessCore

struct EstimateView: View {
    @Environment(AppState.self) private var state
    var goNext: () -> Void
    @State private var confirmReanalyze = false

    var body: some View {
        let pending = state.pendingAnalysisIDs
        let failed = state.aiFailedIDs
        let total = state.undatedSorted.count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(step: 4, title: "Estimate dates",
                           subtitle: "Every photo gets a best guess for its year and season, built from all the clues we can find. Nothing in your library changes yet.",
                           systemImage: "sparkles")

                Card {
                    if let p = state.estimationProgress, state.isEstimating {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(p.phase).font(.headline)
                                Spacer()
                                Button("Stop") { state.cancelEstimation() }
                            }
                            ProgressView(value: p.fraction)
                            HStack {
                                Text("\(p.done.formatted()) of \(p.total.formatted()) photos")
                                Spacer()
                                if p.usage.inputTokens + p.usage.outputTokens > 0 {
                                    Text("Claude usage so far: about \(p.usage.cost(model: state.settings.ai.model).formatted(.currency(code: "USD")))")
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pending.isEmpty ? "All \(total.formatted()) photos have an estimate" : "\(pending.count.formatted()) photos waiting for an estimate")
                                    .font(.title2.weight(.semibold))
                                Text("\((total - pending.count).formatted()) estimated · \(state.groups.count) groups · \(state.people.count) people")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !pending.isEmpty {
                                Button {
                                    state.startEstimation()
                                } label: {
                                    Label("Estimate \(pending.count.formatted()) Photos", systemImage: "sparkles")
                                        .padding(.horizontal, 8)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            } else if total > 0 {
                                Button("Next: Review", action: goNext)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                            }
                        }
                        HStack(spacing: 14) {
                            if !failed.isEmpty && state.settings.ai.enabled {
                                Button("Retry Claude for \(failed.count.formatted()) photos") { state.startEstimation(ids: failed) }
                            }
                            if total > 0 {
                                Button("Re-estimate everything…") { confirmReanalyze = true }
                            }
                            Spacer()
                        }
                        .controlSize(.small)
                        Text("Changed your groups or people? Estimates update automatically. Re-estimate only if you turned on Claude after estimating, or added reference photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Card(title: "Clues checked on this Mac (free & private)", systemImage: "desktopcomputer") {
                    ClueRow(icon: "doc.text", text: "Filenames and album names — dates, years, decades (“late 70s”), holidays (“xmas ’85”), seasons")
                    ClueRow(icon: "doc.richtext", text: "File format and camera — e.g. HEIC means 2017 or later; a known camera model can’t predate its release")
                    ClueRow(icon: "paintpalette", text: "Color and tone — black & white, sepia, faded magenta prints")
                    ClueRow(icon: "photo.artframe", text: "Borders and format — white print borders, instant-film frames, square prints")
                    ClueRow(icon: "mountain.2", text: "Scene — snow, beaches, autumn leaves, holiday decorations to guess the season")
                    ClueRow(icon: "square.stack.3d.up", text: "Your groups, hints, people and birthdays")
                }

                aiCard
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .confirmationDialog("Re-estimate all \(total.formatted()) photos?", isPresented: $confirmReanalyze) {
            Button("Re-estimate All") { state.startEstimation(ids: state.undatedSorted.map(\.id)) }
        } message: {
            Text(state.settings.ai.enabled
                 ? "This will send every photo to Claude again (about \(state.settings.ai.estimatedCost(photoCount: total, referenceImages: referenceCount).formatted(.currency(code: "USD")))."
                 : "On-device analysis will run again for every photo.")
        }
    }

    private var referenceCount: Int { state.people.reduce(0) { $0 + min(2, $1.referenceAssetIDs.count) } }

    private var aiCard: some View {
        @Bindable var state = state
        let pending = state.pendingAnalysisIDs.count
        let option = AIModelOption.option(for: state.settings.ai.model)
        return Card(title: "Visual analysis with Claude (optional, recommended)", systemImage: "eye") {
            Toggle(isOn: $state.settings.ai.enabled) {
                Text("Look at each photo like a historian would: fashion and clothing, hairstyles, eyeglasses and accessories, cars, phones and TVs, architecture and interiors, printed date stamps, paper and border styles — and recognize the people you added to judge their age.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.settings.ai.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    if state.hasAPIKey {
                        Label("API key saved · \(option.name) · \(state.settings.ai.effort) effort", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Add your Anthropic API key in Settings to use this.", systemImage: "key")
                            .foregroundStyle(.orange)
                    }
                    if pending > 0 {
                        Text("Estimated cost for \(pending.formatted()) photos with \(option.name): about \(state.settings.ai.estimatedCost(photoCount: pending, referenceImages: referenceCount).formatted(.currency(code: "USD"))) (a rough guess; your Anthropic usage page shows the real amount).")
                            .font(.callout)
                    }
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    Text("Privacy: a reduced-size copy of each photo (\(state.settings.ai.imageMaxEdge) px), its filename and album names, your group notes, and the names and reference photos of people you added are sent to Anthropic’s API for analysis. Nothing is sent unless this is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
        }
    }
}

struct ClueRow: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
