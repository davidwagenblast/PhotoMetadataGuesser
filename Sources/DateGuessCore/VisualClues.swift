import Foundation

/// Simple statistics computed from a small RGBA rendering of a photo.
/// These capture the "look" of old prints: black & white, sepia, faded dyes, borders, square formats.
public struct ImageStatistics: Codable, Hashable, Sendable {
    public var meanR: Double
    public var meanG: Double
    public var meanB: Double
    public var meanChroma: Double
    public var chroma95: Double
    public var colorfulness: Double
    public var luminanceStdDev: Double
    public var warmHueFraction: Double
    public var isMonochrome: Bool
    public var isSepia: Bool
    public var magentaCast: Double
    public var yellowCast: Double
    public var border: BorderInfo
    /// Aspect ratio of the picture area (long side / short side), excluding detected borders.
    public var contentAspect: Double

    public init(meanR: Double, meanG: Double, meanB: Double, meanChroma: Double, chroma95: Double,
                colorfulness: Double, luminanceStdDev: Double, warmHueFraction: Double,
                isMonochrome: Bool, isSepia: Bool, magentaCast: Double, yellowCast: Double,
                border: BorderInfo, contentAspect: Double) {
        self.meanR = meanR
        self.meanG = meanG
        self.meanB = meanB
        self.meanChroma = meanChroma
        self.chroma95 = chroma95
        self.colorfulness = colorfulness
        self.luminanceStdDev = luminanceStdDev
        self.warmHueFraction = warmHueFraction
        self.isMonochrome = isMonochrome
        self.isSepia = isSepia
        self.magentaCast = magentaCast
        self.yellowCast = yellowCast
        self.border = border
        self.contentAspect = contentAspect
    }
}

public struct BorderInfo: Codable, Hashable, Sendable {
    public enum Tone: String, Codable, Sendable { case none, light, dark }
    /// Border thickness on each side as a fraction of that dimension (0 if none).
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double
    public var tone: Tone

    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0, tone: Tone = .none) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.tone = tone
    }

    public var sidesWithBorder: Int { [top, bottom, left, right].filter { $0 > 0.012 }.count }

    /// Instant-film look: a much thicker bottom margin than top.
    public var isBottomHeavy: Bool { tone == .light && sidesWithBorder >= 3 && bottom > 0.06 && bottom > top * 2.2 }
}

extension ImageStatistics {
    /// Computes statistics from tightly packed 8-bit RGBA(X) pixels.
    public static func compute(rgba: [UInt8], width: Int, height: Int) -> ImageStatistics {
        precondition(rgba.count >= width * height * 4, "buffer too small")
        let n = max(1, width * height)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var sumLum = 0.0, sumLum2 = 0.0
        var sumChroma = 0.0
        var chromaHist = [Int](repeating: 0, count: 101)
        var rgSum = 0.0, rg2 = 0.0, ybSum = 0.0, yb2 = 0.0
        var tintedCount = 0, warmCount = 0

        for i in 0..<n {
            let r = Double(rgba[i * 4]) / 255, g = Double(rgba[i * 4 + 1]) / 255, b = Double(rgba[i * 4 + 2]) / 255
            sumR += r; sumG += g; sumB += b
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            sumLum += lum; sumLum2 += lum * lum
            let mx = max(r, g, b), mn = min(r, g, b)
            let chroma = mx - mn
            sumChroma += chroma
            chromaHist[min(100, Int(chroma * 100))] += 1
            let rg = (r - g) * 255, yb = (0.5 * (r + g) - b) * 255
            rgSum += rg; rg2 += rg * rg; ybSum += yb; yb2 += yb * yb
            if chroma > 0.03 {
                tintedCount += 1
                let h = hue(r, g, b, mx, chroma)
                if h >= 15 && h <= 60 { warmCount += 1 }
            }
        }
        let dn = Double(n)
        let meanLum = sumLum / dn
        let lumStd = max(0, sumLum2 / dn - meanLum * meanLum).squareRoot()
        let meanChroma = sumChroma / dn
        var acc = 0, chroma95 = 1.0
        for (i, c) in chromaHist.enumerated() {
            acc += c
            if Double(acc) >= dn * 0.95 { chroma95 = Double(i) / 100; break }
        }
        let rgMean = rgSum / dn, ybMean = ybSum / dn
        let rgStd = max(0, rg2 / dn - rgMean * rgMean).squareRoot()
        let ybStd = max(0, yb2 / dn - ybMean * ybMean).squareRoot()
        let colorfulness = (rgStd * rgStd + ybStd * ybStd).squareRoot() + 0.3 * (rgMean * rgMean + ybMean * ybMean).squareRoot()

        let mR = sumR / dn, mG = sumG / dn, mB = sumB / dn
        let warmFraction = tintedCount > 0 ? Double(warmCount) / Double(tintedCount) : 0
        let isMono = meanChroma < 0.035 && chroma95 <= 0.10
        let isSepia = !isMono && meanChroma < 0.16 && chroma95 <= 0.28 && warmFraction > 0.85 && colorfulness < 30

        let border = detectBorder(rgba: rgba, width: width, height: height)
        let contentW = Double(width) * (1 - border.left - border.right)
        let contentH = Double(height) * (1 - border.top - border.bottom)
        let aspect = contentW > 0 && contentH > 0 ? max(contentW, contentH) / min(contentW, contentH) : 1

        return ImageStatistics(
            meanR: mR, meanG: mG, meanB: mB, meanChroma: meanChroma, chroma95: chroma95,
            colorfulness: colorfulness, luminanceStdDev: lumStd, warmHueFraction: warmFraction,
            isMonochrome: isMono, isSepia: isSepia,
            magentaCast: (mR + mB) / 2 - mG, yellowCast: (mR + mG) / 2 - mB,
            border: border, contentAspect: aspect)
    }

    static func hue(_ r: Double, _ g: Double, _ b: Double, _ mx: Double, _ chroma: Double) -> Double {
        var h: Double
        if mx == r { h = ((g - b) / chroma).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / chroma + 2 }
        else { h = (r - g) / chroma + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    /// Walks inward from each edge while rows/columns stay uniform and close to the edge color.
    static func detectBorder(rgba: [UInt8], width: Int, height: Int) -> BorderInfo {
        guard width >= 16, height >= 16 else { return BorderInfo() }

        func lineStats(_ count: Int, _ pixel: (Int) -> Int) -> (mean: Double, std: Double, chroma: Double) {
            var s = 0.0, s2 = 0.0, c = 0.0
            for k in 0..<count {
                let i = pixel(k) * 4
                let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                s += l; s2 += l * l; c += max(r, g, b) - min(r, g, b)
            }
            let m = s / Double(count)
            return (m, max(0, s2 / Double(count) - m * m).squareRoot(), c / Double(count))
        }
        func row(_ y: Int) -> (Double, Double, Double) { lineStats(width) { y * width + $0 } }
        func col(_ x: Int) -> (Double, Double, Double) { lineStats(height) { $0 * width + x } }

        func thickness(_ limit: Int, _ line: (Int) -> (Double, Double, Double)) -> (Double, BorderInfo.Tone) {
            let edge = line(0)
            let tone: BorderInfo.Tone
            if edge.0 > 0.78 && edge.1 < 0.07 && edge.2 < 0.08 { tone = .light }
            else if edge.0 < 0.14 && edge.1 < 0.06 { tone = .dark }
            else { return (0, .none) }
            var k = 1
            while k < limit {
                let s = line(k)
                if s.1 > 0.08 || abs(s.0 - edge.0) > 0.09 { break }
                k += 1
            }
            return (Double(k), tone)
        }

        let maxY = height / 4, maxX = width / 4
        let t = thickness(maxY) { row($0) }
        let b = thickness(maxY) { row(height - 1 - $0) }
        let l = thickness(maxX) { col($0) }
        let r = thickness(maxX) { col(width - 1 - $0) }
        let tones = [t.1, b.1, l.1, r.1].filter { $0 != .none }
        let light = tones.filter { $0 == .light }.count, dark = tones.filter { $0 == .dark }.count
        let tone: BorderInfo.Tone = tones.isEmpty ? .none : (light >= dark ? .light : .dark)
        func frac(_ v: (Double, BorderInfo.Tone), _ dim: Int) -> Double {
            v.1 == tone && v.0 >= 2 ? v.0 / Double(dim) : 0
        }
        return BorderInfo(top: frac(t, height), bottom: frac(b, height), left: frac(l, width), right: frac(r, width), tone: tone)
    }
}

/// Turns image statistics into era clues.
public enum VisualClues {
    public static func evidence(from s: ImageStatistics) -> [DateEvidence] {
        var out: [DateEvidence] = []
        if s.isSepia {
            out.append(DateEvidence(source: .colorTone, summary: "Sepia-toned print, common before the mid-1930s",
                                    yearLow: 1860, yearHigh: 1935, peakYear: 1905, weight: 0.5))
        } else if s.isMonochrome {
            out.append(DateEvidence(source: .colorTone, summary: "Black & white — most family snapshots were B&W until the mid-1960s",
                                    yearLow: 1890, yearHigh: 1968, peakYear: 1948, weight: 0.4))
        } else {
            if s.magentaCast > 0.035 && s.meanR - s.meanB > 0.05 {
                out.append(DateEvidence(source: .colorTone, summary: "Magenta/red color shift typical of faded 1960s–80s color prints",
                                        yearLow: 1958, yearHigh: 1985, peakYear: 1972, weight: 0.3))
            } else if s.yellowCast > 0.12 && s.luminanceStdDev < 0.17 {
                out.append(DateEvidence(source: .colorTone, summary: "Yellowed, low-contrast color typical of aging prints",
                                        yearLow: 1955, yearHigh: 1995, peakYear: 1978, weight: 0.15))
            }
        }

        let border = s.border
        if border.isBottomHeavy {
            out.append(DateEvidence(source: .borderPaper, summary: "Instant-film frame (thicker bottom margin), e.g. Polaroid",
                                    yearLow: 1963, yearHigh: 2010, peakYear: 1980, weight: 0.3))
        } else if border.tone == .light && border.sidesWithBorder >= 3 {
            out.append(DateEvidence(source: .borderPaper, summary: "White print border, popular from the 1940s to the late 1980s",
                                    yearLow: 1940, yearHigh: 1992, peakYear: 1965, weight: 0.2))
        }

        if abs(s.contentAspect - 1) < 0.04 {
            if s.isMonochrome || s.isSepia {
                out.append(DateEvidence(source: .printFormat, summary: "Square black & white image (medium-format box/TLR cameras)",
                                        yearLow: 1930, yearHigh: 1975, peakYear: 1955, weight: 0.15))
            } else {
                out.append(DateEvidence(source: .printFormat, summary: "Square color image (Instamatic 126 / instant film era)",
                                        yearLow: 1963, yearHigh: 1988, peakYear: 1972, weight: 0.2))
            }
        }
        return out
    }

    /// Plain-language observations passed to the AI as extra context.
    public static func observations(from s: ImageStatistics) -> [String] {
        var notes: [String] = []
        if s.isSepia { notes.append("sepia toned") }
        else if s.isMonochrome { notes.append("black & white") }
        if s.magentaCast > 0.035 && !s.isMonochrome { notes.append("magenta color cast") }
        if s.border.isBottomHeavy { notes.append("instant-film style border") }
        else if s.border.sidesWithBorder >= 3 { notes.append("\(s.border.tone.rawValue) border around the image") }
        notes.append(String(format: "picture aspect %.2f:1", s.contentAspect))
        return notes
    }
}

/// Season clues from on-device scene classification labels (e.g. Vision's "snow", "beach").
public enum SceneClues {
    static let keywords: [(Season, [String], String)] = [
        (.winter, ["snow", "ski", "sled", "snowman", "icicle", "christmas", "winter", "frost"], "wintry scene"),
        (.summer, ["beach", "swimming", "pool", "surf", "sunbathing", "watermelon", "sandcastle", "water_park"], "summery scene"),
        (.fall, ["pumpkin", "jack_o_lantern", "halloween", "autumn", "fall_foliage", "foliage", "corn_maze"], "autumn scene"),
        (.spring, ["blossom", "cherry_blossom", "tulip", "daffodil", "easter", "egg_hunt"], "spring scene"),
    ]

    public static func evidence(fromLabels labels: [(identifier: String, confidence: Double)]) -> [DateEvidence] {
        var best: [Season: (Double, String)] = [:]
        for (identifier, confidence) in labels where confidence >= 0.3 {
            let id = identifier.lowercased()
            for (season, words, _) in keywords where words.contains(where: { id.contains($0) }) {
                if (best[season]?.0 ?? 0) < confidence { best[season] = (confidence, identifier) }
            }
        }
        return best.map { season, value in
            let label = value.1.replacingOccurrences(of: "_", with: " ")
            let month: Int? = value.1.lowercased().contains("christmas") ? 12 :
                (value.1.lowercased().contains("halloween") || value.1.lowercased().contains("jack_o_lantern")) ? 10 : nil
            return DateEvidence(source: .scene, summary: "Scene looks like \(label) (\(season.displayName.lowercased()))",
                                season: season, seasonWeight: min(0.7, value.0 * 0.8), exactMonth: month)
        }
    }
}
