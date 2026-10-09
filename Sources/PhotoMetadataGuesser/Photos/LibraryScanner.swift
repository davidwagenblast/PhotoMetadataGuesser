import Foundation
import Photos
import DateGuessCore

struct ScanProgress: Equatable {
    var phase: String = ""
    var done = 0
    var total = 0
    var found = 0

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Walks the whole library and finds photos without a trustworthy date. Designed for 250k+ photos:
/// one fast pass over PhotoKit's database, then a header-only read of the files that need it.
struct LibraryScanner {
    let library = PhotoLibraryService.shared
    var options: ScanOptions
    var previous: ScanSnapshot
    /// Photos this app already dated (or the user chose to ignore): never flag them again.
    var excludedIDs: Set<String>

    func run(progress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanSnapshot {
        var snapshot = ScanSnapshot()
        snapshot.checkedDatedIDs = previous.checkedDatedIDs

        // Phase 1: fast pass over the database.
        await progress(ScanProgress(phase: "Reading library…"))
        let albumRuleIDs = library.assetIDs(inAlbums: options.undatedAlbumIDs)
        let all = library.fetchAllPhotos()
        let total = all.count
        snapshot.totalAssets = total

        var candidates: [(AssetRef, UndatedReason)] = []
        var deepQueue: [AssetRef] = []
        let now = Date()
        var index = 0
        let batch = 2000
        while index < total {
            try Task.checkCancellation()
            let end = min(index + batch, total)
            let slice = all.objects(at: IndexSet(integersIn: index..<end))
            for asset in slice {
                let id = asset.localIdentifier
                if excludedIDs.contains(id) { continue }
                if !options.includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { continue }
                if let reason = UndatedDetector.fastCheck(creationDate: asset.creationDate, now: now, rules: options.dateRangeRules) {
                    candidates.append((AssetRef(asset: asset), reason))
                } else if albumRuleIDs.contains(id) {
                    candidates.append((AssetRef(asset: asset), .albumRule))
                } else if options.deepCheck {
                    if options.skipGPSTagged && asset.location != nil { continue }
                    if previous.checkedDatedIDs.contains(id) { continue }
                    deepQueue.append(AssetRef(asset: asset))
                }
            }
            index = end
            await progress(ScanProgress(phase: "Reading library…", done: index, total: total, found: candidates.count))
        }

        // Phase 2: read file headers for capture dates.
        var embeddedByID: [String: EmbeddedDateInfo] = [:]
        if !deepQueue.isEmpty {
            let deepTotal = deepQueue.count
            var done = 0
            await progress(ScanProgress(phase: "Checking file metadata…", done: 0, total: deepTotal, found: candidates.count))
            let allowNetwork = options.allowICloudDownloads
            let library = self.library
            try await withThrowingTaskGroup(of: (AssetRef, PhotoLibraryService.EmbeddedResult).self) { group in
                var iterator = deepQueue.makeIterator()
                let width = 8
                for _ in 0..<width {
                    guard let ref = iterator.next() else { break }
                    group.addTask { (ref, await library.readEmbeddedInfo(for: ref.asset, allowNetwork: allowNetwork)) }
                }
                while let (ref, result) = try await group.next() {
                    try Task.checkCancellation()
                    switch result {
                    case .unavailable:
                        snapshot.unverifiableCount += 1
                    case .info(let info):
                        if let reason = UndatedDetector.embeddedCheck(info) {
                            candidates.append((ref, reason))
                            embeddedByID[ref.asset.localIdentifier] = info
                        } else {
                            snapshot.checkedDatedIDs.insert(ref.asset.localIdentifier)
                        }
                    }
                    done += 1
                    if done % 100 == 0 || done == deepTotal {
                        await progress(ScanProgress(phase: "Checking file metadata…", done: done, total: deepTotal, found: candidates.count))
                    }
                    if let next = iterator.next() {
                        group.addTask { (next, await library.readEmbeddedInfo(for: next.asset, allowNetwork: allowNetwork)) }
                    }
                }
            }
        }

        // Phase 3: details for the photos that need dates.
        await progress(ScanProgress(phase: "Collecting details…", done: 0, total: candidates.count, found: candidates.count))
        let ids = Set(candidates.map { $0.0.asset.localIdentifier })
        let albums = library.albumTitles(for: ids)
        for (i, (ref, reason)) in candidates.enumerated() {
            if i % 500 == 0 {
                try Task.checkCancellation()
                await progress(ScanProgress(phase: "Collecting details…", done: i, total: candidates.count, found: candidates.count))
            }
            let asset = ref.asset
            let id = asset.localIdentifier
            let format = library.formatInfo(for: asset, embedded: embeddedByID[id])
            snapshot.undated[id] = UndatedPhoto(id: id, reason: reason, libraryDate: asset.creationDate,
                                                format: format, albums: albums[id] ?? [])
        }
        snapshot.lastScan = Date()
        await progress(ScanProgress(phase: "Done", done: candidates.count, total: candidates.count, found: candidates.count))
        return snapshot
    }
}
