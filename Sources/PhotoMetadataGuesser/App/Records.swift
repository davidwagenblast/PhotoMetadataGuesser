import Foundation
import DateGuessCore

/// A photo the scan found without a trustworthy date.
struct UndatedPhoto: Codable, Identifiable, Hashable {
    var id: String
    var reason: UndatedReason
    var libraryDate: Date?
    var format: FormatInfo
    var albums: [String]

    var filename: String { format.originalFilename ?? "Untitled" }
}

struct ScanOptions: Codable, Hashable {
    /// Read each original file's header to find photos whose date is only the import/scan time.
    var deepCheck = true
    /// Photos with GPS come from phones/cameras with clocks: trust their dates.
    var skipGPSTagged = true
    /// Download originals from iCloud when they aren't on this Mac (slow, uses bandwidth).
    var allowICloudDownloads = false
    var includeScreenshots = false
    /// Albums whose photos should all be treated as undated (PhotoKit collection identifiers).
    var undatedAlbumIDs: [String] = []
    var dateRangeRules: [DateRangeRule] = []
}

struct ScanSnapshot: Codable {
    var lastScan: Date?
    var totalAssets = 0
    var undated: [String: UndatedPhoto] = [:]
    /// Deep-checked photos that turned out to have a real capture date (lets re-scans skip them).
    var checkedDatedIDs: Set<String> = []
    var unverifiableCount = 0
}

/// Everything learned about one photo during estimation (before groups/people are applied).
struct PhotoAnalysis: Codable, Hashable {
    var assetID: String
    var localEvidence: [DateEvidence]
    var aiEvidence: [DateEvidence]
    var aiError: String?
    var usedAI: Bool
    var analyzedAt: Date
}

/// The user's choices for one photo on the review screen.
struct ReviewDecision: Codable, Hashable {
    var selected = false
    var overrideYear: Int?
    var overrideSeason: Season?
    var ignored = false
}

struct JournalEntry: Codable, Hashable {
    var assetID: String
    var previousDate: Date?
    var newDate: Date
}

/// One "Apply" click, kept so it can be undone.
struct ApplyBatch: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var entries: [JournalEntry]
    var failures: [String: String] = [:]
    var undone = false
}

struct AppSettings: Codable, Hashable {
    var ai = AISettings()
    var scan = ScanOptions()
    var allowExactMonth = true
}

/// A fused estimate ready for review.
struct ComputedEstimate: Hashable {
    var estimate: DateEstimate
    var evidence: [DateEvidence]
    var groupName: String?
}
