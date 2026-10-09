import Foundation

// MARK: - Season

/// Seasons the app estimates. Each maps to one representative month:
/// January for winter, March for spring, June for summer, September for fall.
public enum Season: String, Codable, CaseIterable, Sendable, Identifiable {
    case winter, spring, summer, fall

    public var id: String { rawValue }

    public var representativeMonth: Int {
        switch self {
        case .winter: return 1
        case .spring: return 3
        case .summer: return 6
        case .fall: return 9
        }
    }

    public var displayName: String { rawValue.capitalized }

    public var symbolName: String {
        switch self {
        case .winter: return "snowflake"
        case .spring: return "camera.macro"
        case .summer: return "sun.max.fill"
        case .fall: return "leaf.fill"
        }
    }

    /// Meteorological season for a calendar month (Northern Hemisphere).
    public static func from(month: Int) -> Season {
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .fall
        default: return .winter
        }
    }
}

// MARK: - Evidence

/// Where a clue came from. Used for display and for weighting.
public enum EvidenceSource: String, Codable, CaseIterable, Sendable {
    case filename
    case album
    case fileFormat
    case camera
    case colorTone
    case borderPaper
    case printFormat
    case scene
    case aiOverall
    case aiClue
    case printedDate
    case person
    case groupHint
    case group
    case libraryDate
    case prior

    public var displayName: String {
        switch self {
        case .filename: return "Filename"
        case .album: return "Album"
        case .fileFormat: return "File format"
        case .camera: return "Camera"
        case .colorTone: return "Color & tone"
        case .borderPaper: return "Border & paper"
        case .printFormat: return "Print format"
        case .scene: return "Scene"
        case .aiOverall: return "Visual analysis"
        case .aiClue: return "Visual clue"
        case .printedDate: return "Printed date"
        case .person: return "People"
        case .groupHint: return "Your group hint"
        case .group: return "Group"
        case .libraryDate: return "Library date"
        case .prior: return "Background"
        }
    }

    public var symbolName: String {
        switch self {
        case .filename: return "doc.text"
        case .album: return "rectangle.stack"
        case .fileFormat: return "doc.richtext"
        case .camera: return "camera"
        case .colorTone: return "paintpalette"
        case .borderPaper: return "photo.artframe"
        case .printFormat: return "aspectratio"
        case .scene: return "mountain.2"
        case .aiOverall: return "sparkles"
        case .aiClue: return "eye"
        case .printedDate: return "calendar"
        case .person: return "person.2"
        case .groupHint: return "text.bubble"
        case .group: return "square.stack.3d.up"
        case .libraryDate: return "clock"
        case .prior: return "circle.dashed"
        }
    }
}

/// A single clue about when a photo was taken.
///
/// Year information is a soft "plateau" over `yearLow...yearHigh` (optionally peaked at
/// `peakYear`) mixed with a uniform floor according to `weight`. A `weight` of 0 makes the
/// clue informational only (shown to the user but not used in the math). Hard constraints
/// (e.g. "a person born in 1950 is in the photo") make years outside the range near-impossible.
public struct DateEvidence: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: EvidenceSource
    public var summary: String
    public var yearLow: Int?
    public var yearHigh: Int?
    public var peakYear: Int?
    public var weight: Double
    public var isHardConstraint: Bool
    public var season: Season?
    public var seasonWeight: Double
    public var exactMonth: Int?
    public var exactDay: Int?

    public init(
        id: UUID = UUID(),
        source: EvidenceSource,
        summary: String,
        yearLow: Int? = nil,
        yearHigh: Int? = nil,
        peakYear: Int? = nil,
        weight: Double = 0,
        isHardConstraint: Bool = false,
        season: Season? = nil,
        seasonWeight: Double = 0,
        exactMonth: Int? = nil,
        exactDay: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.summary = summary
        self.yearLow = yearLow
        self.yearHigh = yearHigh
        self.peakYear = peakYear
        self.weight = max(0, min(1, weight))
        self.isHardConstraint = isHardConstraint
        self.season = season
        self.seasonWeight = max(0, min(1, seasonWeight))
        self.exactMonth = exactMonth
        self.exactDay = exactDay
    }

    public var hasYearInfo: Bool { (yearLow != nil || yearHigh != nil) && (weight > 0 || isHardConstraint) }

    /// Human-readable year range, e.g. "1972–1978" or "after 1950".
    public var yearRangeText: String? {
        switch (yearLow, yearHigh) {
        case let (lo?, hi?) where lo == hi: return "\(lo)"
        case let (lo?, hi?): return "\(lo)–\(hi)"
        case let (lo?, nil): return "\(lo) or later"
        case let (nil, hi?): return "\(hi) or earlier"
        default: return nil
        }
    }
}

// MARK: - Estimate

public enum ConfidenceLevel: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    public var displayName: String { rawValue.capitalized }
}

/// The best guess for a photo, produced by `EvidenceFusion`.
public struct DateEstimate: Codable, Hashable, Sendable {
    public var year: Int
    public var season: Season
    public var month: Int
    public var day: Int
    /// Roughly an 80% credible interval.
    public var yearLow: Int
    public var yearHigh: Int
    /// Probability mass within ±2 years of `year` (0...1).
    public var confidence: Double
    public var seasonIsDefault: Bool
    public var usedExactMonth: Bool
    public var usedExactDay: Bool
    public var hasAnyEvidence: Bool

    public init(
        year: Int, season: Season, month: Int, day: Int = 1,
        yearLow: Int, yearHigh: Int, confidence: Double,
        seasonIsDefault: Bool, usedExactMonth: Bool = false, usedExactDay: Bool = false,
        hasAnyEvidence: Bool
    ) {
        self.year = year
        self.season = season
        self.month = month
        self.day = day
        self.yearLow = yearLow
        self.yearHigh = yearHigh
        self.confidence = confidence
        self.seasonIsDefault = seasonIsDefault
        self.usedExactMonth = usedExactMonth
        self.usedExactDay = usedExactDay
        self.hasAnyEvidence = hasAnyEvidence
    }

    public var confidenceLevel: ConfidenceLevel {
        if confidence >= 0.6 { return .high }
        if confidence >= 0.35 { return .medium }
        return .low
    }

    /// e.g. "Summer 1976", "July 1976", or "July 4, 1976".
    public var displayString: String {
        let monthName = DateEstimate.monthNames[max(1, min(12, month)) - 1]
        if usedExactDay { return "\(monthName) \(day), \(year)" }
        if usedExactMonth { return "\(monthName) \(year)" }
        return "\(season.displayName) \(year)"
    }

    public var rangeText: String {
        yearLow == yearHigh ? "\(yearLow)" : "\(yearLow)–\(yearHigh)"
    }

    /// The date that will be written: the chosen month/day at noon local time
    /// (noon keeps the calendar day stable across time zones).
    public func date(calendar: Calendar = .current) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return calendar.date(from: comps)
    }

    /// Returns a copy with a user-chosen year/season (clears exact month/day).
    public func overridden(year newYear: Int? = nil, season newSeason: Season? = nil) -> DateEstimate {
        var copy = self
        if let newYear { copy.year = newYear }
        if let newSeason {
            copy.season = newSeason
            copy.month = newSeason.representativeMonth
            copy.day = 1
            copy.usedExactMonth = false
            copy.usedExactDay = false
            copy.seasonIsDefault = false
        }
        if newYear != nil && newSeason == nil && !copy.usedExactMonth {
            copy.month = copy.season.representativeMonth
            copy.day = 1
        }
        return copy
    }

    public static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
}

// MARK: - People & Groups

/// Someone the user identified, with their birth date, so their apparent age can date photos.
public struct PersonInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var birthYear: Int
    public var birthMonth: Int?
    /// PhotoKit local identifiers of photos that clearly show this person.
    public var referenceAssetIDs: [String]
    public var notes: String

    public init(id: UUID = UUID(), name: String, birthYear: Int, birthMonth: Int? = nil,
                referenceAssetIDs: [String] = [], notes: String = "") {
        self.id = id
        self.name = name
        self.birthYear = birthYear
        self.birthMonth = birthMonth
        self.referenceAssetIDs = referenceAssetIDs
        self.notes = notes
    }
}

public enum GroupKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// All photos are from one event (same day/trip): they get the same date.
    case sameEvent
    /// Photos are from roughly the same period: each gets its own date, pulled toward the group.
    case sameEra

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sameEvent: return "Same event (one date for all)"
        case .sameEra: return "Same era (nudge toward each other)"
        }
    }
}

/// A person the user says appears in a group, optionally with their approximate age there.
public struct GroupPersonHint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var approximateAge: Int?

    public init(id: UUID = UUID(), personID: UUID, approximateAge: Int? = nil) {
        self.id = id
        self.personID = personID
        self.approximateAge = approximateAge
    }
}

/// Photos the user says go together, plus anything they know about them.
public struct PhotoGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: GroupKind
    public var assetIDs: [String]
    public var hint: String
    public var yearFrom: Int?
    public var yearTo: Int?
    public var season: Season?
    public var people: [GroupPersonHint]

    public init(id: UUID = UUID(), name: String, kind: GroupKind = .sameEra, assetIDs: [String] = [],
                hint: String = "", yearFrom: Int? = nil, yearTo: Int? = nil, season: Season? = nil,
                people: [GroupPersonHint] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.assetIDs = assetIDs
        self.hint = hint
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.season = season
        self.people = people
    }
}

// MARK: - Calendar helpers

public enum YearBounds {
    /// The first surviving photograph dates from 1826/27.
    public static let earliestPhotoYear = 1826
    /// Lower edge of the estimation grid.
    public static let gridMinYear = 1830

    public static func currentYear(now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.component(.year, from: now)
    }

    public static func isPlausible(_ year: Int, now: Date = Date()) -> Bool {
        year >= earliestPhotoYear && year <= currentYear(now: now)
    }
}
