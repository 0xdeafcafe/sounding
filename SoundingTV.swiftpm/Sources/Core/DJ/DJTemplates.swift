import Foundation

enum DJTempo {

    static let relations: [(factor: Double, baseCost: Double, label: String)] = [
        (1.0,       0.00, "same tempo"),
        (2.0,       0.06, "double time"),
        (0.5,       0.06, "half time"),
        (1.5,       0.30, "3:2"),
        (2.0 / 3.0, 0.30, "2:3"),
        (4.0 / 3.0, 0.42, "4:3"),
        (0.75,      0.42, "3:4")
    ]

    struct Relation: Equatable, Sendable {
        let factor: Double
        let baseCost: Double
        let label: String
        let residual: Double
        let requiredRate: Double

        var selectionCost: Double { pow(residual / 0.10, 1.8) + baseCost }
    }

    static func best(outgoing: BeatGrid, incoming: BeatGrid) -> Relation? {
        guard outgoing.beatPeriod > 0, incoming.beatPeriod > 0 else { return nil }
        var best: Relation?
        for r in relations {
            let residual = abs(1 - r.factor * outgoing.beatPeriod / incoming.beatPeriod)
            let required = incoming.beatPeriod / (outgoing.beatPeriod * r.factor)
            let candidate = Relation(
                factor: r.factor, baseCost: r.baseCost, label: r.label,
                residual: residual, requiredRate: required
            )
            if best == nil || candidate.selectionCost < best?.selectionCost ?? .infinity {
                best = candidate
            }
        }
        return best
    }

    static func applicableRate(_ relation: Relation, profile: DJProfile) -> Double {
        let m = profile.maxAbsRatePercent / 100
        return min(1 + m, max(1 - m, relation.requiredRate))
    }

    static func leftover(_ relation: Relation, appliedRate: Double) -> Double {
        guard relation.requiredRate > 0 else { return 0 }
        return abs(1 - appliedRate / relation.requiredRate)
    }

    static func driftMs(leftover: Double, overlapSeconds: TimeInterval) -> Double {
        leftover * 1000 * overlapSeconds
    }

    static func curvatureDriftMs(_ grid: BeatGrid?, from start: TimeInterval, seconds: TimeInterval) -> Double {
        guard let beats = grid?.beats, seconds > 0 else { return 0 }
        let window = beats.filter { $0 >= start && $0 <= start + seconds }
        guard window.count >= 8 else { return 0 }
        let n = Double(window.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (i, t) in window.enumerated() {
            let x = Double(i)
            sx += x; sy += t; sxx += x * x; sxy += x * t
        }
        let slope = (n * sxy - sx * sy) / max(1e-12, n * sxx - sx * sx)
        let intercept = (sy - slope * sx) / n
        var worst = 0.0
        for (i, t) in window.enumerated() { worst = max(worst, abs(t - (intercept + slope * Double(i)))) }
        return worst * 1000
    }
}

enum DJGridTrust {
    static func phaseLocked(_ track: TrackFeatures, profile: DJProfile) -> Bool {
        guard let grid = track.beatGrid else { return false }
        let floor = track.isBeatOnly ? min(profile.minGridConfidence, DJBeatOnly.minimumGridConfidence) : profile.minGridConfidence
        return track.provenance.contains(.measuredBeatGrid) && grid.confidence >= floor
    }

    static func phaseLocked(_ outgoing: TrackFeatures, _ incoming: TrackFeatures, profile: DJProfile) -> Bool {
        phaseLocked(outgoing, profile: profile) && phaseLocked(incoming, profile: profile)
    }
}

enum DJPointFinder {

    static let maxExits = 8
    static let maxEntries = 6
    static let outroExitBars = [16, 24, 32, 40, 48, 64]

    static func exitCandidates(in track: TrackFeatures, profile: DJProfile) -> [ExitPoint] {
        guard track.duration.isFinite, track.duration >= DJEngineConstants.minimumPlannableDuration else {
            return []
        }

        let floor = max(track.duration * profile.exitRegionFloor, track.earliestExitSeconds)
        let ceiling = max(floor, track.duration - 2)
        guard floor < ceiling else { return [] }

        var out: [ExitPoint] = []

        if let preferred = track.preferredExitSeconds,
           preferred >= 1, preferred <= ceiling {
            out.append(ExitPoint(
                seconds: preferred,
                kind: track.section(at: preferred),
                barsRemaining: bars(from: preferred, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(preferred, track),
                confidence: 1
            ))
        }

        for hint in track.cueHints where hint.role == .exit && hint.seconds >= floor && hint.seconds <= ceiling {
            out.append(ExitPoint(
                seconds: hint.seconds,
                kind: track.section(at: hint.seconds),
                barsRemaining: bars(from: hint.seconds, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(hint.seconds, track),
                confidence: hint.confidence
            ))
        }

        if track.provenance.contains(.measuredStructure) {
            for section in track.sections where section.start >= floor && section.start <= ceiling {
                out.append(ExitPoint(
                    seconds: section.start,
                    kind: section.kind,
                    barsRemaining: bars(from: section.start, to: track.duration, grid: track.beatGrid),
                    onPhraseBoundary: isOnPhrase(section.start, track),
                    confidence: 0.85
                ))
            }
        }

        if let payoff = DJMoveRails.energyPayoffEnd(track), payoff >= floor, payoff <= ceiling {
            var after = [payoff]
            if let grid = track.beatGrid, grid.barDuration > 0 {
                after += grid.phraseStarts(from: payoff + 0.05, through: min(ceiling, payoff + grid.phraseDuration * 2))
            }
            for t in after {
                out.append(ExitPoint(
                    seconds: t,
                    kind: .outro,
                    barsRemaining: bars(from: t, to: track.duration, grid: track.beatGrid),
                    onPhraseBoundary: isOnPhrase(t, track),
                    confidence: 0.8
                ))
            }
        }

        for point in envelopeExits(in: track, floor: floor, ceiling: ceiling) {
            out.append(point)
        }

        if profile.allowMidTrackExit {
            for point in envelopeShapeExits(in: track, floor: floor, ceiling: ceiling) {
                out.append(point)
            }
        }

        if let grid = track.beatGrid, track.provenance.contains(.measuredBeatGrid),
           grid.phraseDuration > 1, grid.barDuration > 0 {
            for bars in outroExitBars {
                let target = track.duration - Double(bars) * grid.barDuration
                guard target >= floor, target <= ceiling else { continue }
                let t = grid.phraseStarts(from: target - grid.phraseDuration / 2, through: target + grid.phraseDuration / 2)
                    .min { abs($0 - target) < abs($1 - target) } ?? grid.nearestDownbeat(to: target)
                guard t >= floor, t <= ceiling else { continue }
                out.append(ExitPoint(
                    seconds: t,
                    kind: track.section(at: t) == .unknown ? .outro : track.section(at: t),
                    barsRemaining: Self.bars(from: t, to: track.duration, grid: grid),
                    onPhraseBoundary: true,
                    confidence: 0.8 * grid.confidence
                ))
            }
        }

        if profile.allowMidTrackExit, let grid = track.beatGrid,
           track.provenance.contains(.measuredBeatGrid), grid.phraseDuration > 1 {
            for t in grid.phraseStarts(from: floor, through: ceiling).prefix(maxExits * 3) {
                out.append(ExitPoint(
                    seconds: t,
                    kind: track.section(at: t),
                    barsRemaining: bars(from: t, to: track.duration, grid: grid),
                    onPhraseBoundary: true,
                    confidence: 0.55 * grid.confidence
                ))
            }
        }

        if out.isEmpty {
            var point = max(floor, track.duration - 4)
            var kind: SectionKind = .outro
            if profile.allowMidTrackExit {
                if let valley = bestValleyStart(envelope: track.envelope, duration: track.duration, after: floor),
                   valley <= ceiling {
                    point = valley
                    kind = .breakdown
                } else {
                    point = min(ceiling, max(floor, max(profile.minimumPlayFraction * track.duration, track.duration * 0.6)))
                }
            }
            out.append(ExitPoint(
                seconds: point,
                kind: kind,
                barsRemaining: bars(from: point, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(point, track),
                confidence: 0.25
            ))
        }

        let snapped = out.map { snap($0, track: track, profile: profile) }.filter { point in
            point.seconds >= track.earliestExitSeconds - 0.01
        }
        let ordered: [ExitPoint]
        if profile.allowMidTrackExit {
            ordered = snapped.sorted { $0.confidence > $1.confidence }
        } else {
            ordered = snapped.sorted { lhs, rhs in
                let lhsCue = lhs.confidence >= 1
                let rhsCue = rhs.confidence >= 1
                if lhsCue != rhsCue { return lhsCue }
                return outroFit(lhs, in: track) > outroFit(rhs, in: track)
            }
        }
        var seen = Set<Int>()
        var unique: [ExitPoint] = []
        for point in ordered {
            let bucket = Int((point.seconds / 0.5).rounded())
            if seen.insert(bucket).inserted { unique.append(point) }
        }
        return Array(unique.prefix(maxExits))
    }

    static func outroFit(_ point: ExitPoint, in track: TrackFeatures) -> Double {
        let remaining = track.duration - point.seconds
        let barSeconds = track.beatGrid?.barDuration ?? 2
        let bars = barSeconds > 0 ? remaining / barSeconds : 0
        let fit: Double
        switch bars {
        case 16...48: fit = 1
        case 8..<16, 48..<64: fit = 0.6
        default: fit = 0.2
        }
        return fit + 0.3 * point.confidence + (point.onPhraseBoundary ? 0.1 : 0)
    }

    static func entryCandidates(in track: TrackFeatures, profile: DJProfile) -> [EntryPoint] {
        guard track.duration.isFinite, track.duration > 10 else { return [] }
        let hasStructuralData = track.provenance.contains(.measuredStructure)
            || track.provenance.contains(.measuredBeatGrid)
        let ceiling = hasStructuralData
            ? max(4, track.duration * profile.entryRegionCeiling)
            : max(4, track.duration * 0.20)

        var out: [EntryPoint] = []
        let median = envelopeMedian(track.envelope)

        if let preferred = track.preferredEntrySeconds,
           preferred >= 0, preferred < track.duration {
            out.append(EntryPoint(
                seconds: preferred,
                kind: track.section(at: preferred),
                barsUntilNextSection: barsUntilNext(after: preferred, in: track),
                onPhraseBoundary: isOnPhrase(preferred, track),
                hasBassFromHere: hasBody(track, at: preferred, median: median),
                confidence: 1
            ))
        }

        for hint in track.cueHints where hint.role == .entry && hint.seconds >= 0 && hint.seconds < track.duration {
            out.append(EntryPoint(
                seconds: hint.seconds,
                kind: track.section(at: hint.seconds),
                barsUntilNextSection: barsUntilNext(after: hint.seconds, in: track),
                onPhraseBoundary: isOnPhrase(hint.seconds, track),
                hasBassFromHere: hasBody(track, at: hint.seconds, median: median),
                confidence: hint.confidence
            ))
        }

        if track.provenance.contains(.measuredStructure) {
            for section in track.sections where section.start <= ceiling {
                out.append(EntryPoint(
                    seconds: section.start,
                    kind: section.kind,
                    barsUntilNextSection: barsUntilNext(after: section.start, in: track),
                    onPhraseBoundary: isOnPhrase(section.start, track),
                    hasBassFromHere: hasBody(track, at: section.start, median: median),
                    confidence: 0.85
                ))
            }
        }

        let opening = track.contentStart
        out.append(EntryPoint(
            seconds: opening,
            kind: track.provenance.contains(.measuredStructure) ? track.section(at: opening) : .intro,
            barsUntilNextSection: barsUntilNext(after: opening, in: track),
            onPhraseBoundary: true,
            hasBassFromHere: hasBody(track, at: opening, median: median),
            confidence: 0.6
        ))

        for t in track.intro?.alternatives ?? [] where t > opening + 0.5 && t < track.duration {
            out.append(EntryPoint(
                seconds: t,
                kind: track.section(at: t),
                barsUntilNextSection: barsUntilNext(after: t, in: track),
                onPhraseBoundary: true,
                hasBassFromHere: hasBody(track, at: t, median: median),
                confidence: 0.62
            ))
        }

        if let grid = track.beatGrid, track.provenance.contains(.measuredBeatGrid),
           grid.phraseDuration > 1 {
            for t in grid.phraseStarts(from: max(0.5, opening), through: ceiling).prefix(maxEntries * 3) {
                out.append(EntryPoint(
                    seconds: t,
                    kind: track.section(at: t),
                    barsUntilNextSection: barsUntilNext(after: t, in: track),
                    onPhraseBoundary: true,
                    hasBassFromHere: hasBody(track, at: t, median: median),
                    confidence: 0.65 * grid.confidence
                ))
            }
        }

        if profile.allowMidTrackExit {
            for point in envelopeShapeEntries(in: track, ceiling: ceiling, median: median) {
                out.append(point)
            }
        }

        let snapped = out.map { snapEntry($0, track: track, median: median) }.filter { point in
            point.seconds >= track.contentStart - 0.5 || point.confidence >= 1
        }
        var seen = Set<Int>()
        var unique: [EntryPoint] = []
        for point in snapped.sorted(by: { $0.confidence > $1.confidence }) {
            let bucket = Int((point.seconds / 0.5).rounded())
            if seen.insert(bucket).inserted { unique.append(point) }
        }
        return Array(unique.prefix(maxEntries))
    }

    static func snapEntry(_ point: EntryPoint, track: TrackFeatures, median: Double) -> EntryPoint {
        guard let grid = track.beatGrid, track.provenance.contains(.measuredBeatGrid),
              grid.barDuration > 0 else { return point }
        var target = grid.nearestDownbeat(to: point.seconds)
        if target < 0 { target = grid.firstDownbeat }
        if point.seconds <= 0.001 { target = max(0, grid.firstDownbeat) }
        if target < track.contentStart - 0.01 {
            target = grid.nearestDownbeat(to: track.contentStart)
            if target < track.contentStart - 0.01 { target += grid.barDuration }
        }
        guard abs(target - point.seconds) > 0.0005 else { return point }
        return EntryPoint(
            seconds: target,
            kind: point.kind,
            barsUntilNextSection: barsUntilNext(after: target, in: track),
            onPhraseBoundary: isOnPhrase(target, track),
            hasBassFromHere: hasBody(track, at: target, median: median),
            confidence: point.confidence
        )
    }

    private static func envelopeExits(
        in track: TrackFeatures, floor: TimeInterval, ceiling: TimeInterval
    ) -> [ExitPoint] {
        let envelope = track.envelope
        guard envelope.count >= 8 else { return [] }
        let bucketSeconds = track.duration / Double(envelope.count)
        guard bucketSeconds > 0 else { return [] }

        let quietThreshold = max(0.05, envelopeMedian(envelope) * 0.55)

        let floorBucket = min(envelope.count - 1, max(0, Int(floor / bucketSeconds)))
        let ceilBucket = min(envelope.count - 1, max(floorBucket, Int(ceiling / bucketSeconds)))
        guard floorBucket < ceilBucket else { return [] }

        var out: [ExitPoint] = []
        var i = floorBucket
        while i <= ceilBucket {
            guard Double(envelope[i]) <= quietThreshold else { i += 1; continue }
            let start = i
            while i <= ceilBucket, Double(envelope[i]) <= quietThreshold { i += 1 }
            let length = i - start
            guard length >= 4 else { continue }
            let floorAmplitude = envelope[start..<i].map(Double.init).min() ?? quietThreshold
            let kind: SectionKind = floorAmplitude <= quietThreshold * 0.4 ? .ambientOutro : .breakdown
            let seconds = Double(start) * bucketSeconds
            out.append(ExitPoint(
                seconds: seconds,
                kind: kind,
                barsRemaining: bars(from: seconds, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(seconds, track),
                confidence: min(0.7, 0.35 + Double(length) * 0.02)
            ))
        }
        return out
    }

    static func envelopeMedian(_ envelope: [Float]) -> Double {
        guard !envelope.isEmpty else { return 0 }
        let sorted = envelope.sorted()
        return Double(sorted[sorted.count / 2])
    }

    // MARK: - Envelope shape (relative valleys, builds and outros)

    private static let valleyRatio = 0.8
    private static let valleyMinSeconds: TimeInterval = 8
    private static let riseLookaheadSeconds: TimeInterval = 12
    private static let smoothingRadiusSeconds: TimeInterval = 5
    private static let rollingMedianRadiusSeconds: TimeInterval = 45

    private static func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, values.count > 1 else { return values }
        var out = [Float](repeating: 0, count: values.count)
        for i in 0..<values.count {
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            var sum: Float = 0
            for j in lo...hi { sum += values[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }

    private static func rollingMedian(_ values: [Float], radius: Int) -> [Double] {
        guard radius > 0, !values.isEmpty else { return values.map(Double.init) }
        var out = [Double](repeating: 0, count: values.count)
        for i in 0..<values.count {
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            let window = values[lo...hi].map(Double.init).sorted()
            out[i] = window[window.count / 2]
        }
        return out
    }

    private static func shapeProfile(envelope: [Float], duration: TimeInterval) -> (
        smoothed: [Float], rolling: [Double], bucketSeconds: TimeInterval
    )? {
        guard envelope.count >= 8, duration > 0 else { return nil }
        let bucketSeconds = duration / Double(envelope.count)
        guard bucketSeconds > 0 else { return nil }
        let smoothed = movingAverage(
            envelope, radius: max(1, Int((smoothingRadiusSeconds / bucketSeconds).rounded()))
        )
        let rolling = rollingMedian(
            smoothed, radius: max(4, Int((rollingMedianRadiusSeconds / bucketSeconds).rounded()))
        )
        return (smoothed, rolling, bucketSeconds)
    }

    private static func riseStart(
        smoothed: [Float], rolling: [Double], from end: Int, ceilBucket: Int, bucketSeconds: TimeInterval
    ) -> Int? {
        guard end <= ceilBucket, end < smoothed.count else { return nil }
        let lookahead = max(1, Int((riseLookaheadSeconds / bucketSeconds).rounded()))
        let limit = min(ceilBucket, end + lookahead, smoothed.count - 1)
        guard limit > end else { return nil }
        let baseline = rolling[end]
        guard baseline > 0 else { return nil }
        let startLevel = Double(smoothed[end])
        let peak = smoothed[end...limit].map(Double.init).max() ?? startLevel
        guard peak - startLevel >= baseline * 0.25, peak >= baseline * 0.9 else { return nil }
        return end
    }

    private static func valleyRuns(
        smoothed: [Float], rolling: [Double], from floorBucket: Int, to ceilBucket: Int, minBuckets: Int
    ) -> [(start: Int, end: Int)] {
        var runs: [(start: Int, end: Int)] = []
        var i = floorBucket
        while i <= ceilBucket {
            let baseline = rolling[i]
            guard baseline > 0, Double(smoothed[i]) <= baseline * valleyRatio else { i += 1; continue }
            let start = i
            while i <= ceilBucket, rolling[i] > 0, Double(smoothed[i]) <= rolling[i] * valleyRatio { i += 1 }
            if i - start >= minBuckets { runs.append((start, i)) }
        }
        return runs
    }

    private static func finalHighRegionEnd(
        smoothed: [Float], rolling: [Double], floorBucket: Int, ceilBucket: Int, minBuckets: Int
    ) -> Int? {
        var runs: [(start: Int, end: Int)] = []
        var i = floorBucket
        while i <= ceilBucket {
            let baseline = rolling[i]
            guard baseline > 0, Double(smoothed[i]) >= baseline else { i += 1; continue }
            let start = i
            while i <= ceilBucket, rolling[i] > 0, Double(smoothed[i]) >= rolling[i] { i += 1 }
            if i - start >= minBuckets { runs.append((start, i)) }
        }
        guard let last = runs.last, last.end < ceilBucket else { return nil }
        return last.end
    }

    static func bestValleyStart(
        envelope: [Float], duration: TimeInterval, after floorSeconds: TimeInterval
    ) -> TimeInterval? {
        guard let profile = shapeProfile(envelope: envelope, duration: duration) else { return nil }
        let floorBucket = min(profile.smoothed.count - 1, max(0, Int(floorSeconds / profile.bucketSeconds)))
        let minBuckets = max(1, Int((valleyMinSeconds / profile.bucketSeconds).rounded()))
        let runs = valleyRuns(
            smoothed: profile.smoothed, rolling: profile.rolling,
            from: floorBucket, to: profile.smoothed.count - 1, minBuckets: minBuckets
        )
        guard !runs.isEmpty else { return nil }
        var best: (start: Int, depth: Double)?
        for run in runs {
            let baseline = profile.rolling[run.start]
            guard baseline > 0 else { continue }
            let depth = (run.start..<run.end).map { Double(profile.smoothed[$0]) / profile.rolling[$0] }.min() ?? 1
            if best == nil || depth < best!.depth { best = (run.start, depth) }
        }
        guard let winner = best else { return nil }
        return Double(winner.start) * profile.bucketSeconds
    }

    private static func envelopeShapeExits(
        in track: TrackFeatures, floor: TimeInterval, ceiling: TimeInterval
    ) -> [ExitPoint] {
        guard let profile = shapeProfile(envelope: track.envelope, duration: track.duration) else { return [] }
        let smoothed = profile.smoothed
        let rolling = profile.rolling
        let bucketSeconds = profile.bucketSeconds

        let floorBucket = min(smoothed.count - 1, max(0, Int(floor / bucketSeconds)))
        let ceilBucket = min(smoothed.count - 1, max(floorBucket, Int(ceiling / bucketSeconds)))
        guard floorBucket < ceilBucket else { return [] }
        let minBuckets = max(1, Int((valleyMinSeconds / bucketSeconds).rounded()))

        var out: [ExitPoint] = []
        let runs = valleyRuns(smoothed: smoothed, rolling: rolling, from: floorBucket, to: ceilBucket, minBuckets: minBuckets)
        for run in runs {
            let seconds = Double(run.start) * bucketSeconds
            out.append(ExitPoint(
                seconds: seconds,
                kind: .breakdown,
                barsRemaining: bars(from: seconds, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(seconds, track),
                confidence: 0.5
            ))
            if let rise = riseStart(smoothed: smoothed, rolling: rolling, from: run.end, ceilBucket: ceilBucket, bucketSeconds: bucketSeconds) {
                let riseSeconds = Double(rise) * bucketSeconds
                if riseSeconds >= floor, riseSeconds <= ceiling {
                    out.append(ExitPoint(
                        seconds: riseSeconds,
                        kind: .build,
                        barsRemaining: bars(from: riseSeconds, to: track.duration, grid: track.beatGrid),
                        onPhraseBoundary: isOnPhrase(riseSeconds, track),
                        confidence: 0.45
                    ))
                }
            }
        }

        if let outroBucket = finalHighRegionEnd(smoothed: smoothed, rolling: rolling, floorBucket: floorBucket, ceilBucket: ceilBucket, minBuckets: minBuckets) {
            let seconds = Double(outroBucket) * bucketSeconds
            out.append(ExitPoint(
                seconds: seconds,
                kind: .outro,
                barsRemaining: bars(from: seconds, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(seconds, track),
                confidence: 0.4
            ))
        }

        return out
    }

    private static func envelopeShapeEntries(
        in track: TrackFeatures, ceiling: TimeInterval, median: Double
    ) -> [EntryPoint] {
        guard let profile = shapeProfile(envelope: track.envelope, duration: track.duration) else { return [] }
        let smoothed = profile.smoothed
        let rolling = profile.rolling
        let bucketSeconds = profile.bucketSeconds

        let ceilBucket = min(smoothed.count - 1, max(0, Int(ceiling / bucketSeconds)))
        guard ceilBucket > 0 else { return [] }
        let minBuckets = max(1, Int((valleyMinSeconds / bucketSeconds).rounded()))

        let runs = valleyRuns(smoothed: smoothed, rolling: rolling, from: 0, to: ceilBucket, minBuckets: minBuckets)
        guard let firstValley = runs.first else { return [] }

        var out: [EntryPoint] = []
        let valleyEndSeconds = Double(firstValley.end) * bucketSeconds
        if valleyEndSeconds <= ceiling {
            out.append(EntryPoint(
                seconds: valleyEndSeconds,
                kind: .breakdown,
                barsUntilNextSection: barsUntilNext(after: valleyEndSeconds, in: track),
                onPhraseBoundary: isOnPhrase(valleyEndSeconds, track),
                hasBassFromHere: hasBody(track, at: valleyEndSeconds, median: median),
                confidence: 0.45
            ))
        }
        if let rise = riseStart(smoothed: smoothed, rolling: rolling, from: firstValley.end, ceilBucket: ceilBucket, bucketSeconds: bucketSeconds) {
            let riseSeconds = Double(rise) * bucketSeconds
            if riseSeconds <= ceiling {
                out.append(EntryPoint(
                    seconds: riseSeconds,
                    kind: .build,
                    barsUntilNextSection: barsUntilNext(after: riseSeconds, in: track),
                    onPhraseBoundary: isOnPhrase(riseSeconds, track),
                    hasBassFromHere: hasBody(track, at: riseSeconds, median: median),
                    confidence: 0.4
                ))
            }
        }
        return out
    }

    private static func hasBody(_ track: TrackFeatures, at seconds: TimeInterval, median: Double) -> Bool {
        if track.provenance.contains(.measuredBass) {
            let lookahead = 8.0
            let window = seconds...(seconds + lookahead)
            return track.bassRanges.contains { $0.overlaps(window) }
        }
        guard !track.envelope.isEmpty, track.duration > 0 else { return true }
        let idx = min(track.envelope.count - 1,
                      max(0, Int(seconds / track.duration * Double(track.envelope.count))))
        return Double(track.envelope[idx]) >= median * 0.5
    }

    private static func bars(from: TimeInterval, to: TimeInterval, grid: BeatGrid?) -> Int? {
        guard let grid, grid.barDuration > 0 else { return nil }
        return max(0, Int((to - from) / grid.barDuration))
    }

    private static func barsUntilNext(after seconds: TimeInterval, in track: TrackFeatures) -> Int? {
        guard let grid = track.beatGrid, grid.barDuration > 0 else { return nil }
        guard let next = track.sections.first(where: { $0.start > seconds + 0.5 }) else { return nil }
        return max(0, Int((next.start - seconds) / grid.barDuration))
    }

    private static func isOnPhrase(_ seconds: TimeInterval, _ track: TrackFeatures) -> Bool {
        guard track.beatGrid?.beatPeriod ?? 0 > 0 else { return false }
        return abs(track.beatsFromPhraseBoundary(at: seconds)) < 0.25
    }

    private static func snap(_ point: ExitPoint, track: TrackFeatures, profile: DJProfile) -> ExitPoint {
        if let preferred = track.preferredExitSeconds,
           abs(preferred - point.seconds) < 0.001 { return point }
        guard let grid = track.beatGrid else { return point }
        guard grid.confidence >= profile.minGridConfidence, grid.phraseDuration > 1 else {
            return point
        }
        let offsetBeats = track.beatsFromPhraseBoundary(at: point.seconds)
        let snapped = grid.nearestDownbeat(to: point.seconds - offsetBeats * grid.beatPeriod)
        guard snapped > 0 else { return point }
        return ExitPoint(
            seconds: snapped,
            kind: point.kind,
            barsRemaining: point.barsRemaining,
            onPhraseBoundary: true,
            confidence: point.confidence
        )
    }
}

enum DJTemplates {

    static let bassSwapBlend: TransitionTemplateID = "bassSwapBlend"
    static let filterFadeOut: TransitionTemplateID = "filterFadeOut"
    static let filterBloomIn: TransitionTemplateID = "filterBloomIn"
    static let highPassThinOut: TransitionTemplateID = "highPassThinOut"
    static let cutOnTheOne: TransitionTemplateID = "cutOnTheOne"
    static let halfTimeBlend: TransitionTemplateID = "halfTimeBlend"
    static let loopRollDown: TransitionTemplateID = "loopRollDown"
    static let echoOut: TransitionTemplateID = "echoOut"
    static let tempoRampBlend: TransitionTemplateID = "tempoRampBlend"
    static let doubleDrop: TransitionTemplateID = "doubleDrop"

    static var v1Registry: TransitionRegistry {
        TransitionRegistry([
            BassSwapBlendTemplate(),
            FilterFadeOutTemplate(),
            FilterBloomInTemplate(),
            HighPassThinOutTemplate(),
            HalfTimeBlendTemplate(),
            CutOnTheOneTemplate(),
            LoopRollDownTemplate(),
            EchoOutTemplate(),
            TempoRampBlendTemplate(),
            DoubleDropTemplate()
        ] + DJMoveIDs.templates)
    }

    static func displayName(for id: TransitionTemplateID) -> String {
        v1Registry.templates[id]?.displayName ?? id.rawValue
    }
}

enum DJBlendMath {

    static func window(bars: Int, grid: BeatGrid?, fallback: TimeInterval) -> TimeInterval {
        let seconds: TimeInterval
        if let grid, grid.barDuration > 0 {
            seconds = grid.barDuration * Double(bars)
        } else {
            seconds = fallback
        }
        return min(DJEngineConstants.maximumTransitionSeconds, seconds)
    }

    static func sweepWindow(available: TimeInterval, minimum: TimeInterval, grid: BeatGrid?) -> TimeInterval {
        let ceiling = min(available * 0.9, DJEngineConstants.maximumTransitionSeconds)
        if let grid, grid.barDuration > 0 {
            for bars in [32.0, 16.0, 8.0] where bars * grid.barDuration <= ceiling && bars * grid.barDuration >= minimum {
                return bars * grid.barDuration
            }
        }
        return min(max(minimum, available * 0.9), DJEngineConstants.maximumTransitionSeconds)
    }

    static func bassSwap(
        window: TimeInterval,
        grid: BeatGrid?,
        profile: DJProfile
    ) -> (at: TimeInterval, duration: TimeInterval) {
        let beats = 1.0

        guard let grid, grid.beatPeriod > 0, grid.phraseDuration > 0 else {
            let fallbackDuration = grid.map { min(0.6, max(0.3, $0.beatPeriod)) } ?? 0.5
            return (at: window * 0.55, duration: min(fallbackDuration, window * 0.2))
        }

        let duration = min(grid.beatPeriod * beats, window * 0.25)
        let target = window * 0.55
        let phrases = (target / grid.phraseDuration).rounded(.down)
        var at = phrases * grid.phraseDuration
        if at < grid.phraseDuration * 0.5 || at + duration > window {
            let bars = (target / grid.barDuration).rounded(.down)
            at = bars * grid.barDuration
        }
        at = min(max(0, at), max(0, window - duration))
        return (at: at, duration: duration)
    }

}

struct BassSwapBlendTemplate: TransitionTemplate {
    let id = DJTemplates.bassSwapBlend
    let displayName = "Bass swap"
    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue, .snappedBassSwap
    ]

    static let minRunwaySeconds: TimeInterval = 12

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= 45 else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is only \(Int(outgoing.duration))s, too short to blend out of")
        }
        guard incoming.duration >= 45 else {
            return .rejected(reason: "\(displayName): \(incoming.displayName) is only \(Int(incoming.duration))s, too short to blend into")
        }
        guard DJGridTrust.phaseLocked(outgoing, incoming, profile: profile) else {
            return .rejected(reason: "\(displayName): blending two beats needs measured downbeats on both tracks")
        }
        let earliest = outgoing.duration * profile.exitRegionFloor
        guard outgoing.duration - earliest >= Self.minRunwaySeconds else {
            return .rejected(reason: "\(displayName): only \(Int(outgoing.duration - earliest))s of runway past \(Int(profile.exitRegionFloor * 100))% of \(outgoing.displayName), needs \(Int(Self.minRunwaySeconds))s")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        var plans: [DJTransitionPlan] = []
        let globalRelation = DJTempo.grid(outgoing, incoming)

        let handovers = DJHandover.options(outgoing: outgoing, incoming: incoming, exits: exits, entries: entries, profile: profile, lengths: barChoices(profile: profile))
        if !handovers.isEmpty {
            let beat = outgoing.beatGrid?.beatPeriod ?? 0.5
            for option in handovers {
                let relation = DJTempo.local(outgoing, exit: option.exit.seconds, overlap: option.window, incoming, entry: option.entry.seconds) ?? globalRelation
                plans.append(DJTransitionPlan(
                    templateId: id, profileId: profile.id,
                    outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                    exit: option.exit, entry: option.entry,
                    overlapSeconds: option.window,
                    bassSwapAtSeconds: option.swapWall, bassSwapSeconds: min(beat, option.window * 0.25),
                    incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                    tempoFactor: relation?.factor ?? 1,
                    tempoLabel: relation?.label ?? "tempo unknown",
                    accent: nil,
                    profileMinimumScore: profile.minimumScoreToFire
                ))
            }
            return plans
        }

        let bassCapableEntries = entries.filter(\.hasBassFromHere)

        for exit in exits.prefix(DJHandover.maximumExits) {
            let available = outgoing.duration - exit.seconds
            guard available >= 4 else { continue }

            for bars in barChoices(profile: profile) {
                var window = DJBlendMath.window(
                    bars: bars, grid: outgoing.beatGrid, fallback: Double(bars) * 1.875
                )
                window = min(window, available - 0.5)
                guard window >= 4 else { continue }

                for entry in bassCapableEntries.prefix(DJHandover.maximumFallbackEntries) {
                    if let untilNext = entry.barsUntilNextSection, untilNext < 4 { continue }

                    let swap = DJBlendMath.bassSwap(
                        window: window, grid: outgoing.beatGrid, profile: profile
                    )
                    let relation = DJTempo.local(
                        outgoing, exit: exit.seconds, overlap: window, incoming, entry: entry.seconds
                    ) ?? globalRelation
                    plans.append(DJTransitionPlan(
                        templateId: id, profileId: profile.id,
                        outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                        exit: exit, entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                        incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                        tempoFactor: relation?.factor ?? 1,
                        tempoLabel: relation?.label ?? "tempo unknown",
                        accent: nil,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }

    private func barChoices(profile: DJProfile) -> [Int] {
        DJHandover.lengths.filter { profile.transitionBarsRange.contains($0) }
    }
}

enum DJHandover {
    static let lengths = [4, 8, 16, 24, 32, 40, 48, 64]
    static let maximumExits = 8
    static let maximumArrivals = 3
    static let maximumFallbackEntries = 4
    static let maximumSeconds: TimeInterval = 135
    static let bassRunBars = 4
    static let bassDropDecibels: Float = 6

    struct Option: Equatable, Sendable {
        let exit: ExitPoint
        let entry: EntryPoint
        let bars: Int
        let swapBars: Int
        let arrival: TimeInterval
        let swapWall: TimeInterval
        let window: TimeInterval
    }

    static func bassBars(_ track: TrackFeatures) -> [Bool]? {
        let count = track.barStarts.count
        guard count >= 16, let profile = track.barProfile, profile.level.count == count,
              let bands = profile.bands, bands.count == count * 4 else { return nil }
        let measured = profile.level.filter { $0 > -89 }
        guard measured.count >= 8 else { return nil }
        let body = DJMoveRails.percentile(measured, 0.75)
        let lows = (0..<count).map { bands[$0 * 4] * DJMoveRails.bandDecibelsPerUnit }
        let loud = (0..<count).filter { profile.level[$0] >= body - 3 }.map { lows[$0] }
        let typical = DJMoveRails.percentile(loud.isEmpty ? lows : loud, 0.5)
        return (0..<count).map { lows[$0] >= typical - bassDropDecibels && profile.level[$0] > -89 }
    }

    static func feasibleBars(outgoing: TrackFeatures, incoming: TrackFeatures) -> Int {
        guard outgoing.provenance.contains(.measuredBeatGrid), incoming.provenance.contains(.measuredBeatGrid),
              let outBar = outgoing.beatGrid?.barDuration, outBar > 0,
              let inBar = incoming.beatGrid?.barDuration, inBar > 0 else { return 0 }
        let release = max(DJMoveRails.payoffEnd(outgoing) ?? 0, outgoing.duration * 0.45, outgoing.earliestExitSeconds)
        let tailBars = Int((outgoing.duration - 1 - release) / outBar)
        let introBars: Int
        if bassBars(incoming) == nil {
            introBars = 8
        } else {
            introBars = arrivals(incoming, ceilingFraction: 0.35).map { Int((($0 - incoming.contentStart) / inBar).rounded()) }.max() ?? 0
        }
        return [64, 32, 16, 8].first { tailBars >= $0 && introBars >= $0 / 2 } ?? 0
    }

    static func arrivals(_ incoming: TrackFeatures, profile: DJProfile) -> [TimeInterval] {
        arrivals(incoming, ceilingFraction: max(profile.entryRegionCeiling, 0.35))
    }

    static func arrivals(_ incoming: TrackFeatures, ceilingFraction: Double) -> [TimeInterval] {
        let starts = incoming.barStarts
        let ceiling = max(incoming.contentStart + 1, incoming.duration * ceilingFraction)
        var first: [TimeInterval] = []
        var later: [TimeInterval] = []
        if let arrangement = incoming.arrangement {
            for b in 1..<max(1, arrangement.barCount) {
                guard let role = arrangement.role(atBar: b), let previous = arrangement.role(atBar: b - 1),
                      [.groove, .dropOpening, .dropGroove].contains(role), previous.isIntro || previous == .breakdown || previous == .build,
                      arrangement.barStarts.indices.contains(b), arrangement.barStarts[b] <= ceiling else { continue }
                first.append(arrangement.barStarts[b])
            }
        }
        guard let bass = bassBars(incoming) else {
            return Array(first.filter { $0 <= ceiling }.prefix(maximumArrivals))
        }
        for b in starts.indices where starts[b] >= incoming.contentStart - 0.05 && starts[b] <= ceiling {
            guard b + bassRunBars <= starts.count, (b..<(b + bassRunBars)).allSatisfy({ bass[$0] }),
                  DJMoveSupport.isPhraseLine(incoming, starts[b]) else { continue }
            let arrives = b == 0 || !bass[b - 1] || starts[b - 1] < incoming.contentStart - 0.05
            if arrives { first.append(starts[b]) } else { later.append(starts[b]) }
        }
        for drop in DJMoveSupport.drops(incoming) where drop <= ceiling && drop >= incoming.contentStart - 0.05 {
            if !first.contains(where: { abs($0 - drop) < 0.5 }) { first.append(drop) }
        }
        var seen = Set<Int>()
        let ordered = (first.isEmpty ? later.sorted() : first.sorted()).filter { seen.insert(Int(($0 * 2).rounded())).inserted }
        return Array(ordered.prefix(maximumArrivals))
    }

    static func options(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, lengths: [Int]) -> [Option] {
        guard outgoing.beatGrid != nil, incoming.beatGrid != nil, !DJMoveSupport.downbeats(incoming).isEmpty else { return [] }
        let arrivals = arrivals(incoming, profile: profile)
        let cued = entries.filter { $0.confidence >= 1 && $0.hasBassFromHere }.map(\.seconds)
        guard !arrivals.isEmpty || !cued.isEmpty else { return [] }
        var out: [Option] = []
        for exit in exits.prefix(maximumExits) {
            for bars in lengths {
                for swapBars in swapChoices(bars) {
                guard let end = DJMoveSupport.downbeat(outgoing, from: exit.seconds, bars: bars), end < outgoing.duration - 1,
                      let swap = DJMoveSupport.downbeat(outgoing, from: exit.seconds, bars: swapBars) else { continue }
                let window = end - exit.seconds
                guard window <= maximumSeconds else { continue }
                for arrival in arrivals {
                    if let swapLine = DJMoveSupport.downbeat(incoming, from: arrival, bars: swapBars), arrival >= incoming.contentStart - 0.05 {
                        out.append(Option(exit: exit, entry: DJMoveSupport.entryPoint(incoming, arrival, confidence: 0.75), bars: bars, swapBars: swapBars, arrival: swapLine, swapWall: swap - exit.seconds, window: window))
                    }
                    guard let entrySeconds = DJMoveSupport.downbeat(incoming, from: arrival, bars: -swapBars),
                          entrySeconds >= incoming.contentStart - 0.05 else { continue }
                    let entry = DJMoveSupport.entryPoint(incoming, entrySeconds, confidence: 0.8)
                    out.append(Option(exit: exit, entry: entry, bars: bars, swapBars: swapBars, arrival: arrival, swapWall: swap - exit.seconds, window: window))
                }
                for seconds in cued {
                    guard let entryPoint = entries.first(where: { $0.seconds == seconds }),
                          let arrival = DJMoveSupport.downbeat(incoming, from: seconds, bars: swapBars) else { continue }
                    out.append(Option(exit: exit, entry: entryPoint, bars: bars, swapBars: swapBars, arrival: arrival, swapWall: swap - exit.seconds, window: window))
                }
                }
            }
        }
        return out
    }

    static func swapChoices(_ bars: Int) -> [Int] {
        guard bars >= 16 else { return [] }
        let half = bars / 2
        guard half % 8 != 0 else { return [half] }
        let low = half - half % 8
        return [low, low + 8]
    }
}

struct FilterFadeOutTemplate: TransitionTemplate {
    let id = DJTemplates.filterFadeOut
    let displayName = "Filter fade"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .lowPassFilter, .entryCue]

    static let minimumSeconds: TimeInterval = 10

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= DJEngineConstants.minimumPlannableDuration else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is too short to sweep out of")
        }
        guard DJGridTrust.phaseLocked(outgoing, incoming, profile: profile) else {
            return .rejected(reason: "\(displayName): a long sweep over two beats needs measured downbeats on both tracks")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        let usable = exits.filter {
            $0.kind == .breakdown || $0.kind == .cooldown || $0.kind == .outro || $0.kind == .build
        }
        guard let entry = entries.first else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable.prefix(3) {
            let available = outgoing.duration - exit.seconds
            let window = DJBlendMath.sweepWindow(
                available: available, minimum: Self.minimumSeconds, grid: outgoing.beatGrid
            )
            guard window >= Self.minimumSeconds, window <= available else { continue }

            let swap = DJBlendMath.bassSwap(window: window, grid: outgoing.beatGrid, profile: profile)
            let relation = DJTempo.local(outgoing, exit: exit.seconds, overlap: window, incoming, entry: entry.seconds)
                ?? DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: window,
                bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .outgoingFilterClose,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct FilterBloomInTemplate: TransitionTemplate {
    let id = DJTemplates.filterBloomIn
    let displayName = "Filter bloom"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .lowPassFilter, .entryCue]

    static let minimumSeconds: TimeInterval = 8

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= DJEngineConstants.minimumPlannableDuration else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is too short to sweep out of")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard DJGridTrust.phaseLocked(outgoing, incoming, profile: profile) else { return [] }
        let usable = exits.filter { $0.kind == .ambientOutro || $0.kind == .cooldown }
        guard let entry = entries.first else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable.prefix(3) {
            let available = outgoing.duration - exit.seconds
            let window = DJBlendMath.sweepWindow(
                available: available, minimum: Self.minimumSeconds, grid: outgoing.beatGrid
            )
            guard window >= Self.minimumSeconds, window <= available else { continue }

            let swap = DJBlendMath.bassSwap(window: window, grid: outgoing.beatGrid, profile: profile)
            let relation = DJTempo.local(outgoing, exit: exit.seconds, overlap: window, incoming, entry: entry.seconds)
                ?? DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: window,
                bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .incomingFilterOpen,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct HighPassThinOutTemplate: TransitionTemplate {
    let id = DJTemplates.highPassThinOut
    let displayName = "High-pass handover"
    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .highPassFilter, .timeStretch,
        .entryCue, .sampleAccurateCue
    ]

    static let targetHertz = 600.0
    static let unlockedBars = 4

    static func locked(_ outgoing: TrackFeatures, _ incoming: TrackFeatures, profile: DJProfile) -> Bool {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid else { return false }
        return outgoing.provenance.contains(.measuredBeatGrid) && incoming.provenance.contains(.measuredBeatGrid)
            && a.confidence >= profile.minGridConfidence && b.confidence >= profile.minGridConfidence
    }

    static func tempoOnly(_ outgoing: TrackFeatures, _ incoming: TrackFeatures) -> Bool {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid, a.bpm > 0, b.bpm > 0 else { return false }
        return outgoing.provenance.contains(.measuredTempo) && incoming.provenance.contains(.measuredTempo)
            && (!outgoing.provenance.contains(.measuredBeatGrid) || !incoming.provenance.contains(.measuredBeatGrid))
    }

    func admits(
        outgoing: TrackFeatures,
        incoming: TrackFeatures,
        profile: DJProfile
    ) -> TemplateAdmission {
        guard let outgoingGrid = outgoing.beatGrid,
              let incomingGrid = incoming.beatGrid,
              Self.locked(outgoing, incoming, profile: profile) || Self.tempoOnly(outgoing, incoming) else {
            return .rejected(reason: "\(displayName): a tempo-locked handover needs measured grids on both tracks")
        }
        guard let relation = DJTempo.best(outgoing: outgoingGrid, incoming: incomingGrid) else {
            return .rejected(reason: "\(displayName): no usable tempo relation")
        }
        let rate = DJTempo.applicableRate(relation, profile: profile)
        let remainingDrift = DJTempo.driftMs(
            leftover: DJTempo.leftover(relation, appliedRate: rate),
            overlapSeconds: 8 * outgoingGrid.barDuration
        )
        guard remainingDrift <= profile.maxDriftMs else {
            return .rejected(reason: "\(displayName): the decks would drift \(Int(remainingDrift.rounded())) ms during the sweep")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures,
        incoming: TrackFeatures,
        exits: [ExitPoint],
        entries: [EntryPoint],
        profile: DJProfile,
        rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let grid = outgoing.beatGrid else { return [] }
        guard let relation = DJTempo.grid(outgoing, incoming) else { return [] }

        let fullBodyEntries = entries.filter(\.hasBassFromHere)
        guard !fullBodyEntries.isEmpty else { return [] }

        let unlocked = !Self.locked(outgoing, incoming, profile: profile)
        var plans: [DJTransitionPlan] = []
        for exit in exits.prefix(3) {
            let available = outgoing.duration - exit.seconds
            for bars in (unlocked ? [Self.unlockedBars] : [4, 8].filter({ profile.transitionBarsRange.contains($0) })) {
                let window = min(Double(bars) * grid.barDuration, available - 0.5)
                guard window >= 4 else { continue }
                let thinOver = unlocked ? min(window, grid.barDuration) : window
                let handoverDuration = min(grid.barDuration, max(0.1, window * 0.4))
                let handoverAt = min(max(0, window * 0.55 - handoverDuration / 2), max(0, window - handoverDuration))

                for entry in fullBodyEntries.prefix(2) {
                    let stages: [TransitionStage] = [
                        TransitionStage(
                            at: 0, on: .outgoing,
                            .highPassTo(hertz: Self.targetHertz, over: thinOver),
                            snap: .free
                        ),
                        TransitionStage(
                            at: 0, on: .incoming,
                            .crossfadeTo(position: 1, over: window),
                            snap: .free
                        ),
                        TransitionStage(
                            at: handoverAt, on: .incoming,
                            .eqLow(decibels: 0, over: handoverDuration),
                            snap: .bar
                        )
                    ]
                    plans.append(DJTransitionPlan(
                        templateId: id,
                        profileId: profile.id,
                        outgoingTrackId: outgoing.trackId,
                        incomingTrackId: incoming.trackId,
                        exit: exit,
                        entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: handoverAt,
                        bassSwapSeconds: handoverDuration,
                        incomingRateRatio: DJTempo.applicableRate(relation, profile: profile),
                        tempoFactor: relation.factor,
                        tempoLabel: relation.label,
                        accent: nil,
                        stages: stages,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }
}

struct HalfTimeBlendTemplate: TransitionTemplate {
    let id = DJTemplates.halfTimeBlend
    let displayName = "Half-time blend"
    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue, .snappedBassSwap
    ]

    static let maxResidual = 0.01

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              outgoing.provenance.contains(.measuredBeatGrid),
              incoming.provenance.contains(.measuredBeatGrid) else {
            return .rejected(reason: "\(displayName): needs a measured beat grid on both tracks")
        }
        guard let relation = DJTempo.best(outgoing: a, incoming: b) else {
            return .rejected(reason: "\(displayName): no usable tempo on one side")
        }
        guard relation.factor == 2.0 || relation.factor == 0.5 else {
            return .rejected(reason: "\(displayName): \(DJFormat.bpm(a.bpm)) against \(DJFormat.bpm(b.bpm)) is not a 2:1 relation")
        }
        guard relation.residual <= Self.maxResidual else {
            return .rejected(reason: "\(displayName): the 2:1 fold still leaves \(DJFormat.percent(relation.residual * 100, decimals: 2)) out - that's a stretch, not a fold")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              let relation = DJTempo.best(outgoing: a, incoming: b) else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in exits.prefix(2) {
            let available = outgoing.duration - exit.seconds
            for bars in [8, 16].filter({ profile.transitionBarsRange.contains($0) }) {
                var window = DJBlendMath.window(bars: bars, grid: a, fallback: Double(bars) * 1.875)
                window = min(window, available - 0.5)
                guard window >= 8 else { continue }
                for entry in entries.prefix(2) {
                    let swap = DJBlendMath.bassSwap(window: window, grid: a, profile: profile)
                    plans.append(DJTransitionPlan(
                        templateId: id, profileId: profile.id,
                        outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                        exit: exit, entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                        incomingRateRatio: DJTempo.applicableRate(relation, profile: profile),
                        tempoFactor: relation.factor,
                        tempoLabel: relation.label,
                        accent: nil,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }
}

struct CutOnTheOneTemplate: TransitionTemplate {
    let id = DJTemplates.cutOnTheOne
    let displayName = "Clean cut"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade]

    static let fadeSeconds: TimeInterval = 0.05

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        let cue = exits.first { $0.confidence >= 1 }
        let point = cue ?? exits.max(by: { $0.seconds < $1.seconds })
            ?? ExitPoint(seconds: max(0, outgoing.duration - 1), kind: .outro,
                         barsRemaining: 0, onPhraseBoundary: false, confidence: 0.2)

        var cutAt = cue.map(\.seconds) ?? max(point.seconds, outgoing.duration - Self.fadeSeconds - 0.5)
        var onBoundary = point.onPhraseBoundary
        if let grid = outgoing.beatGrid, grid.barDuration > 0.1,
           outgoing.provenance.contains(.measuredBeatGrid) {
            let bars = ((cutAt - grid.firstDownbeat) / grid.barDuration).rounded(cue == nil ? .down : .toNearestOrAwayFromZero)
            let snapped = grid.nearestDownbeat(to: grid.firstDownbeat + bars * grid.barDuration)
            if snapped > 0, snapped <= outgoing.duration - Self.fadeSeconds {
                cutAt = snapped
                onBoundary = true
            }
        }
        let latest = ExitPoint(
            seconds: cutAt, kind: point.kind, barsRemaining: point.barsRemaining,
            onPhraseBoundary: onBoundary, confidence: point.confidence
        )
        let entry = entries.first ?? EntryPoint(
            seconds: 0, kind: .intro, barsUntilNextSection: nil,
            onPhraseBoundary: true, hasBassFromHere: true, confidence: 0.5
        )
        return [DJTransitionPlan(
            templateId: id, profileId: profile.id,
            outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
            exit: latest, entry: entry,
            overlapSeconds: Self.fadeSeconds,
            bassSwapAtSeconds: 0, bassSwapSeconds: Self.fadeSeconds,
            incomingRateRatio: 1, tempoFactor: 1, tempoLabel: "no tempo match needed",
            accent: nil,
            profileMinimumScore: profile.minimumScoreToFire
        )]
    }
}

struct LoopRollDownTemplate: TransitionTemplate {
    let id = DJTemplates.loopRollDown
    let displayName = "Loop roll-down"

    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .lowPassFilter, .loopBuffer,
        .loopResize, .sampleAccurateCue, .entryCue
    ]

    static let halvingLadder: [Double] = [8, 4, 2, 1]
    static let ownersLadder: [Double] = [8, 6, 4, 2, 1]

    let ladder: [Double]

    init(ladder: [Double] = LoopRollDownTemplate.halvingLadder) {
        self.ladder = ladder
    }

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.allowMidTrackExit || outgoing.extensionLoop != nil else {
            return .rejected(reason: "\(displayName): \(profile.displayName) doesn't cut tracks short")
        }
        guard let grid = outgoing.beatGrid, outgoing.provenance.contains(.measuredBeatGrid),
              grid.confidence >= profile.minGridConfidence else {
            return .rejected(reason: "\(displayName): a loop needs an accurate bar grid and there isn't one")
        }
        let needed = ladder.reduce(0, +) * grid.barDuration
        guard outgoing.duration >= needed + 30 else {
            return .rejected(reason: "\(displayName): the ladder needs \(Int(needed))s and \(outgoing.displayName) is only \(Int(outgoing.duration))s")
        }
        guard ladder.allSatisfy({ $0 > 0 }) else {
            return .rejected(reason: "\(displayName): every rung of the loop ladder needs a positive length")
        }
        guard (ladder.max() ?? 0) <= Double(profile.maxLoopBars) else {
            return .rejected(reason: "\(displayName): \(profile.displayName) limits loops to \(profile.maxLoopBars) bars")
        }
        guard max(0, ladder.count - 1) <= profile.maxLoopHalvings else {
            return .rejected(reason: "\(displayName): \(profile.displayName) only allows \(profile.maxLoopHalvings) loop reductions")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let grid = outgoing.beatGrid, grid.barDuration > 0 else { return [] }
        guard let entry = entries.first else { return [] }

        let loopExits = outgoing.extensionLoop.map { loop in exits.filter { abs($0.seconds - loop.lowerBound) < 0.5 } } ?? []
        let preferred = exits.filter { $0.kind == .drop || $0.kind == .outro || $0.kind == .unknown }
        let usable = !loopExits.isEmpty ? Array(loopExits.prefix(1))
            : preferred.isEmpty ? Array(exits.prefix(1)) : Array(preferred.prefix(2))
        guard !usable.isEmpty else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable {
            var stages: [TransitionStage] = []
            var t: TimeInterval = 0

            for bars in ladder {
                stages.append(TransitionStage(at: t, on: .outgoing, .loop(bars: bars), snap: .bar))
                t += bars * grid.barDuration
            }

            stages.append(TransitionStage(
                at: 0, on: .outgoing,
                .lowPassTo(hertz: DJEngineConstants.accentClosedFilterHz, over: t),
                snap: .free
            ))

            let fade = CutOnTheOneTemplate.fadeSeconds
            stages.append(TransitionStage(at: t, on: .outgoing, .clearLoop, snap: .bar))
            stages.append(TransitionStage(at: t, on: .outgoing, .hardCut(fadeSeconds: fade), snap: .bar))
            stages.append(TransitionStage(at: t, on: .incoming, .crossfadeTo(position: 1, over: fade), snap: .bar))

            let relation = DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: t + fade,
                bassSwapAtSeconds: t, bassSwapSeconds: fade,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .outgoingFilterClose,
                stages: stages,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct EchoOutTemplate: TransitionTemplate {
    let id = DJTemplates.echoOut
    let displayName = "Echo out"

    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .delayPerDeck, .entryCue
    ]

    static let tailBars = 4
    static let throwBars = 1
    static let releaseBars = 2
    static let feedback = 0.55
    static let fallbackBeatPeriod: TimeInterval = 0.5

    private func usableGrid(outgoing: TrackFeatures, profile: DJProfile) -> (grid: BeatGrid, isEstimated: Bool)? {
        if let grid = outgoing.beatGrid, outgoing.provenance.contains(.measuredBeatGrid),
           grid.confidence >= profile.minGridConfidence {
            return (grid, false)
        }
        guard profile.id != .wedding else { return nil }
        let period = outgoing.beatGrid?.beatPeriod ?? Self.fallbackBeatPeriod
        return (BeatGrid(anchor: 0, beatPeriod: period, confidence: DJEngineConstants.tempoOnlyGridConfidence), true)
    }

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.allowMidTrackExit else {
            return .rejected(reason: "\(displayName): \(profile.displayName) doesn't cut tracks short")
        }
        guard let (grid, _) = usableGrid(outgoing: outgoing, profile: profile) else {
            return .rejected(reason: "\(displayName): the tail is beat-synced and there is no trustworthy grid")
        }
        let needed = Double(Self.tailBars) * grid.barDuration
        guard outgoing.duration >= needed + DJEngineConstants.minimumPlannableDuration else {
            return .rejected(reason: "\(displayName): the tail needs \(Int(needed))s and \(outgoing.displayName) is only \(Int(outgoing.duration))s")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let (grid, isEstimated) = usableGrid(outgoing: outgoing, profile: profile), grid.barDuration > 0 else { return [] }
        guard let entry = entries.first else { return [] }

        let preferred = exits.filter { $0.kind == .drop || $0.kind == .breakdown || $0.kind == .cooldown }
        let usable = preferred.isEmpty ? Array(exits.prefix(1)) : Array(preferred.prefix(2))
        guard !usable.isEmpty else { return [] }

        let beat = grid.beatPeriod
        let fade = CutOnTheOneTemplate.fadeSeconds
        let throwSeconds = Double(Self.throwBars) * grid.barDuration
        let release = Double(Self.releaseBars) * grid.barDuration

        var plans: [DJTransitionPlan] = []
        for exit in usable {
            guard outgoing.duration - exit.seconds - 0.5 >= throwSeconds else { continue }

            let stages: [TransitionStage] = [
                TransitionStage(at: 0, on: .outgoing,
                    .delayWet(mix: 0.45, feedback: Self.feedback, over: beat), snap: .free),
                TransitionStage(at: throwSeconds, on: .outgoing,
                    .echoCut(feedback: Self.feedback, release: release), snap: .bar),
                TransitionStage(at: throwSeconds, on: .incoming,
                    .crossfadeTo(position: 1, over: fade), snap: .bar),
                TransitionStage(at: throwSeconds, on: .incoming,
                    .eqLow(decibels: 0, over: beat), snap: .bar)
            ]

            let relation = isEstimated ? nil : DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: throwSeconds + release + fade,
                bassSwapAtSeconds: throwSeconds, bassSwapSeconds: beat,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: isEstimated ? "estimated tempo" : (relation?.label ?? "tempo unknown"),
                accent: nil,
                stages: stages,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct TempoRampBlendTemplate: TransitionTemplate {
    let id = DJTemplates.tempoRampBlend
    let displayName = "Tempo ramp"

    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue
    ]

    static let maxResidual = 0.02
    static let settleFraction = 0.15

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.allowVarispeed else {
            return .rejected(reason: "\(displayName): \(profile.displayName) doesn't ride the pitch")
        }
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              outgoing.provenance.contains(.measuredBeatGrid),
              incoming.provenance.contains(.measuredBeatGrid) else {
            return .rejected(reason: "\(displayName): needs a measured beat grid on both tracks")
        }
        guard let relation = DJTempo.best(outgoing: a, incoming: b) else {
            return .rejected(reason: "\(displayName): no usable tempo on one side")
        }
        guard relation.residual <= Self.maxResidual else {
            return .rejected(reason: "\(displayName): \(DJFormat.bpm(a.bpm)) against \(DJFormat.bpm(b.bpm)) is a key change, not a nudge")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              let relation = DJTempo.best(outgoing: a, incoming: b) else { return [] }

        let m = profile.maxAbsRatePercent / 100
        let outgoingTarget = min(1 + m, max(1 - m, 1 / relation.requiredRate))
        guard abs(outgoingTarget - 1) > 0.001 else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in exits.prefix(2) {
            let available = outgoing.duration - exit.seconds
            for bars in [8, 16].filter({ profile.transitionBarsRange.contains($0) }) {
                var window = DJBlendMath.window(bars: bars, grid: a, fallback: Double(bars) * 1.875)
                window = min(window, available - 0.5)
                guard window >= 6 else { continue }
                for entry in entries.prefix(2) {
                    let swap = DJBlendMath.bassSwap(window: window, grid: a, profile: profile)
                    let settle = max(1, window * Self.settleFraction)

                    let stages: [TransitionStage] = [
                        TransitionStage(at: 0, on: .outgoing,
                            .rateRatio(outgoingTarget, over: window - settle), snap: .free),
                        TransitionStage(at: 0, on: .incoming,
                            .crossfadeTo(position: 1, over: window), snap: .free),
                        TransitionStage(at: swap.at, on: .incoming,
                            .eqLow(decibels: 0, over: swap.duration), snap: .bar),
                        TransitionStage(at: swap.at, on: .outgoing,
                            .eqLow(decibels: MixEngine.eqGainRange.lowerBound, over: swap.duration), snap: .bar),
                        TransitionStage(at: window - settle, on: .incoming,
                            .rateRatio(1, over: settle), snap: .free)
                    ]

                    plans.append(DJTransitionPlan(
                        templateId: id, profileId: profile.id,
                        outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                        exit: exit, entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                        incomingRateRatio: DJTempo.applicableRate(relation, profile: profile),
                        tempoFactor: relation.factor,
                        tempoLabel: relation.label,
                        accent: nil,
                        stages: stages,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }
}

struct DoubleDropTemplate: TransitionTemplate {
    let id = DJTemplates.doubleDrop
    let displayName = "Double drop"

    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue
    ]

    static let maxResidual = 0.02
    static let overlapBars = 4

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              outgoing.provenance.contains(.measuredBeatGrid),
              incoming.provenance.contains(.measuredBeatGrid) else {
            return .rejected(reason: "\(displayName): lining up two drops needs a measured grid on both tracks")
        }
        guard outgoing.provenance.contains(.measuredStructure),
              incoming.provenance.contains(.measuredStructure) else {
            return .rejected(reason: "\(displayName): can't line up drops that were never found")
        }
        guard let relation = DJTempo.best(outgoing: a, incoming: b),
              [1.0, 2.0, 0.5].contains(relation.factor),
              relation.residual <= Self.maxResidual else {
            return .rejected(reason: "\(displayName): the tempos don't fold onto each other cleanly")
        }
        let floor = outgoing.duration * profile.exitRegionFloor
        guard outgoing.sections.contains(where: { $0.kind == .drop && $0.start >= floor }) else {
            return .rejected(reason: "\(displayName): no drop left in \(outgoing.displayName) to play to")
        }
        guard incoming.sections.contains(where: { $0.kind == .drop }) else {
            return .rejected(reason: "\(displayName): \(incoming.displayName) has no drop to land on")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let grid = outgoing.beatGrid, grid.barDuration > 0,
              let relation = DJTempo.grid(outgoing, incoming) else { return [] }

        let floor = outgoing.duration * profile.exitRegionFloor
        let outDrops = outgoing.sections.filter { $0.kind == .drop && $0.start >= floor }
        let inDrops = incoming.sections.filter { $0.kind == .drop }

        let overlap = min(DJBlendMath.window(bars: Self.overlapBars, grid: grid,
                                             fallback: Double(Self.overlapBars) * 1.875),
                          DJEngineConstants.maximumTransitionSeconds)
        let beat = grid.beatPeriod
        let fade = CutOnTheOneTemplate.fadeSeconds

        var plans: [DJTransitionPlan] = []
        for outDrop in outDrops.prefix(2) {
            let exitSeconds = outDrop.start - overlap
            guard exitSeconds > 0, exitSeconds < outgoing.duration - overlap - 1 else { continue }
            let exit = ExitPoint(
                seconds: exitSeconds,
                kind: outgoing.section(at: exitSeconds),
                barsRemaining: Int((outgoing.duration - exitSeconds) / grid.barDuration),
                onPhraseBoundary: true,
                confidence: 0.8
            )
            for inDrop in inDrops.prefix(2) {
                let entrySeconds = max(0, inDrop.start - overlap)
                let entry = EntryPoint(
                    seconds: entrySeconds,
                    kind: incoming.section(at: entrySeconds),
                    barsUntilNextSection: Int((inDrop.start - entrySeconds) / grid.barDuration),
                    onPhraseBoundary: true,
                    hasBassFromHere: true,
                    confidence: 0.8
                )

                let stages: [TransitionStage] = [
                    TransitionStage(at: 0, on: .incoming,
                        .crossfadeTo(position: 0.5, over: overlap), snap: .free),
                    TransitionStage(at: max(0, overlap - 2 * beat), on: .outgoing,
                        .eqLow(decibels: MixEngine.eqGainRange.lowerBound, over: 2 * beat), snap: .bar),
                    TransitionStage(at: overlap, on: .incoming,
                        .eqLow(decibels: 0, over: beat), snap: .bar),
                    TransitionStage(at: overlap, on: .incoming,
                        .crossfadeTo(position: 1, over: beat), snap: .bar),
                    TransitionStage(at: overlap + beat, on: .outgoing,
                        .hardCut(fadeSeconds: fade), snap: .bar)
                ]

                plans.append(DJTransitionPlan(
                    templateId: id, profileId: profile.id,
                    outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                    exit: exit, entry: entry,
                    overlapSeconds: overlap + beat + fade,
                    bassSwapAtSeconds: max(0, overlap - 2 * beat), bassSwapSeconds: 3 * beat,
                    incomingRateRatio: DJTempo.applicableRate(relation, profile: profile),
                    tempoFactor: relation.factor,
                    tempoLabel: relation.label,
                    accent: nil,
                    stages: stages,
                    profileMinimumScore: profile.minimumScoreToFire
                ))
            }
        }
        return plans
    }
}

extension DJTempo {
    static func grid(_ outgoing: TrackFeatures, _ incoming: TrackFeatures) -> Relation? {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid else { return nil }
        return best(outgoing: a, incoming: b)
    }

    static func local(
        _ outgoing: TrackFeatures,
        exit: TimeInterval,
        overlap: TimeInterval,
        _ incoming: TrackFeatures,
        entry: TimeInterval
    ) -> Relation? {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid else { return nil }
        let span = max(overlap, 8 * a.barDuration)
        return best(
            outgoing: a.localized(from: exit, to: exit + span),
            incoming: b.localized(from: entry, to: entry + span)
        )
    }
}
