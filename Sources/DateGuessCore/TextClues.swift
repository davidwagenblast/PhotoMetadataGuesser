import Foundation

/// Finds date clues in text: filenames, album names, and the user's own group hints.
///
/// Recognizes full dates (1985-07-04, 19850704, 7/4/1985), month + year ("July 1985", "Jul '85"),
/// year ranges ("1975-1980"), decades ("late 70s", "1960s"), approximate years ("circa 1975"),
/// bare years, Unix timestamps (FB_IMG_1541234567890), seasons and holidays ("xmas '85").
public enum TextClues {
    public enum Context: Sendable {
        case filename
        case album
        case userHint

        var source: EvidenceSource {
            switch self {
            case .filename: return .filename
            case .album: return .album
            case .userHint: return .groupHint
            }
        }

        /// How much to trust each kind of finding in this context.
        func weight(_ kind: Kind) -> Double {
            switch (self, kind) {
            case (.filename, .fullDate): return 0.9
            case (.filename, .timestamp): return 0.85
            case (.filename, .monthYear): return 0.8
            case (.filename, .range): return 0.7
            case (.filename, .decade): return 0.6
            case (.filename, .approx): return 0.6
            case (.filename, .year): return 0.55
            case (.album, .fullDate): return 0.85
            case (.album, .timestamp): return 0.6
            case (.album, .monthYear): return 0.8
            case (.album, .range): return 0.75
            case (.album, .decade): return 0.7
            case (.album, .approx): return 0.65
            case (.album, .year): return 0.75
            case (.userHint, .fullDate): return 0.95
            case (.userHint, .timestamp): return 0.9
            case (.userHint, .monthYear): return 0.92
            case (.userHint, .range): return 0.9
            case (.userHint, .decade): return 0.85
            case (.userHint, .approx): return 0.85
            case (.userHint, .year): return 0.9
            }
        }

        var seasonWeight: Double {
            switch self {
            case .filename: return 0.6
            case .album: return 0.6
            case .userHint: return 0.9
            }
        }

        var label: String {
            switch self {
            case .filename: return "Filename"
            case .album: return "Album"
            case .userHint: return "Your hint"
            }
        }
    }

    enum Kind { case fullDate, timestamp, monthYear, range, decade, approx, year }

    // MARK: Public entry points

    public static func evidence(fromFilename name: String, now: Date = Date()) -> [DateEvidence] {
        // Drop the extension and anything after it.
        var base = name
        if let dot = base.lastIndex(of: "."), base.distance(from: dot, to: base.endIndex) <= 6 {
            base = String(base[..<dot])
        }
        return parse(base, context: .filename, now: now)
    }

    public static func evidence(fromAlbumName name: String, now: Date = Date()) -> [DateEvidence] {
        parse(name, context: .album, now: now)
    }

    public static func evidence(fromHint text: String, now: Date = Date()) -> [DateEvidence] {
        parse(text, context: .userHint, now: now)
    }

    // MARK: Parser

    static func parse(_ raw: String, context: Context, now: Date) -> [DateEvidence] {
        let text = raw.lowercased()
        let currentYear = YearBounds.currentYear(now: now)
        var consumed: [Range<String.Index>] = []
        var out: [DateEvidence] = []
        let quoted = "“\(raw)”"

        func isFree(_ r: Range<String.Index>) -> Bool { !consumed.contains { $0.overlaps(r) } }
        func add(_ e: DateEvidence, _ r: Range<String.Index>) {
            out.append(e)
            consumed.append(r)
        }
        func plausible(_ y: Int) -> Bool { y >= YearBounds.earliestPhotoYear && y <= currentYear }

        // 1. Unix timestamps (only in filenames, only behind known prefixes or as 13-digit millis).
        if context == .filename {
            for m in matches(#"(?<![0-9])(1[0-9]{9})([0-9]{3})?(?![0-9])"#, in: text) {
                let r = m.range
                guard isFree(r), let secs = Double(m.group(1) ?? "") else { continue }
                let isMillis = m.group(2) != nil
                let prefix = text[text.startIndex..<r.lowerBound]
                let knownPrefix = ["fb_img_", "received_", "img_", "screenshot_", "photo_", "image_", "signal-"]
                    .contains { prefix.hasSuffix($0) }
                guard isMillis || knownPrefix else { continue }
                let date = Date(timeIntervalSince1970: secs)
                guard date <= now, secs >= 946_684_800 else { continue } // after 2000-01-01
                let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
                guard let y = c.year, let mo = c.month else { continue }
                add(DateEvidence(source: context.source,
                                 summary: "\(context.label) contains a timestamp (\(y)-\(pad(mo))-\(pad(c.day ?? 1))) \(quoted)",
                                 yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.timestamp),
                                 season: Season.from(month: mo), seasonWeight: 0.9,
                                 exactMonth: mo, exactDay: c.day), r)
            }
        }

        // 2. Year range: 1975-1980, 1975 to 1980
        for m in matches(#"(?<![0-9])((?:18|19|20)[0-9]{2})\s*(?:-|–|—|to|thru|through|until)\s*((?:18|19|20)[0-9]{2})(?![0-9])"#, in: text) {
            guard isFree(m.range), let a = Int(m.group(1) ?? ""), let b = Int(m.group(2) ?? "") else { continue }
            let lo = min(a, b), hi = max(a, b)
            // "1985-07" style would not reach here (needs 4 digits on both sides); avoid ymd like 2019-2020 being a date.
            guard plausible(lo), plausible(hi), hi - lo <= 40 else { continue }
            add(DateEvidence(source: context.source, summary: "\(context.label) says \(lo)–\(hi) \(quoted)",
                             yearLow: lo, yearHigh: hi, weight: context.weight(.range)), m.range)
        }

        // 3. Full date y-m-d (with or without separators)
        for m in matches(#"(?<![0-9])((?:18|19|20)[0-9]{2})[-_./ ]?(0[1-9]|1[0-2])[-_./ ]?(0[1-9]|[12][0-9]|3[01])(?![0-9])"#, in: text) {
            guard isFree(m.range),
                  let y = Int(m.group(1) ?? ""), let mo = Int(m.group(2) ?? ""), let d = Int(m.group(3) ?? ""),
                  plausible(y), isValidDate(y, mo, d, notAfter: now) else { continue }
            add(fullDate(y, mo, d, context: context, quoted: quoted), m.range)
        }

        // 4. Full date m/d/y or d.m.y with a 4-digit year
        for m in matches(#"(?<![0-9])([0-9]{1,2})[-_./ ]([0-9]{1,2})[-_./ ]((?:18|19|20)[0-9]{2})(?![0-9])"#, in: text) {
            guard isFree(m.range),
                  let a = Int(m.group(1) ?? ""), let b = Int(m.group(2) ?? ""), let y = Int(m.group(3) ?? ""),
                  plausible(y) else { continue }
            // Prefer US month/day; fall back to day/month when the first number can't be a month.
            let (mo, d) = a <= 12 ? (a, b) : (b, a)
            guard isValidDate(y, mo, d, notAfter: now) else { continue }
            var e = fullDate(y, mo, d, context: context, quoted: quoted)
            e.weight = min(e.weight, 0.8)
            add(e, m.range)
        }

        // 5. Month name + year: "july 1985", "jul '85", "dec85"
        let monthPattern = #"(?<![a-z])(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?[ ,_'’-]*((?:18|19|20)[0-9]{2}|[0-9]{2})(?![0-9])"#
        for m in matches(monthPattern, in: text) {
            guard isFree(m.range), let monthWord = m.group(1), let yText = m.group(2),
                  let mo = monthIndex(monthWord) else { continue }
            // Avoid "mar" in "marina" etc. by requiring the full token to be a month name or abbreviation.
            let fullWord = text[m.range].prefix { $0.isLetter }
            guard isMonthWord(String(fullWord)) else { continue }
            // "Dec 12" is more likely the 12th than 2012: two-digit years need an apostrophe or to be > 31.
            if yText.count == 2 {
                let hasApostrophe = text[m.range].contains("'") || text[m.range].contains("’")
                guard hasApostrophe || (Int(yText) ?? 0) > 31 else { continue }
            }
            guard let y = expandYear(yText, currentYear: currentYear), plausible(y) else { continue }
            add(DateEvidence(source: context.source,
                             summary: "\(context.label) mentions \(DateEstimate.monthNames[mo - 1]) \(y) \(quoted)",
                             yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.monthYear),
                             season: Season.from(month: mo), seasonWeight: 0.9, exactMonth: mo), m.range)
        }

        // 6. Decades: "1970s", "70s", "'70s", "early 80s", "mid-1960s", "late 70's"
        for m in matches(#"(?<![a-z0-9])(early|mid|late)?[ -]?(?:((?:18|19|20)[0-9])0|'?’?([0-9])0)'?’?s(?![a-z])"#, in: text) {
            guard isFree(m.range) else { continue }
            var decadeStart: Int?
            if let full = m.group(2), let v = Int(full) { decadeStart = v * 10 }
            else if let d = m.group(3), let v = Int(d) { decadeStart = v <= 1 ? 2000 + v * 10 : 1900 + v * 10 }
            guard let start = decadeStart, plausible(start) || plausible(start + 9) else { continue }
            var lo = start, hi = start + 9
            var label = "the \(start)s"
            switch m.group(1) {
            case "early": hi = start + 4; label = "the early \(start)s"
            case "mid": lo = start + 3; hi = start + 7; label = "the mid \(start)s"
            case "late": lo = start + 6; label = "the late \(start)s"
            default: break
            }
            hi = min(hi, currentYear)
            add(DateEvidence(source: context.source, summary: "\(context.label) suggests \(label) \(quoted)",
                             yearLow: lo, yearHigh: hi, peakYear: (lo + hi) / 2, weight: context.weight(.decade)), m.range)
        }

        // 7. Approximate years: "circa 1975", "c. 1975", "around 1975", "~1975"
        for m in matches(#"(?:circa|ca\.?|c\.|around|about|approx\.?|approximately|~)\s*((?:18|19|20)[0-9]{2})(?![0-9])"#, in: text) {
            guard isFree(m.range), let y = Int(m.group(1) ?? ""), plausible(y) else { continue }
            add(DateEvidence(source: context.source, summary: "\(context.label) says around \(y) \(quoted)",
                             yearLow: y - 2, yearHigh: min(y + 2, currentYear), peakYear: y,
                             weight: context.weight(.approx)), m.range)
        }

        // 8. Holiday/season words followed by a 2-digit year ("xmas 85", "summer '79"), and apostrophe years ("'85").
        for m in matches(#"(?<![a-z])(xmas|christmas|summer|winter|spring|fall|autumn|easter|thanksgiving|halloween|vacation|holiday)[ _'’-]*([0-9]{2})(?![0-9])"#, in: text) {
            guard let yText = m.group(2), let y = expandYear(yText, currentYear: currentYear), plausible(y) else { continue }
            // Only the year part is consumed so the season word still counts below.
            guard let yRange = m.groupRange(2), isFree(yRange) else { continue }
            add(DateEvidence(source: context.source, summary: "\(context.label) mentions ’\(yText) → \(y) \(quoted)",
                             yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.year)), yRange)
        }
        for m in matches(#"['’]([0-9]{2})(?![0-9a-z])"#, in: text) {
            guard isFree(m.range), let yText = m.group(1),
                  let y = expandYear(yText, currentYear: currentYear), plausible(y) else { continue }
            add(DateEvidence(source: context.source, summary: "\(context.label) mentions ’\(yText) → \(y) \(quoted)",
                             yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.year)), m.range)
        }

        // 9. Bare 4-digit years.
        for m in matches(#"(?<![0-9])((?:18|19|20)[0-9]{2})(?![0-9])"#, in: text) {
            guard isFree(m.range), let y = Int(m.group(1) ?? ""), plausible(y) else { continue }
            if context == .filename && followsCounterPrefix(text, before: m.range.lowerBound) { continue }
            add(DateEvidence(source: context.source, summary: "\(context.label) contains the year \(y) \(quoted)",
                             yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.year)), m.range)
        }

        // 10. Holidays and seasons (no year information on their own).
        out.append(contentsOf: seasonalEvidence(in: text, context: context, quoted: quoted))

        return out
    }

    static func fullDate(_ y: Int, _ mo: Int, _ d: Int, context: Context, quoted: String) -> DateEvidence {
        DateEvidence(source: context.source,
                     summary: "\(context.label) contains the date \(y)-\(pad(mo))-\(pad(d)) \(quoted)",
                     yearLow: y, yearHigh: y, peakYear: y, weight: context.weight(.fullDate),
                     season: Season.from(month: mo), seasonWeight: 0.95, exactMonth: mo, exactDay: d)
    }

    // MARK: Seasons & holidays

    struct SeasonalWord {
        let pattern: String
        let label: String
        let season: Season
        let month: Int?
        let strength: Double
    }

    static let seasonalWords: [SeasonalWord] = [
        .init(pattern: "christmas|xmas|x-mas|noel|santa", label: "Christmas", season: .winter, month: 12, strength: 1),
        .init(pattern: "hanukkah|chanukah", label: "Hanukkah", season: .winter, month: 12, strength: 1),
        .init(pattern: "new ?year'?s?(?: eve| day)?|nye", label: "New Year", season: .winter, month: 1, strength: 0.8),
        .init(pattern: "valentine'?s?", label: "Valentine's Day", season: .winter, month: 2, strength: 1),
        .init(pattern: "easter", label: "Easter", season: .spring, month: 4, strength: 1),
        .init(pattern: "mother'?s ?day", label: "Mother's Day", season: .spring, month: 5, strength: 1),
        .init(pattern: "prom", label: "Prom", season: .spring, month: 5, strength: 0.8),
        .init(pattern: "father'?s ?day", label: "Father's Day", season: .summer, month: 6, strength: 1),
        .init(pattern: "graduation|commencement", label: "Graduation", season: .summer, month: 6, strength: 0.6),
        .init(pattern: "4th of july|fourth of july|july 4th|independence day", label: "Fourth of July", season: .summer, month: 7, strength: 1),
        .init(pattern: "halloween|trick or treat", label: "Halloween", season: .fall, month: 10, strength: 1),
        .init(pattern: "thanksgiving", label: "Thanksgiving", season: .fall, month: 11, strength: 1),
        .init(pattern: "back to school|first day of school", label: "Back to school", season: .fall, month: 9, strength: 0.8),
        .init(pattern: "winter|snow|ski(?:ing)?|sledding|snowman", label: "Winter", season: .winter, month: nil, strength: 0.8),
        .init(pattern: "spring|blossoms?", label: "Spring", season: .spring, month: nil, strength: 0.8),
        .init(pattern: "summer|beach|pool|lake ?house|camping", label: "Summer", season: .summer, month: nil, strength: 0.7),
        .init(pattern: "fall|autumn|foliage|pumpkins?|harvest", label: "Fall", season: .fall, month: nil, strength: 0.8),
    ]

    static func seasonalEvidence(in text: String, context: Context, quoted: String) -> [DateEvidence] {
        var out: [DateEvidence] = []
        var seen = Set<String>()
        for word in seasonalWords {
            let pattern = "(?<![a-z])(?:\(word.pattern))(?![a-z])"
            guard !matches(pattern, in: text).isEmpty, !seen.contains(word.label) else { continue }
            seen.insert(word.label)
            let monthNote = word.month.map { " (\(DateEstimate.monthNames[$0 - 1]))" } ?? ""
            out.append(DateEvidence(source: context.source,
                                    summary: "\(context.label) mentions \(word.label)\(monthNote) \(quoted)",
                                    season: word.season,
                                    seasonWeight: context.seasonWeight * word.strength,
                                    exactMonth: word.month))
        }
        return out
    }

    // MARK: Helpers

    /// Camera/scanner counters like IMG_1987 or DSC_2001 are not years.
    static func followsCounterPrefix(_ text: String, before idx: String.Index) -> Bool {
        let prefix = String(text[text.startIndex..<idx])
        let counterPattern = #"(?:^|[^a-z])(img|dsc|dscn|dscf|dsci|dsc0|_mg|mvi|pict|cimg|sam|p10|p[0-9]{2}|dcp|imag|vid|mov|gopr|gh0[0-9]|dji|pxl|hpim|kif|scan|scanned|image|photo|pic|picture|file|copy|edit|untitled|img e|document|page)[ _-]?0*$"#
        return !matches(counterPattern, in: prefix).isEmpty
    }

    static func expandYear(_ text: String, currentYear: Int) -> Int? {
        guard let v = Int(text) else { return nil }
        if text.count == 4 { return v }
        guard text.count == 2 else { return nil }
        let currentTwo = currentYear % 100
        return v > currentTwo ? 1900 + v : 2000 + v
    }

    static func isValidDate(_ y: Int, _ m: Int, _ d: Int, notAfter now: Date) -> Bool {
        guard (1...12).contains(m), (1...31).contains(d) else { return false }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return false }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d && date <= now.addingTimeInterval(86_400)
    }

    static let monthWords: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    static func monthIndex(_ word: String) -> Int? { monthWords[word] }
    static func isMonthWord(_ word: String) -> Bool { monthWords[word] != nil }

    static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    // MARK: Regex plumbing

    struct Match {
        let text: String
        let result: NSTextCheckingResult

        var range: Range<String.Index> { Range(result.range, in: text)! }

        func group(_ i: Int) -> String? {
            guard let r = groupRange(i) else { return nil }
            return String(text[r])
        }

        func groupRange(_ i: Int) -> Range<String.Index>? {
            guard i < result.numberOfRanges else { return nil }
            let ns = result.range(at: i)
            guard ns.location != NSNotFound else { return nil }
            return Range(ns, in: text)
        }
    }

    static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, options: [], range: ns).map { Match(text: text, result: $0) }
    }
}
