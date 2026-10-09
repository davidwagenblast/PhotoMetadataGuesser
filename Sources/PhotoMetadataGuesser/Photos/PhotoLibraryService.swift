import AppKit
import Photos
import ImageIO
import DateGuessCore

struct AlbumInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var count: Int
}

/// Wraps a PHAsset so it can cross concurrency boundaries (PhotoKit objects are thread-safe to read).
struct AssetRef: @unchecked Sendable {
    let asset: PHAsset
}

/// All read access to the Photos library goes through here.
final class PhotoLibraryService: @unchecked Sendable {
    static let shared = PhotoLibraryService()

    let imageManager = PHCachingImageManager()
    private let assetCache = NSCache<NSString, PHAsset>()

    init() {
        assetCache.countLimit = 5000
        imageManager.allowsCachingHighQualityImages = false
    }

    // MARK: Authorization

    var authorizationStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: Fetching

    /// Every photo in the user's own library (not shared albums), oldest first.
    func fetchAllPhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    func asset(for id: String) -> PHAsset? {
        if let cached = assetCache.object(forKey: id as NSString) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assetCache.setObject(asset, forKey: id as NSString)
        return asset
    }

    func assets(for ids: [String]) -> [String: PHAsset] {
        var out: [String: PHAsset] = [:]
        for chunk in ids.chunked(into: 500) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            result.enumerateObjects { asset, _, _ in out[asset.localIdentifier] = asset }
        }
        return out
    }

    private func userAlbumCollections() -> [PHAssetCollection] {
        var out: [PHAssetCollection] = []
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        result.enumerateObjects { collection, _, _ in
            // Shared iCloud albums can't be edited and aren't part of the user's library.
            if collection.assetCollectionSubtype != .albumCloudShared { out.append(collection) }
        }
        return out
    }

    func userAlbums() -> [AlbumInfo] {
        userAlbumCollections().map { c in
            AlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled album",
                      count: PHAsset.fetchAssets(in: c, options: nil).count)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Asset IDs in the given albums.
    func assetIDs(inAlbums albumIDs: [String]) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var ids = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    /// Album titles for each of the given assets.
    func albumTitles(for ids: Set<String>) -> [String: [String]] {
        var out: [String: [String]] = [:]
        guard !ids.isEmpty else { return out }
        for collection in userAlbumCollections() {
            let title = collection.localizedTitle ?? "Untitled album"
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                if ids.contains(asset.localIdentifier) { out[asset.localIdentifier, default: []].append(title) }
            }
        }
        return out
    }

    // MARK: File metadata

    func originalResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
    }

    func formatInfo(for asset: PHAsset, embedded: EmbeddedDateInfo?) -> FormatInfo {
        let resource = originalResource(for: asset)
        return FormatInfo(
            originalFilename: resource?.originalFilename,
            uniformTypeIdentifier: resource?.uniformTypeIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isPanorama: asset.mediaSubtypes.contains(.photoPanorama),
            isDepthEffect: asset.mediaSubtypes.contains(.photoDepthEffect),
            cameraMake: embedded?.make,
            cameraModel: embedded?.model,
            software: embedded?.software,
            hasGPS: asset.location != nil || (embedded?.hasGPS ?? false))
    }

    enum EmbeddedResult {
        case info(EmbeddedDateInfo)
        /// The original isn't on this Mac (iCloud) and downloads aren't allowed, or it couldn't be read.
        case unavailable
    }

    /// Reads just enough of the original file to see its capture-date metadata, without
    /// loading or changing the photo.
    func readEmbeddedInfo(for asset: PHAsset, allowNetwork: Bool) async -> EmbeddedResult {
        guard let resource = originalResource(for: asset) else { return .unavailable }
        let uti = resource.uniformTypeIdentifier.lowercased()
        // JPEG/HEIC keep metadata near the start of the file; TIFF/RAW may keep it anywhere.
        let headerFormat = uti.contains("jpeg") || uti.contains("heic") || uti.contains("heif")
        let anywhereFormat = uti.contains("tiff") || uti.contains("raw") || uti.contains("dng")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            let reader = PartialMetadataReader(byteCap: anywhereFormat ? 64_000_000 : 8_000_000,
                                               conclusiveAfter: headerFormat ? 256 * 1024 : (anywhereFormat ? 64_000_000 : 1_000_000)) { result in
                continuation.resume(returning: result.map(EmbeddedResult.info) ?? .unavailable)
            }
            let requestID = PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { chunk in reader.append(chunk) },
                completionHandler: { error in reader.finish(error: error) })
            reader.setRequestID(requestID)
        }
    }

    // MARK: Images

    /// A thumbnail for grids. Calls back possibly twice (fast degraded image, then sharp).
    @discardableResult
    func requestThumbnail(for asset: PHAsset, side: CGFloat, handler: @escaping (NSImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: side * scale, height: side * scale)
        return imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
            handler(image)
        }
    }

    func cancel(_ id: PHImageRequestID) { imageManager.cancelImageRequest(id) }

    /// A good-quality rendering for analysis (current edited version, oriented correctly).
    func analysisImage(for asset: PHAsset, maxEdge: Int) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let size = CGSize(width: maxEdge, height: maxEdge)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard once.claim() else { return }
                var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
                continuation.resume(returning: image?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            }
        }
    }
}

/// Thread-safe "only once" guard for continuations.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Accumulates file bytes until the image header's metadata can be parsed, then stops the download.
final class PartialMetadataReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelWhenIDKnown = false
    private var nextParseAt = 64 * 1024
    private let byteCap: Int
    /// After this many bytes, a readable header without EXIF/TIFF means the file has none.
    private let conclusiveAfter: Int
    private let completion: (EmbeddedDateInfo?) -> Void

    init(byteCap: Int, conclusiveAfter: Int, completion: @escaping (EmbeddedDateInfo?) -> Void) {
        self.byteCap = byteCap
        self.conclusiveAfter = conclusiveAfter
        self.completion = completion
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelWhenIDKnown
        lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        data.append(chunk)
        let size = data.count
        guard size >= nextParseAt || size >= byteCap else { lock.unlock(); return }
        nextParseAt = size * 2
        let snapshot = data
        lock.unlock()

        if let info = Self.parse(snapshot, final: false, requireDates: size < conclusiveAfter && size < byteCap) {
            deliver(info, cancel: true)
        } else if size >= byteCap {
            // Read plenty and still no capture-date metadata: treat as having none.
            deliver(Self.parse(snapshot, final: false, requireDates: false) ?? EmbeddedDateInfo(), cancel: true)
        }
    }

    func finish(error: Error?) {
        lock.lock()
        let alreadyDone = finished
        let snapshot = data
        lock.unlock()
        guard !alreadyDone else { return }
        if error != nil && snapshot.isEmpty {
            deliver(nil, cancel: false)
            return
        }
        deliver(Self.parse(snapshot, final: error == nil, requireDates: false) ?? (error == nil ? EmbeddedDateInfo() : nil), cancel: false)
    }

    private func deliver(_ info: EmbeddedDateInfo?, cancel: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let id = requestID
        if cancel && id == nil { cancelWhenIDKnown = true }
        lock.unlock()
        if cancel, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        completion(info)
    }

    /// Parses image properties from (possibly partial) file data.
    /// With `requireDates`, returns nil unless EXIF/TIFF metadata has been seen (so we keep reading).
    static func parse(_ data: Data, final: Bool, requireDates: Bool) -> EmbeddedDateInfo? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, final)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        if requireDates && exif == nil && tiff == nil { return nil }
        return EmbeddedDateInfo(
            dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            dateTimeDigitized: exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiffDateTime: tiff?[kCGImagePropertyTIFFDateTime] as? String,
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String,
            software: tiff?[kCGImagePropertyTIFFSoftware] as? String,
            hasGPS: !(gps?.isEmpty ?? true))
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
