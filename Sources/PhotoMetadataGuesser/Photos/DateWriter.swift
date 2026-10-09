import Foundation
import Photos

/// Changes photo dates using PhotoKit's official API.
///
/// `PHAssetChangeRequest.creationDate` updates the date Photos shows and sorts by — the same thing
/// as Image ▸ Adjust Date and Time in the Photos app. The original file is not rewritten or
/// replaced, and every other property (location, people, albums, keywords, captions, edits,
/// favorites) is untouched. Going through PhotoKit means Photos itself makes the change, so its
/// database stays consistent and iCloud Photos syncs it normally.
enum DateWriter {
    struct Change: Sendable {
        var assetID: String
        var date: Date
    }

    static let chunkSize = 100

    static func apply(_ changes: [Change], progress: @escaping @Sendable (Int, Int) async -> Void) async -> ApplyBatch {
        var batch = ApplyBatch(date: Date(), entries: [])
        let library = PhotoLibraryService.shared
        var done = 0
        for chunk in changes.chunked(into: chunkSize) {
            if Task.isCancelled { break }
            let assets = library.assets(for: chunk.map(\.assetID))
            var pending: [(AssetRef, Change, Date?)] = []
            for change in chunk {
                guard let asset = assets[change.assetID] else {
                    batch.failures[change.assetID] = "Photo no longer in the library"
                    continue
                }
                guard asset.canPerform(.properties) else {
                    batch.failures[change.assetID] = "Photos doesn't allow changing this item's date (e.g. shared album)"
                    continue
                }
                pending.append((AssetRef(asset: asset), change, asset.creationDate))
            }
            if !pending.isEmpty {
                let requests = pending.map { ($0.0, $0.1.date) }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for (ref, date) in requests {
                            let request = PHAssetChangeRequest(for: ref.asset)
                            request.creationDate = date
                        }
                    }
                    for (_, change, previous) in pending {
                        batch.entries.append(JournalEntry(assetID: change.assetID, previousDate: previous, newDate: change.date))
                    }
                } catch {
                    for (_, change, _) in pending { batch.failures[change.assetID] = error.localizedDescription }
                }
            }
            done += chunk.count
            await progress(done, changes.count)
        }
        return batch
    }

    /// Puts the previous dates back for a batch this app applied.
    static func undo(_ batch: ApplyBatch, progress: @escaping @Sendable (Int, Int) async -> Void) async -> ApplyBatch {
        let restorable = batch.entries.compactMap { entry in
            entry.previousDate.map { Change(assetID: entry.assetID, date: $0) }
        }
        return await apply(restorable, progress: progress)
    }
}
