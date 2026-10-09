import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Settings

public struct AIModelOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var blurb: String
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    /// Server-side refusal fallback (`fallbacks: "default"`) is available for this model on the Claude API.
    public var supportsServerFallback: Bool

    public static let all: [AIModelOption] = [
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", blurb: "Most accurate (default)",
              inputPerMTok: 4.00, outputPerMTok: 20.00, supportsServerFallback: true),
        .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", blurb: "Balanced cost and accuracy",
              inputPerMTok: 2.00, outputPerMTok: 10.00, supportsServerFallback: true),
        .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", blurb: "Cheapest, good for very large batches",
              inputPerMTok: 0.10, outputPerMTok: 0.50, supportsServerFallback: false),
    ]

    public static let defaultID = "claude-opus-5-5"

    public static func option(for id: String) -> AIModelOption {
        all.first { $0.id == id } ?? all[0]
    }
}

public struct AISettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var model: String
    /// "low", "medium" or "high".
    public var effort: String
    /// Long edge in pixels of images sent for analysis.
    public var imageMaxEdge: Int
    public var photosPerRequest: Int
    public var concurrentRequests: Int

    public init(enabled: Bool = false, model: String = AIModelOption.defaultID, effort: String = "medium",
                imageMaxEdge: Int = 1024, photosPerRequest: Int = 6, concurrentRequests: Int = 3) {
        self.enabled = enabled
        self.model = model
        self.effort = effort
        self.imageMaxEdge = imageMaxEdge
        self.photosPerRequest = photosPerRequest
        self.concurrentRequests = concurrentRequests
    }

    /// Rough cost in US dollars for `photoCount` photos.
    public func estimatedCost(photoCount: Int, referenceImages: Int = 0) -> Double {
        let option = AIModelOption.option(for: model)
        let edge = Double(imageMaxEdge)
        let imageTokens = edge * edge * 0.75 / 750
        let perPhotoInput = imageTokens + 300
        let perPhotoOutput = effort == "low" ? 450.0 : effort == "high" ? 1400.0 : 800.0
        let requests = Double(photoCount) / Double(max(1, photosPerRequest))
        // System prompt + reference images: written to cache once, then read at ~10% price.
        let referenceTokens = Double(referenceImages) * 400 + 1500
        let input = Double(photoCount) * perPhotoInput + requests * referenceTokens * 0.15
        let output = Double(photoCount) * perPhotoOutput
        return input / 1_000_000 * option.inputPerMTok + output / 1_000_000 * option.outputPerMTok
    }
}

// MARK: - Request inputs

public struct AIPhotoInput: Sendable {
    /// Short ID used in the prompt (e.g. "P3"); mapped back to the asset by the caller.
    public var promptID: String
    public var context: String
    public var jpegData: Data

    public init(promptID: String, context: String, jpegData: Data) {
        self.promptID = promptID
        self.context = context
        self.jpegData = jpegData
    }
}

public struct AIReferenceImage: Sendable {
    public var personName: String
    public var note: String
    public var jpegData: Data

    public init(personName: String, note: String, jpegData: Data) {
        self.personName = personName
        self.note = note
        self.jpegData = jpegData
    }
}

// MARK: - Response model

public struct AIPhotoResult: Codable, Hashable, Sendable {
    public struct PrintedDate: Codable, Hashable, Sendable {
        public var text: String
        public var year: Int?
        public var month: Int?
    }

    public struct Clue: Codable, Hashable, Sendable {
        public var category: String
        public var observation: String
        public var yearLow: Int
        public var yearHigh: Int
    }

    public struct PersonSighting: Codable, Hashable, Sendable {
        public var name: String
        public var apparentAgeLow: Int
        public var apparentAgeHigh: Int
        public var matchConfidence: Double
    }

    public var photoId: String
    public var bestYear: Int
    public var yearLow: Int
    public var yearHigh: Int
    public var confidence: Double
    public var season: String
    public var seasonConfidence: Double
    public var seasonReason: String
    public var isScannedPrint: Bool
    public var printedOrWrittenDate: PrintedDate?
    public var clues: [Clue]
    public var people: [PersonSighting]
    public var summary: String
}

struct AIBatchPayload: Codable {
    var photos: [AIPhotoResult]
}

public struct AIUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadInputTokens: Int = 0
    public var cacheCreationInputTokens: Int = 0

    public init() {}

    public mutating func add(_ other: AIUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
    }

    public func cost(model: String) -> Double {
        let o = AIModelOption.option(for: model)
        let input = Double(inputTokens) + Double(cacheCreationInputTokens) * 1.25 + Double(cacheReadInputTokens) * 0.1
        return input / 1_000_000 * o.inputPerMTok + Double(outputTokens) / 1_000_000 * o.outputPerMTok
    }
}

public enum ClaudeError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal(category: String?)
    case truncated
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Anthropic API key in Settings to use visual analysis."
        case let .http(status, message): return "Claude API error \(status): \(message)"
        case let .refusal(category): return "Claude declined to analyze this batch\(category.map { " (\($0))" } ?? "")."
        case .truncated: return "The response was cut off before it finished."
        case let .invalidResponse(detail): return "Unexpected response from Claude: \(detail)"
        }
    }

    public var isRetryable: Bool {
        if case let .http(status, _) = self { return status == 408 || status == 429 || status >= 500 }
        return false
    }
}

// MARK: - Prompt

public enum DatingPrompt {
    public static let system = """
    You are an expert photo archivist and social historian. Your job is to estimate when family photographs \
    were taken, as precisely as the evidence allows, for photos that have lost their dates.

    Use every available clue and say which ones you used:
    - Printed or written dates: orange/red LCD date imprints in a corner (1980s–2000s cameras), photofinisher \
    stamps on borders or backs (e.g. "MAR 72", "WEEK OF JUN 3 1968"), handwriting on the print. These are the \
    strongest clues; read them carefully and report them in printed_or_written_date.
    - Fashion: clothing cuts, fabrics, patterns, collars, lapels, hemlines, swimwear, uniforms.
    - Hair and grooming: hairstyles, facial hair, makeup, eyeglass frames.
    - Accessories, jewelry, watches, toys, product packaging, signage, logos and their versions.
    - Technology: phones, TVs, radios, computers, game consoles, cameras, appliances.
    - Vehicles: makes, models and model years; license plate styles.
    - Architecture and interiors: wallpaper, paneling, carpet, furniture, kitchen colors, lighting.
    - Photographic medium: black & white vs. color, color palette and dye fading (magenta/red shift of faded \
    1960s–80s prints), sepia, tintypes/cabinet cards, print borders (deckled/scalloped edges ~1940s–60s, white \
    borders, rounded corners), Polaroid/instant frames, paper texture and sheen, square 126/Instamatic prints, \
    aspect ratios (3.5×5, 4×6, panoramic APS), film grain, digital-camera look.
    - Season: snow, bare trees, foliage colors, blossoms, holiday decorations, clothing weight, beach scenes.
    - The context text: filenames, album names, the user's group hints, and on-device observations.
    - Known people: if reference photos of people are provided, say which of them appear and estimate their \
    apparent age in this photo. Only name someone if they reasonably resemble the reference; otherwise leave \
    them out.

    Be calibrated. year_low–year_high should contain the true year about 80% of the time; widen it when \
    clues are weak. confidence is 0–1 for how sure you are the best_year is within ±2 years. Use \
    season "unknown" when there are no seasonal clues. Never invent details you cannot see. Write \
    observations as short phrases a family member would understand.
    """

    public static let clueCategories = [
        "printed_date", "filename_or_album", "clothing_fashion", "hair_grooming", "accessories", "technology",
        "vehicles", "architecture_interior", "objects_products", "color_tone", "border_paper", "format_aspect",
        "people_age", "season", "other",
    ]

    public typealias JSON = [String: Any]

    public static var schema: JSON {
        func nullable(_ type: String) -> JSON { ["anyOf": [["type": type], ["type": "null"]]] }
        let clue: JSON = [
            "type": "object", "additionalProperties": false,
            "required": ["category", "observation", "year_low", "year_high"],
            "properties": [
                "category": ["type": "string", "enum": clueCategories] as JSON,
                "observation": ["type": "string"],
                "year_low": ["type": "integer"],
                "year_high": ["type": "integer"],
            ] as JSON,
        ]
        let person: JSON = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "apparent_age_low", "apparent_age_high", "match_confidence"],
            "properties": [
                "name": ["type": "string"],
                "apparent_age_low": ["type": "integer"],
                "apparent_age_high": ["type": "integer"],
                "match_confidence": ["type": "number"],
            ] as JSON,
        ]
        let printedObject: JSON = [
            "type": "object", "additionalProperties": false,
            "required": ["text", "year", "month"],
            "properties": ["text": ["type": "string"], "year": nullable("integer"), "month": nullable("integer")] as JSON,
        ]
        let printed: JSON = ["anyOf": [["type": "null"] as JSON, printedObject]]
        let photo: JSON = [
            "type": "object", "additionalProperties": false,
            "required": ["photo_id", "best_year", "year_low", "year_high", "confidence", "season", "season_confidence",
                         "season_reason", "is_scanned_print", "printed_or_written_date", "clues", "people", "summary"],
            "properties": [
                "photo_id": ["type": "string"],
                "best_year": ["type": "integer"],
                "year_low": ["type": "integer"],
                "year_high": ["type": "integer"],
                "confidence": ["type": "number"],
                "season": ["type": "string", "enum": ["winter", "spring", "summer", "fall", "unknown"]] as JSON,
                "season_confidence": ["type": "number"],
                "season_reason": ["type": "string"],
                "is_scanned_print": ["type": "boolean"],
                "printed_or_written_date": printed,
                "clues": ["type": "array", "items": clue] as JSON,
                "people": ["type": "array", "items": person] as JSON,
                "summary": ["type": "string"],
            ] as JSON,
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["photos"],
            "properties": ["photos": ["type": "array", "items": photo] as JSON] as JSON,
        ]
    }

    /// Builds the user-message content blocks for one request.
    static func contentBlocks(photos: [AIPhotoInput], references: [AIReferenceImage], groupContext: String?) -> [JSON] {
        var blocks: [JSON] = []
        if !references.isEmpty {
            blocks.append(text("Reference photos of people the user identified. Use them to recognize these people below and judge their age."))
            for (i, ref) in references.enumerated() {
                blocks.append(text("Reference: \(ref.personName)\(ref.note.isEmpty ? "" : " — \(ref.note)")"))
                var img = image(ref.jpegData)
                // Cache the stable prefix (system prompt + references) across all batches.
                if i == references.count - 1 { img["cache_control"] = ["type": "ephemeral"] }
                blocks.append(img)
            }
        }
        if let groupContext, !groupContext.isEmpty {
            blocks.append(text(groupContext))
        } else {
            blocks.append(text("Date each of the following photos independently (they are not known to be related)."))
        }
        for p in photos {
            blocks.append(text("Photo \(p.promptID)\n\(p.context)"))
            blocks.append(image(p.jpegData))
        }
        let ids = photos.map(\.promptID).joined(separator: ", ")
        blocks.append(text("Return one entry per photo (\(ids)) using exactly those photo_id values."))
        return blocks
    }

    static func text(_ s: String) -> JSON { ["type": "text", "text": s] }

    static func image(_ data: Data) -> JSON {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
    }
}

// MARK: - Client

/// Minimal Claude Messages API client (raw HTTPS; there is no official Swift SDK).
public final class ClaudeClient: Sendable {
    public let apiKey: String
    public let settings: AISettings
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let session: URLSession

    public init(apiKey: String, settings: AISettings, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.settings = settings
        self.session = session
    }

    public func requestBody(photos: [AIPhotoInput], references: [AIReferenceImage], groupContext: String?) -> DatingPrompt.JSON {
        let option = AIModelOption.option(for: settings.model)
        typealias JSON = DatingPrompt.JSON
        let systemBlock: JSON = ["type": "text", "text": DatingPrompt.system, "cache_control": ["type": "ephemeral"]]
        let message: JSON = [
            "role": "user",
            "content": DatingPrompt.contentBlocks(photos: photos, references: references, groupContext: groupContext),
        ]
        let format: JSON = ["type": "json_schema", "schema": DatingPrompt.schema]
        let outputConfig: JSON = ["effort": settings.effort, "format": format]
        var body: JSON = [
            "model": settings.model,
            "max_tokens": 16000,
            "system": [systemBlock],
            "messages": [message],
            "output_config": outputConfig,
        ]
        if option.supportsServerFallback { body["fallbacks"] = "default" }
        return body
    }

    /// Sends one batch and returns results keyed by prompt ID.
    public func analyze(photos: [AIPhotoInput], references: [AIReferenceImage], groupContext: String?) async throws -> ([String: AIPhotoResult], AIUsage) {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        let body = requestBody(photos: photos, references: references, groupContext: groupContext)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let option = AIModelOption.option(for: settings.model)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if option.supportsServerFallback {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = bodyData

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse("no HTTP response") }
                guard http.statusCode == 200 else {
                    let message = Self.errorMessage(from: data)
                    let error = ClaudeError.http(status: http.statusCode, message: message)
                    if error.isRetryable && attempt < 6 {
                        let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0
                        try await Self.backoff(attempt: attempt, minimum: retryAfter)
                        continue
                    }
                    throw error
                }
                return try Self.parse(data)
            } catch let error as URLError where attempt < 6 && error.code != .cancelled {
                try await Self.backoff(attempt: attempt, minimum: 0)
            }
        }
    }

    static func backoff(attempt: Int, minimum: Double) async throws {
        let delay = max(minimum, pow(2, Double(attempt)) + Double.random(in: 0...1))
        try await Task.sleep(nanoseconds: UInt64(min(delay, 90) * 1_000_000_000))
    }

    struct RawResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        struct StopDetails: Decodable { var category: String? }
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreationInputTokens: Int?
        }
        var content: [Block]
        var stopReason: String?
        var stopDetails: StopDetails?
        var usage: Usage?
    }

    static func parse(_ data: Data) throws -> ([String: AIPhotoResult], AIUsage) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw: RawResponse
        do { raw = try decoder.decode(RawResponse.self, from: data) } catch {
            throw ClaudeError.invalidResponse("could not read response (\(error.localizedDescription))")
        }
        var usage = AIUsage()
        usage.inputTokens = raw.usage?.inputTokens ?? 0
        usage.outputTokens = raw.usage?.outputTokens ?? 0
        usage.cacheReadInputTokens = raw.usage?.cacheReadInputTokens ?? 0
        usage.cacheCreationInputTokens = raw.usage?.cacheCreationInputTokens ?? 0

        if raw.stopReason == "refusal" { throw ClaudeError.refusal(category: raw.stopDetails?.category) }
        if raw.stopReason == "max_tokens" { throw ClaudeError.truncated }
        guard let text = raw.content.last(where: { $0.type == "text" })?.text, let json = text.data(using: .utf8) else {
            throw ClaudeError.invalidResponse("no text block")
        }
        let payload: AIBatchPayload
        do { payload = try decoder.decode(AIBatchPayload.self, from: json) } catch {
            throw ClaudeError.invalidResponse("JSON did not match the schema (\(error.localizedDescription))")
        }
        var byID: [String: AIPhotoResult] = [:]
        for p in payload.photos { byID[p.photoId] = p }
        return (byID, usage)
    }

    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable { struct E: Decodable { var message: String? }; var error: E? }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data), let m = env.error?.message { return m }
        return String(data: data.prefix(300), encoding: .utf8) ?? "unknown error"
    }
}

// MARK: - Mapping AI results to evidence

public enum AIEvidenceMapper {
    public static func evidence(from r: AIPhotoResult, people: [PersonInfo], libraryDate: Date?, now: Date = Date()) -> [DateEvidence] {
        let current = YearBounds.currentYear(now: now)
        func clamp(_ y: Int) -> Int { max(YearBounds.earliestPhotoYear, min(current, y)) }
        var out: [DateEvidence] = []

        let lo = clamp(min(r.yearLow, r.yearHigh)), hi = clamp(max(r.yearLow, r.yearHigh))
        let best = max(lo, min(hi, clamp(r.bestYear)))
        let conf = max(0, min(1, r.confidence))
        let season = Season(rawValue: r.season)
        out.append(DateEvidence(source: .aiOverall, summary: r.summary,
                                yearLow: lo, yearHigh: hi, peakYear: best, weight: 0.35 + 0.55 * conf,
                                season: season, seasonWeight: season == nil ? 0 : max(0, min(1, r.seasonConfidence)) * 0.9))
        if let season, !r.seasonReason.isEmpty {
            out.append(DateEvidence(source: .scene, summary: "\(season.displayName): \(r.seasonReason)"))
        }

        if let printed = r.printedOrWrittenDate, let y = printed.year, YearBounds.isPlausible(y, now: now) {
            let month = printed.month.flatMap { (1...12).contains($0) ? $0 : nil }
            out.append(DateEvidence(source: .printedDate, summary: "Date printed or written on the photo: “\(printed.text)”",
                                    yearLow: y, yearHigh: y, peakYear: y, weight: 0.93,
                                    season: month.map(Season.from(month:)), seasonWeight: month == nil ? 0 : 0.95,
                                    exactMonth: month))
        } else if let printed = r.printedOrWrittenDate, !printed.text.isEmpty {
            out.append(DateEvidence(source: .printedDate, summary: "Text on the photo: “\(printed.text)”"))
        }

        for clue in r.clues {
            let label = clue.category.replacingOccurrences(of: "_", with: " ").capitalized
            let range = clue.yearLow == clue.yearHigh ? "\(clue.yearLow)" : "\(clue.yearLow)–\(clue.yearHigh)"
            out.append(DateEvidence(source: .aiClue, summary: "\(label): \(clue.observation) (\(range))"))
        }

        for sighting in r.people {
            let name = sighting.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard let person = people.first(where: { $0.name.lowercased() == name }) else { continue }
            if sighting.matchConfidence >= 0.6 { out.append(PeopleClues.presence(of: person)) }
            if sighting.matchConfidence >= 0.4 {
                out.append(PeopleClues.age(of: person, ageLow: sighting.apparentAgeLow, ageHigh: sighting.apparentAgeHigh,
                                           matchConfidence: sighting.matchConfidence))
            }
        }

        if !r.isScannedPrint, let libraryDate {
            let y = Calendar.current.component(.year, from: libraryDate)
            if y >= lo - 1 && y <= hi + 1 {
                out.append(DateEvidence(source: .libraryDate,
                                        summary: "Looks born-digital rather than a scanned print, so the library date (\(y)) is probably close",
                                        yearLow: y - 1, yearHigh: y, peakYear: y, weight: 0.5))
            }
        }
        return out
    }
}
