import XCTest
@testable import DateGuessCore

final class TextCluesTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    func years(_ e: [DateEvidence]) -> [ClosedRange<Int>] {
        e.compactMap { ev in
            guard let lo = ev.yearLow, let hi = ev.yearHigh else { return nil }
            return lo...hi
        }
    }

    func testFullDateInFilename() {
        let e = TextClues.evidence(fromFilename: "IMG_20190704_153012.jpg", now: now)
        let full = e.first { $0.exactDay != nil }
        XCTAssertEqual(full?.yearLow, 2019)
        XCTAssertEqual(full?.exactMonth, 7)
        XCTAssertEqual(full?.exactDay, 4)
    }

    func testCameraCounterIsNotAYear() {
        XCTAssertTrue(years(TextClues.evidence(fromFilename: "IMG_1987.JPG", now: now)).isEmpty)
        XCTAssertTrue(years(TextClues.evidence(fromFilename: "DSC_2001.jpg", now: now)).isEmpty)
        XCTAssertTrue(years(TextClues.evidence(fromFilename: "Scan_1985.jpg", now: now)).isEmpty)
    }

    func testBareYearAndDecade() {
        XCTAssertEqual(years(TextClues.evidence(fromAlbumName: "Grandma 1965", now: now)), [1965...1965])
        XCTAssertEqual(years(TextClues.evidence(fromAlbumName: "Late 70s", now: now)), [1976...1979])
        XCTAssertEqual(years(TextClues.evidence(fromHint: "the 1950s", now: now)), [1950...1959])
        XCTAssertEqual(years(TextClues.evidence(fromHint: "circa 1975", now: now)), [1973...1977])
    }

    func testHolidayWithTwoDigitYear() {
        let e = TextClues.evidence(fromFilename: "xmas 85 tree.jpg", now: now)
        XCTAssertEqual(years(e), [1985...1985])
        XCTAssertTrue(e.contains { $0.exactMonth == 12 && $0.season == .winter })
    }

    func testMonthNameYear() {
        let e = TextClues.evidence(fromAlbumName: "July 1979 Lake trip", now: now)
        XCTAssertTrue(e.contains { $0.yearLow == 1979 && $0.exactMonth == 7 })
        // "Dec 12" is a day, not a year.
        XCTAssertTrue(years(TextClues.evidence(fromAlbumName: "Party Dec 12", now: now)).isEmpty)
    }

    func testRange() {
        XCTAssertEqual(years(TextClues.evidence(fromAlbumName: "Photos 1975-1980", now: now)), [1975...1980])
    }

    func testFutureYearIgnored() {
        XCTAssertTrue(years(TextClues.evidence(fromAlbumName: "Plans 2099", now: now)).isEmpty)
    }

    func testFacebookTimestamp() {
        let e = TextClues.evidence(fromFilename: "FB_IMG_1541234567890.jpg", now: now)
        XCTAssertEqual(e.first?.yearLow, 2018)
        XCTAssertEqual(e.first?.exactMonth, 11)
    }
}

final class FusionTests: XCTestCase {
    let options = EvidenceFusion.Options(maxYear: 2026)

    func testAgreeingCluesNarrow() {
        let evidence = [
            DateEvidence(source: .aiOverall, summary: "", yearLow: 1970, yearHigh: 1980, peakYear: 1975, weight: 0.8),
            DateEvidence(source: .colorTone, summary: "", yearLow: 1958, yearHigh: 1985, peakYear: 1972, weight: 0.3),
        ]
        let est = EvidenceFusion.estimate(from: evidence, options: options)
        XCTAssert((1972...1977).contains(est.year), "\(est.year)")
        XCTAssertGreaterThanOrEqual(est.yearLow, 1965)
        XCTAssertLessThanOrEqual(est.yearHigh, 1985)
    }

    func testPrintedDateWins() {
        let evidence = [
            DateEvidence(source: .aiOverall, summary: "", yearLow: 1975, yearHigh: 1985, peakYear: 1980, weight: 0.6),
            DateEvidence(source: .printedDate, summary: "", yearLow: 1983, yearHigh: 1983, peakYear: 1983, weight: 0.93,
                         season: .summer, seasonWeight: 0.95, exactMonth: 7),
        ]
        let est = EvidenceFusion.estimate(from: evidence, options: options)
        XCTAssertEqual(est.year, 1983)
        XCTAssertEqual(est.month, 7)
        XCTAssertTrue(est.usedExactMonth)
        XCTAssertEqual(est.confidenceLevel, .high)
    }

    func testHardConstraint() {
        let evidence = [
            DateEvidence(source: .aiOverall, summary: "", yearLow: 1960, yearHigh: 1975, peakYear: 1965, weight: 0.7),
            PeopleClues.presence(of: PersonInfo(name: "Ann", birthYear: 1970)),
        ]
        let est = EvidenceFusion.estimate(from: evidence, options: options)
        XCTAssertGreaterThanOrEqual(est.year, 1970)
    }

    func testSeasonMapping() {
        let e = [DateEvidence(source: .scene, summary: "", season: .fall, seasonWeight: 0.6)]
        let est = EvidenceFusion.estimate(from: e, options: options)
        XCTAssertEqual(est.season, .fall)
        XCTAssertEqual(est.month, 9)
        let none = EvidenceFusion.estimate(from: [], options: options)
        XCTAssertEqual(none.month, 6)
        XCTAssertTrue(none.seasonIsDefault)
        XCTAssertFalse(none.hasAnyEvidence)
        XCTAssertEqual(none.confidenceLevel, .low)
    }

    func testHolidaySetsMonth() {
        let e = [
            DateEvidence(source: .album, summary: "", yearLow: 1985, yearHigh: 1985, weight: 0.75),
            DateEvidence(source: .filename, summary: "", season: .winter, seasonWeight: 0.6, exactMonth: 12),
        ]
        let est = EvidenceFusion.estimate(from: e, options: options)
        XCTAssertEqual(est.year, 1985)
        XCTAssertEqual(est.month, 12)
    }

    func testPeopleAge() {
        let person = PersonInfo(name: "Ben", birthYear: 1960)
        let e = [PeopleClues.age(of: person, ageLow: 8, ageHigh: 10, matchConfidence: 0.9)]
        let est = EvidenceFusion.estimate(from: e, options: options)
        XCTAssert((1967...1971).contains(est.year), "\(est.year)")
    }

    func testSameEventGroupSharesDate() {
        let members = [
            GroupFusion.Member(assetID: "a", evidence: [DateEvidence(source: .aiOverall, summary: "", yearLow: 1970, yearHigh: 1976, peakYear: 1973, weight: 0.7)]),
            GroupFusion.Member(assetID: "b", evidence: [DateEvidence(source: .aiOverall, summary: "", yearLow: 1972, yearHigh: 1978, peakYear: 1975, weight: 0.7)]),
            GroupFusion.Member(assetID: "c", evidence: []),
        ]
        let hint = TextClues.evidence(fromHint: "summer of 1974")
        let result = GroupFusion.estimates(members: members, groupEvidence: hint, kind: .sameEvent, options: options)
        XCTAssertEqual(Set(result.values.map(\.year)), [1974])
        XCTAssertEqual(result["c"]?.season, .summer)
    }

    func testSameEraNudges() {
        let members = [
            GroupFusion.Member(assetID: "a", evidence: [DateEvidence(source: .aiOverall, summary: "", yearLow: 1960, yearHigh: 1990, weight: 0.5)]),
            GroupFusion.Member(assetID: "b", evidence: [DateEvidence(source: .printedDate, summary: "", yearLow: 1968, yearHigh: 1968, weight: 0.93)]),
        ]
        let result = GroupFusion.estimates(members: members, groupEvidence: [], kind: .sameEra, options: options)
        XCTAssertEqual(result["b"]?.year, 1968)
        XCTAssert((1964...1972).contains(result["a"]!.year), "\(result["a"]!.year)")
    }
}

final class DetectionTests: XCTestCase {
    func testMissingAndDefaultDates() {
        XCTAssertEqual(UndatedDetector.fastCheck(creationDate: nil), .missingDate)
        XCTAssertEqual(UndatedDetector.fastCheck(creationDate: Date(timeIntervalSince1970: 0)), .implausibleDate)
        XCTAssertNil(UndatedDetector.fastCheck(creationDate: Date(timeIntervalSince1970: 1_000_000_123)))
    }

    func testEmbedded() {
        XCTAssertEqual(UndatedDetector.embeddedCheck(EmbeddedDateInfo()), .noCaptureDateInFile)
        XCTAssertNil(UndatedDetector.embeddedCheck(EmbeddedDateInfo(dateTimeOriginal: "2004:06:01 10:00:00", make: "Canon")))
        XCTAssertEqual(UndatedDetector.embeddedCheck(EmbeddedDateInfo(dateTimeOriginal: "2020:01:01 10:00:00",
                                                                      dateTimeDigitized: "2020:01:01 10:00:00",
                                                                      make: "EPSON", model: "FastFoto FF-680W")), .scannerDate)
    }

    func testFormatClues() {
        let heic = FormatClues.evidence(for: FormatInfo(originalFilename: "IMG_0001.HEIC", uniformTypeIdentifier: "public.heic"))
        XCTAssertTrue(heic.contains { $0.isHardConstraint && $0.yearLow == 2017 })
        XCTAssertEqual(FormatClues.iPhoneReleaseYear("iPhone 6s Plus"), 2015)
        XCTAssertEqual(FormatClues.iPhoneReleaseYear("iPhone XR"), 2018)
        XCTAssertEqual(FormatClues.iPhoneReleaseYear("iPhone 11 Pro"), 2019)
    }

    func testGroupSuggestions() {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let candidates = (1...6).map { i in
            GroupCandidate(assetID: "id\(i)", filename: String(format: "Scan_%04d.jpg", i),
                           libraryDate: base.addingTimeInterval(Double(i) * 30), albums: i < 3 ? ["Box 3"] : [])
        }
        let suggestions = GroupSuggester.suggest(candidates)
        XCTAssertTrue(suggestions.contains { $0.assetIDs.count == 6 })
        XCTAssertTrue(suggestions.contains { $0.title == "Box 3" && $0.assetIDs.count == 2 })
    }
}

final class VisualTests: XCTestCase {
    func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                out[i] = r; out[i + 1] = g; out[i + 2] = b
            }
        }
        return out
    }

    func testMonochromeWithWhiteBorder() {
        let w = 100, h = 100
        let px = image(width: w, height: h) { x, y in
            if x < 6 || x >= 94 || y < 6 || y >= 94 { return (250, 250, 250) }
            let v = UInt8((x * 2 + y) % 200 + 20)
            return (v, v, v)
        }
        let s = ImageStatistics.compute(rgba: px, width: w, height: h)
        XCTAssertTrue(s.isMonochrome)
        XCTAssertEqual(s.border.tone, .light)
        XCTAssertGreaterThanOrEqual(s.border.sidesWithBorder, 3)
        XCTAssertTrue(VisualClues.evidence(from: s).contains { $0.source == .colorTone })
    }

    func testColorful() {
        let px = image(width: 64, height: 48) { x, y in (UInt8(x * 4), UInt8(y * 5), UInt8(255 - x * 3)) }
        let s = ImageStatistics.compute(rgba: px, width: 64, height: 48)
        XCTAssertFalse(s.isMonochrome)
        XCTAssertFalse(s.isSepia)
    }
}

final class ClaudeParsingTests: XCTestCase {
    func testParseResponse() throws {
        let inner = """
        {"photos":[{"photo_id":"P1","best_year":1974,"year_low":1970,"year_high":1978,"confidence":0.7,
        "season":"summer","season_confidence":0.8,"season_reason":"beach","is_scanned_print":true,
        "printed_or_written_date":{"text":"JUL 74","year":1974,"month":7},
        "clues":[{"category":"clothing_fashion","observation":"bell-bottoms","year_low":1968,"year_high":1978}],
        "people":[{"name":"Ann","apparent_age_low":4,"apparent_age_high":6,"match_confidence":0.8}],
        "summary":"1970s beach snapshot"}]}
        """
        let outer: [String: Any] = [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": inner]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 1000, "output_tokens": 500],
        ]
        let data = try JSONSerialization.data(withJSONObject: outer)
        let (results, usage) = try ClaudeClient.parse(data)
        XCTAssertEqual(usage.inputTokens, 1000)
        let r = try XCTUnwrap(results["P1"])
        XCTAssertEqual(r.printedOrWrittenDate?.month, 7)

        let people = [PersonInfo(name: "Ann", birthYear: 1969)]
        let evidence = AIEvidenceMapper.evidence(from: r, people: people, libraryDate: nil)
        let est = EvidenceFusion.estimate(from: evidence, options: .init(maxYear: 2026))
        XCTAssertEqual(est.year, 1974)
        XCTAssertEqual(est.month, 7)
    }

    func testRefusal() throws {
        let outer: [String: Any] = ["content": [] as [Any], "stop_reason": "refusal", "stop_details": ["category": "other"]]
        let data = try JSONSerialization.data(withJSONObject: outer)
        XCTAssertThrowsError(try ClaudeClient.parse(data))
    }

    func testRequestBodyIsValidJSON() throws {
        let client = ClaudeClient(apiKey: "x", settings: AISettings(enabled: true))
        let body = client.requestBody(photos: [AIPhotoInput(promptID: "P1", context: "Filename: a.jpg", jpegData: Data([1, 2, 3]))],
                                      references: [AIReferenceImage(personName: "Ann", note: "age 10", jpegData: Data([4]))],
                                      groupContext: nil)
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
    }
}
