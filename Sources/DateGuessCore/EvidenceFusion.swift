import Foundation

/// Combines independent clues into a single best guess.
///
/// Each clue is turned into a likelihood over a grid of years. Likelihoods are multiplied
/// (added in log space), so clues that agree reinforce each other and a strong specific clue
/// (a printed date stamp) outweighs vague ones (black & white film). The season is chosen by a
/// weighted vote.
public enum EvidenceFusion {
    public struct Options: Sendable {
        public var minYear: Int
        public var maxYear: Int
        /// Use an exact month/day when a strong clue provides one (e.g. "1985-07-04" in a filename).
        public var allowExactMonth: Bool
        /// Adds a weak background prior centered on the era most undated prints come from.
        public var includeBackgroundPrior: Bool

        public init(minYear: Int = YearBounds.gridMinYear,
                    maxYear: Int = YearBounds.currentYear(),
                    allowExactMonth: Bool = true,
                    includeBackgroundPrior: Bool = true) {
            self.minYear = minYear
            self.maxYear = max(minYear, maxYear)
            self.allowExactMonth = allowExactMonth
            self.includeBackgroundPrior = includeBackgroundPrior
        }
    }

    static let hardOutsideLikelihood = 1e-6
    static let seasonDecisionThreshold = 0.3
    static let exactMonthWeightThreshold = 0.75

    public static let backgroundPrior = DateEvidence(
        source: .prior,
        summary: "Most undated photos in personal libraries are prints from 1945–2005",
        yearLow: 1945, yearHigh: 2005, peakYear: 1975, weight: 0.15)

    // MARK: Likelihoods

    /// Log-likelihood of each grid year for one clue, or nil if the clue carries no year information.
    ///
    /// Soft clues are a mixture: with probability `weight` the clue is right (density follows its
    /// shape), otherwise it is noise (uniform over all years). Normalizing the shape means a narrow
    /// clue (a printed date) is far more decisive than a broad one (black & white film).
    public static func logLikelihood(_ e: DateEvidence, options: Options) -> [Double]? {
        guard e.hasYearInfo else { return nil }
        let lo = max(options.minYear, e.yearLow ?? options.minYear)
        let hi = min(options.maxYear, e.yearHigh ?? options.maxYear)
        let count = options.maxYear - options.minYear + 1
        // A clue entirely outside the grid can't say anything useful.
        guard lo <= hi else { return nil }

        let width = Double(hi - lo)
        let sigma = max(1.5, width * 0.15 + 1.0)
        let peakSigma = max(1.0, width / 3.0)

        var shape = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let year = options.minYear + i
            if year < lo {
                shape[i] = e.isHardConstraint ? hardOutsideLikelihood : gaussian(Double(lo - year), sigma)
            } else if year > hi {
                shape[i] = e.isHardConstraint ? hardOutsideLikelihood : gaussian(Double(year - hi), sigma)
            } else {
                shape[i] = 1
                if let peak = e.peakYear, !e.isHardConstraint {
                    shape[i] *= 0.6 + 0.4 * gaussian(Double(year - peak), peakSigma)
                }
            }
        }
        if e.isHardConstraint {
            return shape.map { log(max($0, hardOutsideLikelihood)) }
        }
        let area = max(shape.reduce(0, +), 1e-9)
        let w = min(e.weight, 0.99)
        let noise = (1 - w) / Double(count)
        return shape.map { log(noise + w * $0 / area) }
    }

    /// Sum of log-likelihoods for a set of clues, optionally scaled (used to temper group evidence).
    public static func combinedLogLikelihood(_ evidence: [DateEvidence], options: Options, scale: Double = 1) -> [Double] {
        let count = options.maxYear - options.minYear + 1
        var total = [Double](repeating: 0, count: count)
        for e in evidence {
            guard let ll = logLikelihood(e, options: options) else { continue }
            // Hard constraints are never tempered: they are facts, not opinions.
            let s = e.isHardConstraint ? 1 : scale
            for i in 0..<count { total[i] += ll[i] * s }
        }
        return total
    }

    // MARK: Estimate

    /// Best guess from clues, plus optional extra log-likelihood (e.g. from a group).
    public static func estimate(from evidence: [DateEvidence],
                                extraLogLikelihood: [Double]? = nil,
                                extraSeasonVotes: [Season: Double] = [:],
                                extraExactDateCandidates: [DateEvidence] = [],
                                options: Options = Options()) -> DateEstimate {
        var all = evidence
        if options.includeBackgroundPrior { all.append(backgroundPrior) }
        var logp = combinedLogLikelihood(all, options: options)
        if let extra = extraLogLikelihood, extra.count == logp.count {
            for i in 0..<logp.count { logp[i] += extra[i] }
        }
        let probs = normalize(logp)
        let best = bestIndex(probs)
        let year = options.minYear + best

        let (qLo, qHi) = interval(probs, lower: 0.1, upper: 0.9)
        var mass = 0.0
        for i in max(0, best - 2)...min(probs.count - 1, best + 2) { mass += probs[i] }

        let hasEvidence = evidence.contains { $0.hasYearInfo }
            || (extraLogLikelihood.map { ll in ll.contains { $0 != 0 } } ?? false)

        // Season vote
        var votes = extraSeasonVotes
        for e in evidence where e.seasonWeight > 0 {
            if let s = e.season { votes[s, default: 0] += e.seasonWeight }
        }
        let topSeason = votes.max { a, b in a.value < b.value }
        let seasonIsDefault: Bool
        let season: Season
        if let top = topSeason, top.value >= seasonDecisionThreshold {
            season = top.key
            seasonIsDefault = false
        } else {
            // Summer is the most photographed season and sits mid-year, minimizing the worst-case error.
            season = .summer
            seasonIsDefault = true
        }

        var result = DateEstimate(
            year: year, season: season, month: season.representativeMonth, day: 1,
            yearLow: options.minYear + qLo, yearHigh: options.minYear + qHi,
            confidence: hasEvidence ? mass : min(mass, 0.1),
            seasonIsDefault: seasonIsDefault, hasAnyEvidence: hasEvidence)

        if options.allowExactMonth, let exact = strongestExactDate(in: evidence + extraExactDateCandidates, year: year) {
            result.month = exact.month
            result.season = Season.from(month: exact.month)
            result.seasonIsDefault = false
            result.usedExactMonth = true
            if let day = exact.day {
                result.day = day
                result.usedExactDay = true
            }
        }
        return result
    }

    /// A strong clue that gives an exact month and agrees with the chosen year. Dated clues
    /// (a full date in a filename) beat holiday words ("Christmas" → December).
    static func strongestExactDate(in evidence: [DateEvidence], year: Int) -> (month: Int, day: Int?)? {
        var best: (score: Double, evidence: DateEvidence)?
        for e in evidence {
            guard let m = e.exactMonth, (1...12).contains(m) else { continue }
            let score: Double
            if e.hasYearInfo {
                let lo = e.yearLow ?? Int.min, hi = e.yearHigh ?? Int.max
                guard e.weight >= exactMonthWeightThreshold, year >= lo, year <= hi else { continue }
                score = 1 + e.weight
            } else {
                guard e.seasonWeight >= 0.5 else { continue }
                score = e.seasonWeight
            }
            if best == nil || score > best!.score { best = (score, e) }
        }
        guard let chosen = best?.evidence, let month = chosen.exactMonth else { return nil }
        var day: Int? = nil
        if let d = chosen.exactDay, (1...31).contains(d), chosen.yearLow != nil, chosen.yearLow == chosen.yearHigh {
            day = d
        }
        return (month, day)
    }

    // MARK: Math helpers

    static func gaussian(_ d: Double, _ sigma: Double) -> Double {
        exp(-0.5 * (d / sigma) * (d / sigma))
    }

    public static func normalize(_ logp: [Double]) -> [Double] {
        guard let m = logp.max(), m.isFinite else {
            return [Double](repeating: 1 / Double(max(1, logp.count)), count: logp.count)
        }
        let exps = logp.map { exp($0 - m) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    /// Index of the most likely year. When the top is a flat plateau, picks its middle.
    static func bestIndex(_ probs: [Double]) -> Int {
        guard let maxP = probs.max(), maxP > 0 else { return probs.count / 2 }
        // Only consider the contiguous run containing the first maximum.
        let firstMax = probs.firstIndex(of: maxP) ?? probs.count / 2
        var lo = firstMax, hi = firstMax
        while lo - 1 >= 0, probs[lo - 1] >= maxP * 0.98 { lo -= 1 }
        while hi + 1 < probs.count, probs[hi + 1] >= maxP * 0.98 { hi += 1 }
        return (lo + hi) / 2
    }

    static func interval(_ probs: [Double], lower: Double, upper: Double) -> (Int, Int) {
        var acc = 0.0
        var lo = 0, hi = probs.count - 1
        var foundLo = false
        for (i, p) in probs.enumerated() {
            acc += p
            if !foundLo && acc >= lower { lo = i; foundLo = true }
            if acc >= upper { hi = i; break }
        }
        return (lo, max(lo, hi))
    }
}

/// Combines estimates for photos the user grouped together.
public enum GroupFusion {
    public struct Member: Sendable {
        public var assetID: String
        public var evidence: [DateEvidence]
        public init(assetID: String, evidence: [DateEvidence]) {
            self.assetID = assetID
            self.evidence = evidence
        }
    }

    /// Returns one estimate per member, keyed by asset ID.
    ///
    /// - sameEvent: every member gets the group's date. Members' clues are tempered by 1/√n
    ///   because looking at many photos of the same event is not n independent observations.
    /// - sameEra: each member keeps its own clues and gets the group as a softer extra clue.
    public static func estimates(members: [Member],
                                 groupEvidence: [DateEvidence],
                                 kind: GroupKind,
                                 options: EvidenceFusion.Options = .init()) -> [String: DateEstimate] {
        guard !members.isEmpty else { return [:] }
        let n = Double(members.count)
        let temper = 1 / n.squareRoot()

        var groupLL = EvidenceFusion.combinedLogLikelihood(groupEvidence, options: options)
        var seasonVotes: [Season: Double] = [:]
        for e in groupEvidence where e.seasonWeight > 0 {
            if let s = e.season { seasonVotes[s, default: 0] += e.seasonWeight }
        }

        var memberLL: [[Double]] = []
        for m in members {
            // Hard constraints from one member (e.g. a HEIC file) apply to the event as a whole only
            // for sameEvent groups, so keep them per member for sameEra.
            let ll = EvidenceFusion.combinedLogLikelihood(m.evidence, options: options, scale: temper)
            memberLL.append(ll)
            for e in m.evidence where e.seasonWeight > 0 {
                if let s = e.season { seasonVotes[s, default: 0] += e.seasonWeight * temper }
            }
        }

        var result: [String: DateEstimate] = [:]
        switch kind {
        case .sameEvent:
            for ll in memberLL {
                for i in 0..<groupLL.count { groupLL[i] += ll[i] }
            }
            let memberExact = members.flatMap { $0.evidence }.filter { $0.exactMonth != nil }
            let shared = EvidenceFusion.estimate(from: [],
                                                 extraLogLikelihood: groupLL,
                                                 extraSeasonVotes: seasonVotes,
                                                 extraExactDateCandidates: groupEvidence + memberExact,
                                                 options: options)
            for m in members { result[m.assetID] = shared }
        case .sameEra:
            for (idx, m) in members.enumerated() {
                // Group signal = group hints + the other members' tempered clues, at half strength.
                var extra = groupLL
                for (j, ll) in memberLL.enumerated() where j != idx {
                    for i in 0..<extra.count { extra[i] += ll[i] * 0.5 }
                }
                var memberSeasonVotes: [Season: Double] = [:]
                for e in groupEvidence where e.seasonWeight > 0 {
                    if let s = e.season { memberSeasonVotes[s, default: 0] += e.seasonWeight }
                }
                result[m.assetID] = EvidenceFusion.estimate(from: m.evidence,
                                                            extraLogLikelihood: extra,
                                                            extraSeasonVotes: memberSeasonVotes,
                                                            options: options)
            }
        }
        return result
    }
}
