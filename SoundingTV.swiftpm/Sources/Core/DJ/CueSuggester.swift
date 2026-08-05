import Foundation

enum CueSuggester {

    static let identity = CueSuggesterIdentity(name: "sounding.envelope", version: 1)

    struct Input: Sendable, Equatable {
        let trackId: String
        let duration: TimeInterval
        let envelope: [Float]
        let beatGrid: BeatGrid?
        let sections: [TrackSection]

        init(
            trackId: String,
            duration: TimeInterval,
            envelope: [Float],
            beatGrid: BeatGrid? = nil,
            sections: [TrackSection] = []
        ) {
            self.trackId = trackId
            self.duration = duration
            self.envelope = envelope
            self.beatGrid = beatGrid
            self.sections = sections
        }

        init(features: TrackFeatures) {
            self.init(
                trackId: features.trackId,
                duration: features.duration,
                envelope: features.envelope,
                beatGrid: features.beatGrid,
                sections: features.sections
            )
        }
    }

    static let minimumDuration: TimeInterval = DJEngineConstants.minimumPlannableDuration
    static let maximumSuggestions = 6
    static let minimumSpacingSeconds: TimeInterval = 20
    static let minimumConfidence: Double = 0.3
    static let minimumGridConfidenceForSnapping: Double = 0.5

    static func suggest(_ input: Input) -> [CueSuggestion] {
        guard input.duration.isFinite, input.duration >= minimumDuration else { return [] }
        guard input.envelope.count >= 8 else { return [] }
        let bucketSeconds = input.duration / Double(input.envelope.count)
        guard bucketSeconds > 0 else { return [] }

        let stats = EnvelopeStats(envelope: input.envelope)

        var out: [CueSuggestion] = []

        let mixOut = mixOutSuggestion(input)
        if let mixOut { out.append(mixOut) }
        let mixIn = mixInSuggestion(input, stats: stats, bucketSeconds: bucketSeconds)
        if let mixIn { out.append(mixIn) }

        let bodyStart = mixIn?.positionSeconds ?? 0
        let bodyEnd = mixOut?.positionSeconds ?? (input.duration - 2)

        out += dropSuggestions(input, stats: stats, bucketSeconds: bucketSeconds, from: bodyStart, to: bodyEnd)
        out += breakdownSuggestions(input, stats: stats, bucketSeconds: bucketSeconds, from: bodyStart, to: bodyEnd)

        return prune(out)
    }

    static func mixOutSuggestion(_ input: Input) -> CueSuggestion? {
        guard let plan = PhantomDJEngine.plan(outgoingDuration: input.duration, envelope: input.envelope) else { return nil }

        let confidence: Double
        switch plan.outroShape {
        case .fadeToSilence: confidence = 0.78
        case .breakdown:     confidence = 0.70
        case .hardStop:      confidence = 0.45
        case .unknown:       return nil
        }

        let snap = snapped(plan.mixPointSeconds, grid: input.beatGrid, duration: input.duration)
        return CueSuggestion(
            trackId: input.trackId,
            kind: .mixOut,
            positionMillis: CueTime.millis(fromSeconds: snap.seconds),
            endMillis: nil,
            suggester: identity,
            confidence: confidence,
            reasoning: plan.reasoning + snapNote(snap),
            snappedToGrid: snap.didSnap,
            label: "Mix out",
            color: .mixOut
        )
    }

    static func mixInSuggestion(_ input: Input, stats: EnvelopeStats, bucketSeconds: TimeInterval) -> CueSuggestion? {
        var seconds: TimeInterval?
        var confidence = 0.0
        var reasoning = ""

        if let structural = structuralIntroEnd(input.sections) {
            seconds = structural.seconds
            confidence = 0.8
            reasoning = structural.reasoning
        } else {
            let silenceThreshold = max(0.02, stats.median * 0.12)
            let sustain = max(2, Int((2 / bucketSeconds).rounded()))
            guard let firstAudible = firstSustainedRun(
                input.envelope,
                where: { Double($0) > silenceThreshold },
                length: sustain
            ) else { return nil }

            let audibleSeconds = Double(firstAudible) * bucketSeconds
            seconds = audibleSeconds
            confidence = 0.45
            reasoning = audibleSeconds >= 1
                ? "Track opens with \(DJFormat.time(audibleSeconds)) of near-silence — starting the deck where sound actually begins."
                : "Sound from the first bucket."

            if let step = strongestRise(
                input.envelope,
                bucketSeconds: bucketSeconds,
                from: firstAudible,
                to: min(input.envelope.count - 1, firstAudible + Int((60 / bucketSeconds).rounded())),
                window: max(1, Int((4 / bucketSeconds).rounded())),
                minimumRatio: 1.6
            ), (Double(step.bucket) * bucketSeconds) - audibleSeconds >= 8 {
                let stepSeconds = Double(step.bucket) * bucketSeconds
                seconds = stepSeconds
                confidence = 0.58
                reasoning = "Ambient opening until \(DJFormat.time(stepSeconds)), then energy jumps "
                    + String(format: "%.1f×", step.ratio)
                    + " — that's where the beat comes in."
            }
        }

        guard var chosen = seconds else { return nil }
        guard chosen >= 1 else { return nil }
        chosen = CuePolicy.clamp(chosen, duration: input.duration)

        let snap = snapped(chosen, grid: input.beatGrid, duration: input.duration)
        return CueSuggestion(
            trackId: input.trackId,
            kind: .mixIn,
            positionMillis: CueTime.millis(fromSeconds: snap.seconds),
            endMillis: nil,
            suggester: identity,
            confidence: confidence,
            reasoning: reasoning + snapNote(snap),
            snappedToGrid: snap.didSnap,
            label: "Mix in",
            color: .mixIn
        )
    }

    private static func structuralIntroEnd(_ sections: [TrackSection]) -> (seconds: TimeInterval, reasoning: String)? {
        let ordered = sections.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return nil }
        if first.kind == .ambientIntro {
            return (first.end, "Measured structure: ambient intro ends at \(DJFormat.time(first.end)).")
        }
        if first.kind == .intro, first.start > 0 {
            return (first.start, "Measured structure: intro starts at \(DJFormat.time(first.start)).")
        }
        return nil
    }

    static func dropSuggestions(
        _ input: Input,
        stats: EnvelopeStats,
        bucketSeconds: TimeInterval,
        from startSeconds: TimeInterval,
        to endSeconds: TimeInterval
    ) -> [CueSuggestion] {
        let window = max(1, Int((4 / bucketSeconds).rounded()))
        let lower = max(window, Int(startSeconds / bucketSeconds))
        let upper = min(input.envelope.count - window, Int(endSeconds / bucketSeconds))
        guard upper - lower > window else { return [] }

        var candidates: [(bucket: Int, ratio: Double)] = []
        for i in lower..<upper {
            let before = mean(input.envelope, from: i - window, to: i)
            let after = mean(input.envelope, from: i, to: i + window)
            let ratio = after / max(0.06, before)
            guard ratio >= 1.35, after >= stats.median * 0.7 else { continue }
            candidates.append((i, ratio))
        }

        let peaks = localMaxima(candidates, minimumSeparation: max(1, Int(8 / bucketSeconds)))

        return peaks.sorted { $0.ratio > $1.ratio }.prefix(3).map { peak in
            let seconds = Double(peak.bucket) * bucketSeconds
            let snap = snapped(seconds, grid: input.beatGrid, duration: input.duration)
            return CueSuggestion(
                trackId: input.trackId,
                kind: .memory,
                positionMillis: CueTime.millis(fromSeconds: snap.seconds),
                endMillis: nil,
                suggester: identity,
                confidence: min(0.7, 0.32 + (peak.ratio - 1.35) * 0.45),
                reasoning: "Energy jumps " + String(format: "%.1f×", peak.ratio)
                    + " at \(DJFormat.time(snap.seconds)) — reads as a drop." + snapNote(snap),
                snappedToGrid: snap.didSnap,
                label: "Drop",
                color: .memory
            )
        }
    }

    static func breakdownSuggestions(
        _ input: Input,
        stats: EnvelopeStats,
        bucketSeconds: TimeInterval,
        from startSeconds: TimeInterval,
        to endSeconds: TimeInterval
    ) -> [CueSuggestion] {
        let lower = max(0, Int(startSeconds / bucketSeconds))
        let upper = min(input.envelope.count, Int(endSeconds / bucketSeconds))
        guard upper > lower else { return [] }

        let minimumRun = max(4, Int((8 / bucketSeconds).rounded()))
        var runs: [(start: Int, length: Int)] = []
        var runStart: Int?
        for i in lower..<upper {
            let isQuiet = Double(input.envelope[i]) <= stats.quietThreshold
            if isQuiet, runStart == nil { runStart = i }
            if !isQuiet, let start = runStart {
                if i - start >= minimumRun { runs.append((start, i - start)) }
                runStart = nil
            }
        }
        if let start = runStart, upper - start >= minimumRun { runs.append((start, upper - start)) }

        return runs.sorted { $0.length > $1.length }.prefix(2).map { run in
            let seconds = Double(run.start) * bucketSeconds
            let snap = snapped(seconds, grid: input.beatGrid, duration: input.duration)
            let lengthSeconds = Double(run.length) * bucketSeconds
            return CueSuggestion(
                trackId: input.trackId,
                kind: .memory,
                positionMillis: CueTime.millis(fromSeconds: snap.seconds),
                endMillis: nil,
                suggester: identity,
                confidence: min(0.6, 0.3 + lengthSeconds / 120),
                reasoning: "\(Int(lengthSeconds.rounded()))s of sustained low energy from "
                    + "\(DJFormat.time(snap.seconds)) — reads as a breakdown." + snapNote(snap),
                snappedToGrid: snap.didSnap,
                label: "Breakdown",
                color: .memory
            )
        }
    }

    struct EnvelopeStats: Sendable, Equatable {
        let median: Double
        let quietThreshold: Double

        init(envelope: [Float]) {
            guard !envelope.isEmpty else {
                median = 0
                quietThreshold = 0.05
                return
            }
            let sorted = envelope.sorted()
            let value = Double(sorted[sorted.count / 2])
            median = value
            quietThreshold = max(0.05, value * 0.55)
        }
    }

    static func snapped(
        _ seconds: TimeInterval,
        grid: BeatGrid?,
        duration: TimeInterval
    ) -> (seconds: TimeInterval, didSnap: Bool) {
        guard let grid,
              grid.confidence >= minimumGridConfidenceForSnapping,
              grid.beatPeriod > 0,
              grid.barDuration > 0
        else { return (seconds, false) }

        let downbeat = grid.anchor + Double(grid.downbeatOffset) * grid.beatPeriod
        let bars = ((seconds - downbeat) / grid.barDuration).rounded()
        let candidate = downbeat + bars * grid.barDuration
        guard candidate.isFinite, candidate >= 0 else { return (seconds, false) }
        let clamped = CuePolicy.clamp(candidate, duration: duration)
        guard abs(clamped - candidate) < 0.001 else { return (seconds, false) }
        return (clamped, true)
    }

    private static func snapNote(_ snap: (seconds: TimeInterval, didSnap: Bool)) -> String {
        snap.didSnap ? " Snapped to the nearest bar." : ""
    }

    static func prune(_ suggestions: [CueSuggestion]) -> [CueSuggestion] {
        let eligible = suggestions.filter { $0.confidence >= minimumConfidence }
        var kept = eligible.filter { $0.kind != .memory }

        let spacing = CueTime.millis(fromSeconds: minimumSpacingSeconds)
        let candidates = eligible.filter { $0.kind == .memory }.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.positionMillis != rhs.positionMillis { return lhs.positionMillis < rhs.positionMillis }
            return lhs.id < rhs.id
        }
        for candidate in candidates {
            guard kept.count < maximumSuggestions else { break }
            let clashes = kept.contains { other in
                other.kind == .memory && abs(other.positionMillis - candidate.positionMillis) < spacing
            }
            if clashes { continue }
            kept.append(candidate)
        }

        return kept.sorted { lhs, rhs in
            if lhs.positionMillis != rhs.positionMillis { return lhs.positionMillis < rhs.positionMillis }
            if lhs.kind != rhs.kind { return lhs.kind.sortRank < rhs.kind.sortRank }
            return lhs.id < rhs.id
        }
    }

    private static func mean(_ envelope: [Float], from lower: Int, to upper: Int) -> Double {
        let start = max(0, lower)
        let end = min(envelope.count, upper)
        guard end > start else { return 0 }
        var sum = 0.0
        for i in start..<end { sum += Double(envelope[i]) }
        return sum / Double(end - start)
    }

    private static func firstSustainedRun(
        _ envelope: [Float],
        where predicate: (Float) -> Bool,
        length: Int
    ) -> Int? {
        guard length > 0, envelope.count >= length else { return nil }
        var run = 0
        for i in envelope.indices {
            if predicate(envelope[i]) {
                run += 1
                if run >= length { return i - run + 1 }
            } else {
                run = 0
            }
        }
        return nil
    }

    private static func strongestRise(
        _ envelope: [Float],
        bucketSeconds: TimeInterval,
        from lower: Int,
        to upper: Int,
        window: Int,
        minimumRatio: Double
    ) -> (bucket: Int, ratio: Double)? {
        let start = max(window, lower)
        let end = min(envelope.count - window, upper)
        guard end > start else { return nil }
        var best: (bucket: Int, ratio: Double)?
        for i in start..<end {
            let before = mean(envelope, from: i - window, to: i)
            let after = mean(envelope, from: i, to: i + window)
            let ratio = after / max(0.06, before)
            guard ratio >= minimumRatio else { continue }
            if best == nil || ratio > best!.ratio { best = (i, ratio) }
        }
        return best
    }

    private static func localMaxima(
        _ candidates: [(bucket: Int, ratio: Double)],
        minimumSeparation: Int
    ) -> [(bucket: Int, ratio: Double)] {
        var kept: [(bucket: Int, ratio: Double)] = []
        for candidate in candidates.sorted(by: { $0.ratio > $1.ratio }) {
            if kept.contains(where: { abs($0.bucket - candidate.bucket) < minimumSeparation }) { continue }
            kept.append(candidate)
        }
        return kept.sorted { $0.bucket < $1.bucket }
    }
}
