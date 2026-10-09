import SwiftUI
import DateGuessCore

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var batchToUndo: ApplyBatch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(step: nil, title: "History",
                           subtitle: "Every time you click Apply, the old dates are saved here so you can put them back.",
                           systemImage: "clock.arrow.circlepath")
                if state.journal.isEmpty {
                    Card {
                        Text("No dates have been changed yet.").foregroundStyle(.secondary)
                    }
                }
                ForEach(state.journal) { batch in
                    Card {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(batch.date.formatted(date: .long, time: .shortened)).font(.headline)
                                Text("\(batch.entries.count.formatted()) photos updated"
                                     + (batch.failures.isEmpty ? "" : " · \(batch.failures.count) couldn’t be changed"))
                                    .foregroundStyle(.secondary)
                                if batch.undone {
                                    Label("Undone — previous dates restored", systemImage: "arrow.uturn.backward.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !batch.undone {
                                Button("Undo…") { batchToUndo = batch }
                                    .disabled(state.isApplying)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(batch.entries.prefix(30), id: \.assetID) { entry in
                                    VStack(spacing: 2) {
                                        AssetThumbnail(assetID: entry.assetID, side: 70, cornerRadius: 8)
                                        Text(entry.newDate.formatted(.dateTime.month(.abbreviated).year()))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(height: 92)
                        if !batch.failures.isEmpty {
                            DisclosureGroup("Problems") {
                                ForEach(batch.failures.keys.sorted().prefix(50), id: \.self) { id in
                                    Text("\(state.photo(id)?.filename ?? id): \(batch.failures[id] ?? "")")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .alert("Undo this change?", isPresented: Binding(get: { batchToUndo != nil }, set: { if !$0 { batchToUndo = nil } })) {
            Button("Restore Previous Dates") {
                if let batch = batchToUndo { state.undo(batch) }
                batchToUndo = nil
            }
            Button("Cancel", role: .cancel) { batchToUndo = nil }
        } message: {
            Text("The \(batchToUndo?.entries.count ?? 0) photos will get back the dates they had before.")
        }
    }
}
