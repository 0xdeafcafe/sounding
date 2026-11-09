import Foundation
import os

struct TrackArrangement: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable, CaseIterable {
        case introDrums, introQuiet, groove, breakdown, build, dropOpening, dropGroove, vocalHook, outroUsable, outroDead

        var isPeak: Bool { self == .dropOpening || self == .vocalHook }
        var isIntro: Bool { self == .introDrums || self == .introQuiet }
        var isOutro: Bool { self == .outroUsable || self == .outroDead }
        var isBeatLed: Bool { self == .introDrums || self == .groove || self == .dropGroove || self == .outroUsable }

        var sectionKind: SectionKind {
            switch self {
            case .introDrums: return .intro
            case .introQuiet: return .ambientIntro
            case .groove: return .bridge
            case .breakdown: return .breakdown
            case .build: return .buildup
            case .dropOpening, .dropGroove, .vocalHook: return .drop
            case .outroUsable: return .outro
            case .outroDead: return .ambientOutro
            }
        }
    }

    struct Interval: Codable, Sendable, Equatable {
        let role: Role
        let bars: Range<Int>
        let confidence: Float
    }

    struct Boundary: Codable, Sendable, Equatable {
        let bar: Int
        let confidence: Float
        let isSection: Bool
    }

    enum Source: String, Codable, Sendable {
        case beatTracker, soundAnalysis, beatThis, openUnmix
    }

    struct Coverage: Codable, Sendable, Equatable {
        let bars: Range<Int>
        let grid: Source
        let gridConfidence: Float
        let vocals: Source?
        let vocalBars: Range<Int>
        let drums: Source?
    }

    static let version = 1

    let version: Int
    let barStarts: [Double]
    let intervals: [Interval]
    let boundaries: [Boundary]
    let vocal: [Float?]
    let density: [Float]
    let coverage: Coverage

    var barCount: Int { barStarts.count }

    func bar(at seconds: TimeInterval) -> Int? {
        guard let first = barStarts.first, seconds >= first - 0.05 else { return nil }
        var lo = 0, hi = barStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if barStarts[mid] <= seconds + 0.05 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func interval(atBar bar: Int) -> Interval? {
        intervals.first { $0.bars.contains(bar) }
    }

    func role(atBar bar: Int) -> Role? {
        interval(atBar: bar)?.role
    }

    func role(at seconds: TimeInterval) -> Role? {
        bar(at: seconds).flatMap(role(atBar:))
    }

    func vocal(atBar bar: Int) -> Float? {
        guard vocal.indices.contains(bar) else { return nil }
        return vocal[bar]
    }

    func isPeak(bars range: Range<Int>) -> Bool? {
        let clamped = range.clamped(to: coverage.bars)
        guard !clamped.isEmpty else { return nil }
        if clamped.contains(where: { role(atBar: $0)?.isPeak == true }) { return true }
        if coverage.vocals == nil || !clamped.allSatisfy({ coverage.vocalBars.contains($0) }) { return nil }
        return false
    }

    func sections(duration: TimeInterval) -> [TrackSection] {
        intervals.compactMap { interval in
            guard interval.bars.lowerBound < barStarts.count else { return nil }
            let start = barStarts[interval.bars.lowerBound]
            let end = interval.bars.upperBound < barStarts.count ? barStarts[interval.bars.upperBound] : duration
            return end > start ? TrackSection(kind: interval.role.sectionKind, start: start, end: end) : nil
        }
    }

    // MARK: - Evidence

    struct Evidence: Sendable {
        var vocals: [ClosedRange<TimeInterval>]?
        var vocalSource: Source?
        var drumsOnly: [ClosedRange<TimeInterval>]?
        var bass: [ClosedRange<TimeInterval>]?
        var gridSource: Source = .beatTracker

        init(vocals: [ClosedRange<TimeInterval>]? = nil, vocalSource: Source? = nil, drumsOnly: [ClosedRange<TimeInterval>]? = nil, bass: [ClosedRange<TimeInterval>]? = nil, gridSource: Source = .beatTracker) {
            self.vocals = vocals
            self.vocalSource = vocalSource
            self.drumsOnly = drumsOnly
            self.bass = bass
            self.gridSource = gridSource
        }
    }

    static func build(_ tracked: BeatTrackerResult, ai: AIAudioAnalysisResult?) -> TrackArrangement? {
        let grid = ai?.isGridTrusted == true ? ai?.grid ?? tracked : tracked
        var evidence = Evidence(gridSource: grid == tracked ? .beatTracker : .beatThis)
        if let stems = ai?.stems {
            evidence.vocals = stems.vocals.compactMap(\.seconds)
            evidence.vocalSource = .openUnmix
            evidence.drumsOnly = stems.drumsOnly.compactMap(\.seconds)
            evidence.bass = stems.bass.compactMap(\.seconds)
        }
        return build(grid, evidence: evidence)
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let trackId: String
        let fingerprint: [Double]
    }

    private static let cache = OSAllocatedUnfairLock<[CacheKey: TrackArrangement]>(initialState: [:])
    static let cacheLimit = 64

    static func cached(trackId: String, tracked: BeatTrackerResult, ai: AIAudioAnalysisResult?) -> TrackArrangement? {
        let source = ai?.isGridTrusted == true ? ai?.grid ?? tracked : tracked
        let fingerprint: [Double] = [
            Double(version), Double(source.version), Double(source.downbeats.count),
            source.downbeats.first ?? 0, source.downbeats.last ?? 0, source.analysedSeconds,
            Double(source.vocalCurve?.count ?? -1), ai == nil ? 0 : 1, Double(ai?.stems?.vocals.count ?? -1)
        ]
        let key = CacheKey(trackId: trackId, fingerprint: fingerprint)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let built = build(tracked, ai: ai) else { return nil }
        cache.withLock { store in
            if store.count >= cacheLimit { store.removeAll() }
            store[key] = built
        }
        return built
    }

    // MARK: - Thresholds

    static let bodyPercentile = 0.75
    static let bodyWithinDecibels: Float = 3
    static let dipDecibels: Float = 6
    static let deadDecibels: Float = 24
    static let bandDecibelsPerUnit: Float = 4.343
    static let beatDensity: Float = 0.15
    static let beatFloorDecibels: Float = 15
    static let beatLowDecibels: Float = 9
    static let breakdownBarsForDrop = 4
    static let introDropBars = 8
    static let dropOpeningBars = 16
    static let hookVocal: Float = 0.5
    static let hookBars = 4
    static let hookCurveMean: Float = 0.5
    static let hookWithinDecibels: Float = 4
    static let buildRiseDecibels: Float = 3
    static let minimumSegmentBars = 3
    static let fillBars = 4
    static let hookGapBars = 2
    static let sparseDensity: Float = 0.25
    static let sparseDipDecibels: Float = 3
    static let noveltyRadius = 4
    static let noveltyPeakZ = 1.5

    // MARK: - Build

    enum Level: Int, Comparable {
        case dead, dip, mid, body
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    static func build(_ tracked: BeatTrackerResult, evidence: Evidence) -> TrackArrangement? {
        guard let profile = tracked.bars, tracked.downbeats.count == profile.level.count, profile.level.count >= 16 else { return nil }
        let count = profile.level.count
        let starts = tracked.downbeats
        let barSeconds = (starts[count - 1] - starts[0]) / Double(count - 1)
        guard barSeconds > 0 else { return nil }
        let measured = profile.level.filter { $0 > -89 }
        guard measured.count >= 8 else { return nil }
        let body = percentile(measured, bodyPercentile)
        let rel = profile.level.map { $0 > -89 ? $0 - body : -90 }

        func band(_ k: Int) -> [Float]? {
            guard let bands = profile.bands, bands.count == count * 4 else { return nil }
            return (0..<count).map { bands[$0 * 4 + k] * bandDecibelsPerUnit }
        }
        let loudBars = (0..<count).filter { rel[$0] >= -bodyWithinDecibels }
        func relative(_ values: [Float]?) -> [Float] {
            guard let values else { return [Float](repeating: 0, count: count) }
            let typical = percentile(loudBars.isEmpty ? values : loudBars.map { values[$0] }, 0.5)
            return values.map { $0 - typical }
        }
        let low = relative(band(0))
        let high = relative(band(3))
        let density = profile.density

        let drumsOnly = evidence.drumsOnly.map { spans in (0..<count).map { fraction(spans, bar: $0, starts: starts, barSeconds: barSeconds) } }
        let bassOn = evidence.bass.map { spans in (0..<count).map { fraction(spans, bar: $0, starts: starts, barSeconds: barSeconds) } }

        var vocal = [Float?](repeating: nil, count: count)
        var vocalSource: Source?
        var vocalBars = 0..<0
        if let spans = evidence.vocals, let source = evidence.vocalSource {
            vocalSource = source
            vocalBars = 0..<count
            for b in 0..<count { vocal[b] = fraction(spans, bar: b, starts: starts, barSeconds: barSeconds) }
        } else if let curve = tracked.vocalCurve, !curve.isEmpty, let spans = tracked.vocalSeconds {
            vocalSource = .soundAnalysis
            let covered = Double(curve.count) * VocalClassifier.hopSeconds
            let last = (0..<count).last { starts[$0] + barSeconds <= covered + VocalClassifier.hopSeconds } ?? -1
            vocalBars = 0..<(last + 1)
            for b in vocalBars { vocal[b] = fraction(spans, bar: b, starts: starts, barSeconds: barSeconds) }
        }
        var hookStrength = vocal.map { $0 ?? 0 }
        if vocalSource == .soundAnalysis, let curve = tracked.vocalCurve {
            for b in vocalBars {
                let lo = Int(starts[b] / VocalClassifier.hopSeconds)
                let hi = min(curve.count, max(lo + 1, Int((starts[b] + barSeconds) / VocalClassifier.hopSeconds)))
                guard lo < hi else { continue }
                let mean = curve[lo..<hi].reduce(Float(0), +) / Float(hi - lo)
                hookStrength[b] = min(hookStrength[b], mean / hookCurveMean)
            }
        }

        let relS = smoothed(rel.map { max(-40, $0) })
        let lowS = smoothed(low.map { max(-40, $0) })
        let densityS = smoothed(density)
        let levels = (0..<count).map { b -> Level in
            if relS[b] <= -deadDecibels { return .dead }
            let bassMissing = lowS[b] <= -dipDecibels || (bassOn.map { $0[b] < 0.25 } ?? false) && lowS[b] <= -bodyWithinDecibels
            let thin = densityS[b] <= sparseDensity && relS[b] <= -sparseDipDecibels
            if relS[b] <= -dipDecibels || bassMissing || thin { return .dip }
            if relS[b] >= -bodyWithinDecibels && lowS[b] >= -bodyWithinDecibels { return .body }
            return .mid
        }

        let phraseOffset = tracked.phraseOffsetBars
        let gridConfidence = Float(min(1, max(0, tracked.isPhaseReliable ? tracked.confidence : 0.6 * tracked.beatConfidence)))
        func snapped(_ bar: Int) -> Int {
            guard gridConfidence >= 0.3 else { return bar }
            let r = ((bar - phraseOffset) % 4 + 4) % 4
            if r == 1 { return bar - 1 }
            if r == 3 { return bar + 1 }
            return bar
        }

        let novelty = noveltyCurve(rel: rel, low: low, high: high, density: density, count: count)
        let z = zScores(novelty)
        let sectionBars = Set(tracked.sectionStarts.compactMap { s in starts.firstIndex { abs($0 - s) < barSeconds * 0.25 } })

        var cuts: [Int: Float] = [:]
        func addCut(_ bar: Int, _ confidence: Float) {
            let b = snapped(bar)
            guard b > 0, b < count else { return }
            cuts[b] = max(cuts[b] ?? 0, min(1, confidence))
        }
        var b = 1
        while b < count {
            if levels[b] != levels[b - 1], b + 1 >= count || levels[b + 1] == levels[b] {
                let step = abs(Float(levels[b].rawValue - levels[b - 1].rawValue))
                addCut(b, 0.35 + 0.2 * step + 0.1 * Float(max(0, z[b])))
            }
            b += 1
        }
        for k in sectionBars { addCut(k, 0.45 + 0.1 * Float(max(0, z[k]))) }
        for k in 1..<count where z[k] >= noveltyPeakZ {
            let lo = max(0, k - 2), hi = min(count - 1, k + 2)
            if (lo...hi).allSatisfy({ z[$0] <= z[k] }) { addCut(k, 0.3 + 0.1 * Float(z[k])) }
        }

        var edges = [0] + cuts.keys.sorted() + [count]
        edges = Array(Set(edges)).sorted()
        var segments: [(range: Range<Int>, level: Level)] = []
        for (lo, hi) in zip(edges, edges.dropFirst()) where hi > lo {
            segments.append((lo..<hi, majority(levels[lo..<hi])))
        }
        segments = merged(segments)
        segments = absorbingFills(segments)
        var lull = segments.map { $0.level <= .dip }
        for i in segments.indices where segments[i].level == .mid && segments[i].range.count <= 8 {
            if i > 0, lull[i - 1], i + 1 < segments.count, segments[i + 1].level == .body { lull[i] = true }
        }

        let mainIndices = segments.indices.filter { segments[$0].level == .body && segments[$0].range.count >= 4 }
        let firstMain = mainIndices.first ?? segments.indices.first { segments[$0].level >= .mid }
        let lastMain = mainIndices.last ?? segments.indices.last { segments[$0].level >= .mid }

        func mean(_ x: [Float], _ r: Range<Int>) -> Float {
            r.isEmpty ? 0 : r.reduce(Float(0)) { $0 + x[$1] } / Float(r.count)
        }
        func hasBeat(_ r: Range<Int>) -> Bool {
            if let drumsOnly, mean(drumsOnly, r) >= 0.5 { return true }
            return mean(density, r) >= beatDensity && mean(rel, r) >= -beatFloorDecibels && mean(low, r) >= -beatLowDecibels
        }
        func confidence(_ x: Float, _ a: Float, _ c: Float) -> Float {
            let t = max(0, min(1, (x - a) / (c - a)))
            return 0.4 + 0.6 * t * t * (3 - 2 * t)
        }

        var roles = [Role?](repeating: nil, count: count)
        var conf = [Float](repeating: 0, count: count)
        func assign(_ r: Range<Int>, _ role: Role, _ c: Float) {
            for k in r { roles[k] = role; conf[k] = c }
        }

        guard let firstMain, let lastMain else {
            for s in segments {
                let beat = hasBeat(s.range)
                assign(s.range, beat ? .groove : .breakdown, 0.3)
            }
            return finish()
        }

        for i in segments.indices {
            let s = segments[i]
            let r = s.range
            if i < firstMain {
                if hasBeat(r) {
                    assign(r, .introDrums, confidence(mean(density, r), beatDensity, 0.45))
                } else {
                    assign(r, .introQuiet, confidence(-mean(rel, r), 6, 15))
                }
            } else if i > lastMain {
                if hasBeat(r) && r.count >= 4 {
                    assign(r, .outroUsable, confidence(mean(density, r), beatDensity, 0.45))
                } else {
                    assign(r, .outroDead, confidence(-mean(rel, r), 6, 15))
                }
            } else if lull[i], s.level == .mid {
                assign(r, .build, 0.5)
            } else if lull[i] {
                let rising = mean(rel, r.suffix(2).startIndex..<r.upperBound) - mean(rel, r.lowerBound..<(r.lowerBound + min(2, r.count)))
                let highRise = mean(high, r.suffix(2).startIndex..<r.upperBound) - mean(high, r.lowerBound..<(r.lowerBound + min(2, r.count)))
                let leadsIntoBody = i + 1 < segments.count && (segments[i + 1].level == .body || lull[i + 1])
                let depth = max(-mean(rel, r), -mean(low, r))
                if leadsIntoBody, r.count >= 8, let split = buildSplit(r, rel: rel, high: high) {
                    assign(r.lowerBound..<split, .breakdown, confidence(depth, 3, 9))
                    assign(split..<r.upperBound, .build, 0.5)
                } else if leadsIntoBody, r.count <= 8, max(rising, highRise) >= buildRiseDecibels {
                    assign(r, .build, confidence(max(rising, highRise), buildRiseDecibels, 9))
                } else {
                    assign(r, .breakdown, confidence(depth, 3, 9))
                }
            } else {
                let previous = i > 0 ? segments[i - 1] : nil
                var dipBefore = 0
                var j = i - 1
                while j >= 0, lull[j] {
                    dipBefore += segments[j].range.count
                    j -= 1
                }
                let previousQuiet = previous.map { !hasBeat($0.range) && (mean(rel, $0.range) <= -dipDecibels || mean(low, $0.range) <= -dipDecibels) } ?? false
                let isDrop = s.level == .body && dipBefore >= breakdownBarsForDrop && (i > firstMain || (previousQuiet && r.lowerBound >= introDropBars))
                if isDrop {
                    let contrast = mean(rel, r) - (previous.map { mean(rel, $0.range) } ?? mean(rel, r))
                    let lowContrast = mean(low, r) - (previous.map { mean(low, $0.range) } ?? mean(low, r))
                    let c = confidence(max(contrast, lowContrast), 3, 12)
                    var end = min(r.upperBound, r.lowerBound + dropOpeningBars)
                    if let near = cuts.keys.filter({ abs($0 - end) <= 4 && $0 > r.lowerBound + 8 && $0 <= r.upperBound }).min(by: { abs($0 - end) < abs($1 - end) }) { end = near }
                    assign(r.lowerBound..<end, .dropOpening, c)
                    assign(end..<r.upperBound, .dropGroove, c)
                } else {
                    let loop = r.reduce(Float(0)) { $0 + profile.loop8[$1] } / Float(max(1, r.count))
                    assign(r, .groove, confidence(loop, 0.5, 0.85))
                }
            }
        }

        var d = 0
        while d < count {
            guard roles[d] == .dropOpening, d == 0 || roles[d - 1] != .dropOpening else { d += 1; continue }
            var e = d
            while e < count, let role = roles[e], role == .dropOpening || role == .dropGroove || role == .groove {
                if e - d >= dropOpeningBars, role == .dropOpening { roles[e] = .dropGroove }
                if role == .groove { roles[e] = e - d < dropOpeningBars ? .dropOpening : .dropGroove; conf[e] = conf[d] }
                e += 1
            }
            d = max(e, d + 1)
        }

        let hookS = smoothed(hookStrength, before: 1, after: 2)
        func hookOn(_ b: Int) -> Bool { hookS[b] >= hookVocal && relS[b] >= -hookWithinDecibels }
        var k = 0
        while k < count {
            guard hookOn(k), roles[k] == .groove || roles[k] == .dropGroove else { k += 1; continue }
            var end = k + 1
            while end < count, roles[end] == .groove || roles[end] == .dropGroove {
                let bridged = (1...hookGapBars).contains { end + $0 < count && hookOn(end + $0) }
                if hookOn(end) || bridged { end += 1 } else { break }
            }
            if end - k >= hookBars {
                let strength = (k..<end).reduce(Float(0)) { $0 + hookStrength[$1] } / Float(end - k)
                let weight: Float = vocalSource == .openUnmix ? 0.9 : 0.75
                assign(k..<end, .vocalHook, min(1, weight * strength + 0.1))
                for cut in [k, end] where cut > 0 && cut < count { cuts[cut] = max(cuts[cut] ?? 0, 0.4) }
            }
            k = end
        }

        return finish()

        func finish() -> TrackArrangement {
            var intervals: [Interval] = []
            var i = 0
            while i < count {
                guard let role = roles[i] else { i += 1; continue }
                var j = i + 1
                while j < count, roles[j] == role { j += 1 }
                let c = (i..<j).reduce(Float(0)) { $0 + conf[$1] } / Float(j - i)
                intervals.append(Interval(role: role, bars: i..<j, confidence: round3(c * (0.5 + 0.5 * gridConfidence))))
                i = j
            }
            let sectionSet = Set(intervals.map(\.bars.lowerBound))
            var boundaries: [Boundary] = []
            for bar in Swift.stride(from: ((phraseOffset % 8) + 8) % 8, to: count, by: 8) where cuts[bar] == nil && !sectionSet.contains(bar) {
                let support = Float(max(0, z[bar])) * 0.15
                boundaries.append(Boundary(bar: bar, confidence: round3(min(1, (0.35 + support) * gridConfidence)), isSection: false))
            }
            for (bar, c) in cuts {
                boundaries.append(Boundary(bar: bar, confidence: round3(min(1, c * (0.5 + 0.5 * gridConfidence))), isSection: sectionSet.contains(bar)))
            }
            for bar in sectionSet where bar > 0 && cuts[bar] == nil {
                boundaries.append(Boundary(bar: bar, confidence: round3(0.3 * gridConfidence), isSection: true))
            }
            boundaries.sort { $0.bar < $1.bar }
            return TrackArrangement(
                version: version,
                barStarts: starts,
                intervals: intervals,
                boundaries: boundaries,
                vocal: vocal.map { $0.map(round3) },
                density: density.map(round3),
                coverage: Coverage(
                    bars: 0..<count,
                    grid: evidence.gridSource,
                    gridConfidence: round3(gridConfidence),
                    vocals: vocalSource,
                    vocalBars: vocalBars,
                    drums: evidence.drumsOnly == nil ? nil : .openUnmix
                )
            )
        }
    }

    // MARK: - Helpers

    static func buildSplit(_ r: Range<Int>, rel: [Float], high: [Float]) -> Int? {
        let base = r.lowerBound..<(r.lowerBound + r.count / 2)
        let baseLevel = base.reduce(Float(0)) { $0 + rel[$1] } / Float(base.count)
        let baseHigh = base.reduce(Float(0)) { $0 + high[$1] } / Float(base.count)
        for length in [8, 4] where r.count >= length * 2 {
            let tail = (r.upperBound - length)..<r.upperBound
            let level = tail.reduce(Float(0)) { $0 + rel[$1] } / Float(length)
            let bright = tail.reduce(Float(0)) { $0 + high[$1] } / Float(length)
            if level - baseLevel >= buildRiseDecibels || bright - baseHigh >= buildRiseDecibels { return tail.lowerBound }
        }
        return nil
    }

    static func noveltyCurve(rel: [Float], low: [Float], high: [Float], density: [Float], count: Int) -> [Double] {
        let vectors = (0..<count).map { b -> [Double] in
            [Double(max(-30, rel[b])) / 6, Double(max(-30, low[b])) / 6, Double(max(-30, high[b])) / 6, Double(density[b]) * 2]
        }
        var out = [Double](repeating: 0, count: count)
        let w = noveltyRadius
        guard count > 2 * w else { return out }
        for b in w..<(count - w) {
            var s = 0.0
            for d in 0..<4 {
                var before = 0.0, after = 0.0
                for k in (b - w)..<b { before += vectors[k][d] }
                for k in b..<(b + w) { after += vectors[k][d] }
                s += pow((before - after) / Double(w), 2)
            }
            out[b] = s.squareRoot()
        }
        return out
    }

    static func zScores(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Double(x.count)
        let sd = (x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)).squareRoot()
        guard sd > 1e-9 else { return x.map { _ in 0 } }
        return x.map { ($0 - mean) / sd }
    }

    static func fraction(_ spans: [ClosedRange<TimeInterval>], bar: Int, starts: [Double], barSeconds: Double) -> Float {
        let lo = starts[bar]
        let hi = bar + 1 < starts.count ? starts[bar + 1] : lo + barSeconds
        guard hi > lo else { return 0 }
        let covered = spans.reduce(0.0) { $0 + max(0, min($1.upperBound, hi) - max($1.lowerBound, lo)) }
        return Float(min(1, covered / (hi - lo)))
    }

    static func smoothed(_ x: [Float], before: Int = 1, after: Int = 1) -> [Float] {
        x.indices.map { i in
            let lo = max(0, i - before), hi = min(x.count - 1, i + after)
            return x[lo...hi].reduce(Float(0), +) / Float(hi - lo + 1)
        }
    }

    static func absorbingFills(_ segments: [(range: Range<Int>, level: Level)]) -> [(range: Range<Int>, level: Level)] {
        var out: [(range: Range<Int>, level: Level)] = []
        var i = 0
        while i < segments.count {
            let s = segments[i]
            if s.level <= .dip, s.range.count < fillBars, let last = out.last, last.level >= .mid,
               i + 1 < segments.count, segments[i + 1].level >= .mid {
                let next = segments[i + 1]
                out[out.count - 1] = (last.range.lowerBound..<next.range.upperBound, max(last.level, next.level))
                i += 2
                continue
            }
            out.append(s)
            i += 1
        }
        return out
    }

    static func majority(_ slice: ArraySlice<Level>) -> Level {
        var counts = [Level: Int]()
        for l in slice { counts[l, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? .mid
    }

    static func merged(_ segments: [(range: Range<Int>, level: Level)]) -> [(range: Range<Int>, level: Level)] {
        var out: [(range: Range<Int>, level: Level)] = []
        for s in segments {
            if let last = out.last, last.level == s.level || s.range.count < minimumSegmentBars {
                out[out.count - 1] = (last.range.lowerBound..<s.range.upperBound, last.level)
            } else if let last = out.last, last.range.count < minimumSegmentBars {
                out[out.count - 1] = (last.range.lowerBound..<s.range.upperBound, s.level)
            } else {
                out.append(s)
            }
        }
        var again: [(range: Range<Int>, level: Level)] = []
        for s in out {
            if let last = again.last, last.level == s.level {
                again[again.count - 1] = (last.range.lowerBound..<s.range.upperBound, last.level)
            } else {
                again.append(s)
            }
        }
        return again
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))]
    }

    static func round3(_ x: Float) -> Float { (x * 1000).rounded() / 1000 }
}
