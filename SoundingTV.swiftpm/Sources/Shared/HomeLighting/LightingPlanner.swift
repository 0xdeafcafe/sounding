import Foundation

struct LightingAnalysis: Equatable, Sendable {
    let trackID: String
    let duration: TimeInterval
    let envelope: [Float]
    let phraseStarts: [TimeInterval]
    let bpm: Double?
    let palette: [LightColor]
}

struct LightingPhrase: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case steady
        case drop
        case breakdown
    }

    let start: TimeInterval
    let end: TimeInterval
    let energy: Double
    let relative: Double
    let kind: Kind

    var length: TimeInterval { end - start }
}

struct LightingPlan: Equatable, Sendable {
    let trackID: String
    let phrases: [LightingPhrase]
    let cues: [LightCue]

    static func empty(_ trackID: String) -> LightingPlan {
        LightingPlan(trackID: trackID, phrases: [], cues: [])
    }

    func cue(at time: TimeInterval) -> LightCue? {
        cues.last { $0.time <= time }
    }

    func phrase(at time: TimeInterval) -> LightingPhrase? {
        phrases.first { time >= $0.start && time < $0.end } ?? phrases.last
    }
}

enum LightingPlanner {
    static let minimumPhraseLength: TimeInterval = 6
    static let fallbackPhraseLength: TimeInterval = 16
    static let dropReleaseDelay: TimeInterval = 1.5
    static let breakdownStep: TimeInterval = 2
    static let maximumBreakdownFade: TimeInterval = 12

    static func plan(
        _ analysis: LightingAnalysis,
        intensity: LightingIntensity,
        minimumCueSpacing: TimeInterval = 1
    ) -> LightingPlan {
        guard intensity != .off, analysis.duration > 0 else { return .empty(analysis.trackID) }
        let phrases = phrases(for: analysis)
        let palette = analysis.palette.isEmpty ? [LightColor.warmGlow] : analysis.palette
        let vivid = palette.max { $0.saturation < $1.saturation } ?? palette[0]
        let calm = palette.count > 1 ? palette[palette.count - 1] : palette[0]
        let range = intensity.brightnessRange
        let spacing = max(minimumCueSpacing, 0.25)

        var cues: [LightCue] = []
        var steadyIndex = 0
        var lastPulse: TimeInterval = -.infinity
        var previousBrightness = range.lowerBound

        for phrase in phrases {
            let level = brightness(forEnergy: phrase.energy, intensity: intensity)
            switch phrase.kind {
            case .steady:
                let color = palette[steadyIndex % palette.count]
                steadyIndex += 1
                cues.append(LightCue(time: phrase.start, state: LightState(color: color, brightness: level), kind: .phrase))
                previousBrightness = level

            case .drop:
                let release = LightState(color: vivid, brightness: level)
                if let pulseSpacing = intensity.dropPulseSpacing,
                   phrase.start - lastPulse >= pulseSpacing,
                   phrase.length >= dropReleaseDelay + spacing {
                    let flash = LightState(color: LightColor(hue: vivid.hue, saturation: 1), brightness: range.upperBound)
                    cues.append(LightCue(time: phrase.start, state: flash, kind: .drop))
                    cues.append(LightCue(time: phrase.start + max(dropReleaseDelay, spacing), state: release, kind: .dropRelease))
                    lastPulse = phrase.start
                } else {
                    cues.append(LightCue(time: phrase.start, state: release, kind: .phrase))
                }
                previousBrightness = level

            case .breakdown:
                let target = min(level, range.lowerBound + (range.upperBound - range.lowerBound) * 0.25)
                let color = LightColor(hue: calm.hue, saturation: calm.saturation * 0.75)
                let fade = min(maximumBreakdownFade, phrase.length * 0.6)
                let step = max(breakdownStep, spacing)
                let steps = max(1, Int(fade / step))
                for index in 1...steps {
                    let progress = Double(index) / Double(steps)
                    let eased = 0.5 - 0.5 * cos(.pi * progress)
                    let value = previousBrightness + (target - previousBrightness) * eased
                    let time = phrase.start + Double(index - 1) * step
                    guard time < phrase.end else { break }
                    cues.append(LightCue(time: time, state: LightState(color: color, brightness: value), kind: .breakdown))
                }
                previousBrightness = target
            }
        }

        return LightingPlan(trackID: analysis.trackID, phrases: phrases, cues: enforceSpacing(cues, spacing: spacing))
    }

    static func brightness(forEnergy energy: Double, intensity: LightingIntensity) -> Double {
        let range = intensity.brightnessRange
        let clamped = min(1, max(0, energy.isFinite ? energy : 0))
        return range.lowerBound + (range.upperBound - range.lowerBound) * pow(clamped, 1.2)
    }

    static func resting(from state: LightState, intensity: LightingIntensity) -> LightState {
        let floor = intensity.brightnessRange.lowerBound
        return LightState(color: state.color, brightness: max(floor * 0.6, state.brightness * 0.4))
    }

    static func windDown(from state: LightState, progress: Double) -> LightState {
        let p = min(1, max(0, progress))
        let hueDelta = shortestHueDelta(from: state.color.hue, to: LightColor.warmGlow.hue)
        let color = LightColor(
            hue: state.color.hue + hueDelta * p,
            saturation: state.color.saturation + (LightColor.warmGlow.saturation - state.color.saturation) * p
        )
        let floor = 0.03
        return LightState(color: color, brightness: state.brightness + (floor - state.brightness) * p)
    }

    // MARK: - Phrases

    static func phrases(for analysis: LightingAnalysis) -> [LightingPhrase] {
        let duration = analysis.duration
        let starts = phraseStarts(for: analysis)
        guard !starts.isEmpty else { return [] }

        let bounds: [(TimeInterval, TimeInterval)] = starts.enumerated().map { index, start in
            (start, index + 1 < starts.count ? starts[index + 1] : duration)
        }
        let reference = percentile(analysis.envelope, 0.95)
        let means = bounds.map { meanEnvelope(analysis.envelope, duration: duration, from: $0.0, to: $0.1) }
        let median = percentile(means.map(Float.init), 0.5)

        var phrases: [LightingPhrase] = []
        for (index, bound) in bounds.enumerated() {
            let mean = means[index]
            let energy = reference > 0 ? min(1, mean / Double(reference)) : 0
            let relative = median > 0 ? mean / Double(median) : 1
            let kind: LightingPhrase.Kind
            if let previous = phrases.last,
               relative >= 1.15,
               previous.kind == .breakdown || previous.relative <= relative - 0.18 {
                kind = .drop
            } else if relative <= 0.7 {
                kind = .breakdown
            } else {
                kind = .steady
            }
            phrases.append(LightingPhrase(start: bound.0, end: bound.1, energy: energy, relative: relative, kind: kind))
        }
        return phrases
    }

    static func phraseStarts(for analysis: LightingAnalysis) -> [TimeInterval] {
        let duration = analysis.duration
        guard duration > 0 else { return [] }

        let measured = analysis.phraseStarts
            .filter { $0.isFinite && $0 > 0 && $0 < duration }
            .sorted()
        if measured.count >= 2 {
            return merge([0] + measured, duration: duration)
        }

        var length = fallbackPhraseLength
        if let bpm = analysis.bpm, bpm.isFinite, (60...200).contains(bpm) {
            length = 32 * 60 / bpm
            if length < 10 { length *= 2 }
        }
        var starts: [TimeInterval] = [0]
        var cursor = length
        while cursor < duration - minimumPhraseLength {
            let snapped = snapToRise(cursor, window: length * 0.25, envelope: analysis.envelope, duration: duration)
            if snapped - (starts.last ?? 0) >= minimumPhraseLength { starts.append(snapped) }
            cursor = snapped + length
        }
        return starts
    }

    private static func merge(_ starts: [TimeInterval], duration: TimeInterval) -> [TimeInterval] {
        var out: [TimeInterval] = []
        for start in starts {
            if let last = out.last, start - last < minimumPhraseLength { continue }
            out.append(start)
        }
        if out.count > 1, let last = out.last, duration - last < minimumPhraseLength {
            out.removeLast()
        }
        return out
    }

    private static func snapToRise(
        _ time: TimeInterval,
        window: TimeInterval,
        envelope: [Float],
        duration: TimeInterval
    ) -> TimeInterval {
        guard envelope.count >= 8, duration > 0 else { return time }
        let probe: TimeInterval = 2
        var best = time
        var bestRise = 0.15
        var candidate = max(probe, time - window)
        let step = max(0.5, duration / Double(envelope.count))
        while candidate <= min(duration - probe, time + window) {
            let before = meanEnvelope(envelope, duration: duration, from: candidate - probe, to: candidate)
            let after = meanEnvelope(envelope, duration: duration, from: candidate, to: candidate + probe)
            if after - before > bestRise {
                bestRise = after - before
                best = candidate
            }
            candidate += step
        }
        return best
    }

    static func meanEnvelope(_ envelope: [Float], duration: TimeInterval, from: TimeInterval, to: TimeInterval) -> Double {
        guard !envelope.isEmpty, duration > 0, to > from else { return 0 }
        let n = envelope.count
        let lower = max(0, min(n - 1, Int(from / duration * Double(n))))
        let upper = max(lower + 1, min(n, Int((to / duration * Double(n)).rounded(.up))))
        var sum: Float = 0
        for index in lower..<upper { sum += envelope[index] }
        return Double(sum) / Double(upper - lower)
    }

    static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    private static func enforceSpacing(_ cues: [LightCue], spacing: TimeInterval) -> [LightCue] {
        var out: [LightCue] = []
        for cue in cues.sorted(by: { $0.time < $1.time }) {
            if let last = out.last, cue.time - last.time < spacing {
                if cue.kind == .phrase || cue.kind == .drop || last.kind == .breakdown {
                    out[out.count - 1] = cue
                }
                continue
            }
            out.append(cue)
        }
        return out
    }

    private static func shortestHueDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

struct LightingCueCursor: Equatable, Sendable {
    static let seekTolerance: TimeInterval = 3

    let plan: LightingPlan
    var lead: TimeInterval
    private(set) var nextIndex = 0
    private(set) var lastPosition: TimeInterval?

    init(plan: LightingPlan, lead: TimeInterval) {
        self.plan = plan
        self.lead = lead
    }

    mutating func advance(to position: TimeInterval) -> LightCue? {
        defer { lastPosition = position }
        let effective = position + lead
        let jumped: Bool = {
            guard let lastPosition else { return true }
            return position < lastPosition - 0.5 || position > lastPosition + Self.seekTolerance
        }()
        if jumped {
            nextIndex = plan.cues.firstIndex { $0.time > effective } ?? plan.cues.count
            return nextIndex > 0 ? plan.cues[nextIndex - 1] : nil
        }
        var due: LightCue?
        while nextIndex < plan.cues.count, plan.cues[nextIndex].time <= effective {
            due = plan.cues[nextIndex]
            nextIndex += 1
        }
        return due
    }

    func upcoming(after position: TimeInterval, within window: TimeInterval) -> [LightCue] {
        plan.cues.filter { $0.time > position + lead && $0.time <= position + lead + window }
    }

    func lookaheadWindow(at position: TimeInterval) -> TimeInterval {
        guard let phrase = plan.phrase(at: position) else { return LightingPlanner.fallbackPhraseLength }
        return max(LightingPlanner.minimumPhraseLength, phrase.length)
    }
}
