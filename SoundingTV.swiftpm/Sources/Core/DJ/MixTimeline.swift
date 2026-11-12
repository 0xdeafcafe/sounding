import Foundation

struct MixParameter: Hashable, Sendable {
    let raw: Int

    static let perDeckCount = 20
    static let globalBase = 2 * perDeckCount

    static func gain(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 0) }
    static func inputGain(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 1) }
    static func eqLow(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 2) }
    static func eqMid(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 3) }
    static func eqHigh(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 4) }
    static func lowPass(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 5) }
    static func highPass(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 6) }
    static func resonance(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 7) }
    static func echoSend(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 8) }
    static func reverbSend(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 9) }
    static func auxSend(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 10) }
    static func rate(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 11) }
    static func pitch(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 12) }
    static func holdTail(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 13) }
    static func insertMix(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 14) }
    static func fxWet(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 15) }
    static func fxSend(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 16) }
    static func cue(_ deck: Int) -> MixParameter { .init(raw: deck * perDeckCount + 17) }

    static let crossfade = MixParameter(raw: globalBase + 0)
    static let master = MixParameter(raw: globalBase + 1)
    static let echoFeedback = MixParameter(raw: globalBase + 2)
    static let echoReturn = MixParameter(raw: globalBase + 3)
    static let reverbReturn = MixParameter(raw: globalBase + 4)
    static let auxReturn = MixParameter(raw: globalBase + 5)
    static let auxMix = MixParameter(raw: globalBase + 6)
    static let crossfadeCurve = MixParameter(raw: globalBase + 7)
    static let riserLevel = MixParameter(raw: globalBase + 8)
    static let riserSweep = MixParameter(raw: globalBase + 9)
    static let cueMix = MixParameter(raw: globalBase + 10)
    static let phonesLevel = MixParameter(raw: globalBase + 11)
    static let splitCue = MixParameter(raw: globalBase + 12)
    static let crossfaderShape = MixParameter(raw: globalBase + 13)

    static let count = globalBase + 14

    var deck: Int? { raw < Self.globalBase ? raw / Self.perDeckCount : nil }
    var slot: Int { raw < Self.globalBase ? raw % Self.perDeckCount : raw - Self.globalBase }

    var defaultValue: Double {
        guard deck != nil else {
            switch self {
            case .master, .echoReturn, .reverbReturn, .auxReturn, .auxMix: return 1
            case .echoFeedback: return 0.45
            case .phonesLevel: return 0.5
            default: return 0
            }
        }
        switch slot {
        case 0, 11, 14: return 1
        case 5: return MixEngine.filterCutoffRange.upperBound
        case 6: return MixEngine.filterCutoffRange.lowerBound
        default: return 0
        }
    }

    var minimumRampFrames: Int64 {
        guard let _ = deck else {
            switch self {
            case .crossfade, .master, .echoReturn, .reverbReturn, .auxReturn, .auxMix, .riserLevel: return 64
            case .cueMix, .phonesLevel: return 256
            default: return 0
            }
        }
        switch slot {
        case 0, 1, 2, 3, 4, 8, 9, 10: return 64
        case 13: return 32
        case 14, 15, 17: return 256
        case 16: return 512
        default: return 0
        }
    }

    var restoresToNeutral: Bool {
        guard deck != nil else { return self == .echoFeedback || self == .riserLevel || self == .riserSweep }
        switch slot {
        case 2, 3, 4, 5, 6, 7, 8, 9, 10, 13: return true
        default: return false
        }
    }

    var isUserOwned: Bool {
        guard deck != nil else {
            switch self {
            case .cueMix, .phonesLevel, .splitCue, .crossfaderShape: return true
            default: return false
            }
        }
        return slot == 15 || slot == 16 || slot == 17
    }
}

enum MixCurve: UInt8, Sendable {
    case linear
    case smooth
    case logarithmic
    case power

    @inline(__always)
    func interpolate(from: Double, to: Double, t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .linear:
            return from + (to - from) * x
        case .smooth:
            return from + (to - from) * (1 - cos(x * .pi)) / 2
        case .power:
            let p = (1 - x) * pow(10, from / 10) + x * pow(10, to / 10)
            return max(min(from, to), 10 * log10(max(1e-12, p)))
        case .logarithmic:
            let lo = max(1e-3, from)
            let hi = max(1e-3, to)
            return exp(log(lo) + (log(hi) - log(lo)) * x)
        }
    }
}

enum MixTimelineAction: Sendable, Equatable {
    case ramp(MixParameter, to: Double, frames: Int64, curve: MixCurve)
    case start(deck: Int, fromFrame: Double?)
    case stop(deck: Int)
    case seek(deck: Int, frame: Double)
    case seekLinked(lead: Int, frame: Double, follower: Int, movesClock: Bool)
    case loop(deck: Int, startFrame: Double, lengthFrames: Double)
    case clearLoop(deck: Int)
    case echoTime(seconds: Double)
    case phaseLock(deck: Int, reference: Int)
    case phaseUnlock(deck: Int)
    case clearFX
    case deckFX(deck: Int, kind: Int, periodSeconds: Double, feedback: Double)
    case holdParameters
    case resetParameters
}

enum MixTimelineAnchor: Sendable, Equatable {
    case now
    case clock(Int64)
    case deckPosition(deck: Int, frame: Double)
}

struct MixTimeline: Sendable, Equatable {
    struct Event: Sendable, Equatable {
        var offset: Int64
        var action: MixTimelineAction
    }

    var anchor: MixTimelineAnchor
    var events: [Event]
    var lengthFrames: Int64

    init(anchor: MixTimelineAnchor, events: [Event] = [], lengthFrames: Int64 = 0) {
        self.anchor = anchor
        self.events = events
        self.lengthFrames = lengthFrames
    }

    mutating func add(_ seconds: TimeInterval, _ action: MixTimelineAction, sampleRate: Double) {
        events.append(Event(offset: Int64((max(0, seconds) * sampleRate).rounded()), action: action))
    }
}

struct MixTransitionTimelineInput: Sendable {
    var outgoing: Int
    var incoming: Int
    var sampleRate: Double
    var anchorSourceSeconds: TimeInterval
    var window: TimeInterval
    var entrySeconds: TimeInterval
    var outgoingRate: Double
    var incomingRate: Double
    var outgoingGrid: BeatGrid?
    var incomingGrid: BeatGrid?
    var stages: [TransitionStage]
    var bassSwapAtSeconds: TimeInterval?
    var bassSwapSeconds: TimeInterval?
    var filterAccent: PhantomDJEngine.Accent?
    var defersIncomingStart: Bool
    var phaseLock: Bool
    var move: MixMove? = nil
    var riserGain: Double = 0
    var incomingMidCutDecibels: Double = 0
    var level: TransitionLevel? = nil
}

extension MixTimeline {
    static let echoDryCutSeconds: TimeInterval = 0.005
    static let filterLowReturnBeats = 4.0

    static func transition(_ input: MixTransitionTimelineInput) -> MixTimeline {
        if let move = input.move { return Self.move(move, input) }
        let sr = input.sampleRate
        let outgoing = input.outgoing
        let incoming = input.incoming
        let window = max(0.15, input.window)
        var timeline = MixTimeline(
            anchor: .deckPosition(deck: outgoing, frame: input.anchorSourceSeconds * sr),
            lengthFrames: Int64((window * sr).rounded())
        )
        var incomingStarted = !input.defersIncomingStart
        var incomingStartSeconds: TimeInterval = 0
        if incomingStarted {
            timeline.add(0, .start(deck: incoming, fromFrame: input.entrySeconds * sr), sampleRate: sr)
            if input.phaseLock {
                timeline.add(0, .phaseLock(deck: incoming, reference: outgoing), sampleRate: sr)
            }
        }

        func startIncomingIfNeeded(at seconds: TimeInterval) {
            guard !incomingStarted else { return }
            incomingStarted = true
            incomingStartSeconds = seconds
            timeline.add(seconds, .start(deck: incoming, fromFrame: input.entrySeconds * sr), sampleRate: sr)
            if input.phaseLock {
                timeline.add(seconds, .phaseLock(deck: incoming, reference: outgoing), sampleRate: sr)
            }
        }

        func frames(_ seconds: TimeInterval) -> Int64 { Int64((max(0, seconds) * sr).rounded()) }

        let level = input.level ?? .typical
        if let gain = level.incomingGain {
            timeline.add(0, .ramp(.gain(incoming), to: gain, frames: 0, curve: .linear), sampleRate: sr)
        }
        if let gain = level.outgoingGain, input.stages.isEmpty {
            timeline.add(0, .ramp(.gain(outgoing), to: gain, frames: frames(min(window * 0.25, 8)), curve: .linear), sampleRate: sr)
        }
        if input.stages.isEmpty {
            let swapAt = input.bassSwapAtSeconds ?? window * 0.55
            let cut = input.incomingMidCutDecibels
            let shape: Double?
            if level.legacyFaderLaw {
                shape = input.phaseLock ? 1 : nil
            } else {
                let fraction = swapAt / window
                let filter: MixFilterShape = input.filterAccent == .incomingFilterOpen ? .lowPass : .plain
                shape = TransitionFaderLaw.curveShape(
                    outgoing: level.outgoing,
                    incoming: level.incoming,
                    range: input.phaseLock ? 0...1 : 0...MixMoveBuilder.unlockedCurveCeiling
                ) { x in
                    var gains = filter.bands(x: x, swap: fraction, midHandover: false, incomingMidCut: cut)
                    return gains
                }
            }
            if let shape {
                timeline.add(0, .ramp(.crossfadeCurve, to: shape, frames: 0, curve: .linear), sampleRate: sr)
                timeline.add(window, .ramp(.crossfadeCurve, to: 0, frames: 0, curve: .linear), sampleRate: sr)
            }
            timeline.add(0, .ramp(.crossfade, to: incoming == 1 ? 1 : 0, frames: frames(window), curve: .linear), sampleRate: sr)
            let halfBeat = (input.outgoingGrid?.beatPeriod ?? 0.5) / max(0.01, input.outgoingRate) / 2
            let swapOver = min(input.bassSwapSeconds ?? min(0.5, window * 0.2), halfBeat)
            let at = min(max(0, swapAt), max(0, window - swapOver))
            timeline.add(at, .ramp(.eqLow(outgoing), to: MixEngine.bassKillDecibels, frames: frames(swapOver), curve: .power), sampleRate: sr)
            let lowReturn = input.filterAccent == nil ? swapOver : max(swapOver, Self.filterLowReturnBeats * halfBeat * 2)
            let lowFrom = max(0, min(lowReturn > swapOver ? at - halfBeat : at, window - lowReturn))
            timeline.add(lowFrom, .ramp(.eqLow(incoming), to: 0, frames: frames(lowReturn), curve: .power), sampleRate: sr)
            switch input.filterAccent {
            case .outgoingFilterClose:
                let sweepFrom = input.phaseLock ? window * 0.5 : 0
                timeline.add(sweepFrom, .ramp(.lowPass(outgoing), to: DJEngineConstants.accentClosedFilterHz, frames: frames(window - sweepFrom), curve: .logarithmic), sampleRate: sr)
            case .incomingFilterOpen:
                timeline.add(0, .ramp(.lowPass(incoming), to: MixEngine.filterCutoffRange.upperBound, frames: frames(window), curve: .logarithmic), sampleRate: sr)
            case nil:
                break
            }
        } else {
            let clock = OutgoingClock(input: input)
            for stage in input.stages.sorted(by: { $0.atSeconds < $1.atSeconds }) {
                let source = MixTransitionPerformer.quantizedSourceSeconds(
                    nominal: input.anchorSourceSeconds + stage.atSeconds,
                    snap: stage.snap,
                    grid: input.outgoingGrid
                )
                let at = clock.wallSeconds(toReach: source)
                let deck = stage.deck == .outgoing ? outgoing : incoming
                switch stage.action {
                case .loop(let bars):
                    let grid = stage.deck == .outgoing ? input.outgoingGrid : input.incomingGrid
                    guard let grid, grid.beatPeriod > 0 else { break }
                    let position: TimeInterval
                    if stage.deck == .outgoing {
                        position = source
                    } else {
                        position = input.entrySeconds + max(0, at - incomingStartSeconds) * input.incomingRate
                    }
                    let start = Self.loopStart(near: position, grid: grid)
                    let length = max(1, bars * 4) * grid.localBeatPeriod(at: start)
                    timeline.add(at, .loop(deck: deck, startFrame: start * sr, lengthFrames: length * sr), sampleRate: sr)
                case .clearLoop:
                    timeline.add(at, .clearLoop(deck: deck), sampleRate: sr)
                case .lowPassTo(let hertz, let duration):
                    timeline.add(at, .ramp(.lowPass(deck), to: hertz, frames: frames(duration), curve: .logarithmic), sampleRate: sr)
                case .highPassTo(let hertz, let duration):
                    timeline.add(at, .ramp(.highPass(deck), to: hertz, frames: frames(duration), curve: .logarithmic), sampleRate: sr)
                case .eqLow(let decibels, let duration):
                    timeline.add(at, .ramp(.eqLow(deck), to: decibels, frames: frames(duration), curve: .linear), sampleRate: sr)
                case .delayWet(let mix, let feedback, let duration):
                    let grid = stage.deck == .outgoing ? input.outgoingGrid : input.incomingGrid
                    let rate = stage.deck == .outgoing ? input.outgoingRate : input.incomingRate
                    if let beat = grid?.beatPeriod, beat > 0 {
                        timeline.add(at, .echoTime(seconds: beat / max(0.01, rate)), sampleRate: sr)
                    }
                    timeline.add(at, .ramp(.echoFeedback, to: min(0.85, max(0, feedback)), frames: 0, curve: .linear), sampleRate: sr)
                    timeline.add(at, .ramp(.echoSend(deck), to: mix, frames: frames(duration), curve: .linear), sampleRate: sr)
                case .crossfadeTo(let position, let duration):
                    if stage.deck == .incoming { startIncomingIfNeeded(at: at) }
                    let physical = incoming == 1 ? position : 1 - position
                    timeline.add(at, .ramp(.crossfade, to: physical, frames: frames(duration), curve: .linear), sampleRate: sr)
                case .rateRatio(let ratio, let duration):
                    timeline.add(at, .ramp(.rate(deck), to: ratio, frames: frames(duration), curve: .linear), sampleRate: sr)
                case .hardCut(let fade):
                    startIncomingIfNeeded(at: at)
                    timeline.add(at, .ramp(.crossfade, to: incoming == 1 ? 1 : 0, frames: frames(fade), curve: .linear), sampleRate: sr)
                case .echoCut(let feedback, let release):
                    let grid = stage.deck == .outgoing ? input.outgoingGrid : input.incomingGrid
                    let rate = stage.deck == .outgoing ? input.outgoingRate : input.incomingRate
                    if let beat = grid?.beatPeriod, beat > 0 {
                        timeline.add(at, .echoTime(seconds: beat / max(0.01, rate)), sampleRate: sr)
                    }
                    let level = min(0.85, max(0, feedback))
                    timeline.add(at, .ramp(.echoFeedback, to: level, frames: 0, curve: .linear), sampleRate: sr)
                    timeline.add(at, .ramp(.echoSend(deck), to: 1, frames: 0, curve: .linear), sampleRate: sr)
                    timeline.add(at, .ramp(.gain(deck), to: 0, frames: frames(echoDryCutSeconds), curve: .linear), sampleRate: sr)
                    let ring = max(0.25, release)
                    timeline.add(at + echoDryCutSeconds + ring * 2, .ramp(.echoFeedback, to: 0, frames: frames(ring * 2), curve: .linear), sampleRate: sr)
                }
            }
            startIncomingIfNeeded(at: 0)
        }

        if input.phaseLock {
            timeline.add(window, .phaseUnlock(deck: incoming), sampleRate: sr)
        }
        timeline.add(window, .ramp(.crossfade, to: incoming == 1 ? 1 : 0, frames: 0, curve: .linear), sampleRate: sr)
        timeline.add(window, .stop(deck: outgoing), sampleRate: sr)
        if input.incomingMidCutDecibels < 0, input.stages.isEmpty {
            timeline.add(incomingStartSeconds, .ramp(.eqMid(incoming), to: input.incomingMidCutDecibels, frames: 0, curve: .linear), sampleRate: sr)
            let restore = window * midRestoreFraction
            timeline.add(window - restore, .ramp(.eqMid(incoming), to: 0, frames: frames(restore), curve: .linear), sampleRate: sr)
        }
        timeline.events.sort { $0.offset < $1.offset }
        return timeline
    }

    static let midRestoreFraction: Double = 0.25

    static func loopStart(near position: TimeInterval, grid: BeatGrid) -> TimeInterval {
        if let beats = grid.beats, !beats.isEmpty {
            let floor = beats.last { $0 <= position + 0.002 } ?? beats[0]
            return max(0, floor)
        }
        guard grid.beatPeriod > 0 else { return max(0, position) }
        let steps = ((position - grid.anchor) / grid.beatPeriod + 0.002).rounded(.down)
        return max(0, grid.anchor + steps * grid.beatPeriod)
    }

    private struct OutgoingClock {
        struct Segment {
            let start: TimeInterval
            let from: Double
            let to: Double
            let duration: TimeInterval
        }

        let anchor: TimeInterval
        let baseRate: Double
        let segments: [Segment]

        init(input: MixTransitionTimelineInput) {
            anchor = input.anchorSourceSeconds
            baseRate = max(0.01, input.outgoingRate)
            var segments: [Segment] = []
            var rate = baseRate
            var wall: TimeInterval = 0
            var source = input.anchorSourceSeconds
            for stage in input.stages.sorted(by: { $0.atSeconds < $1.atSeconds }) where stage.deck == .outgoing {
                guard case .rateRatio(let target, let duration) = stage.action else { continue }
                let nominal = input.anchorSourceSeconds + stage.atSeconds
                let at = MixTransitionPerformer.quantizedSourceSeconds(nominal: nominal, snap: stage.snap, grid: input.outgoingGrid)
                wall += max(0, at - source) / rate
                source = max(source, at)
                segments.append(Segment(start: wall, from: rate, to: target, duration: max(0, duration)))
                source += (rate + target) / 2 * max(0, duration)
                wall += max(0, duration)
                rate = max(0.01, target)
            }
            self.segments = segments
        }

        func wallSeconds(toReach target: TimeInterval) -> TimeInterval {
            guard target > anchor else { return 0 }
            guard !segments.isEmpty else { return (target - anchor) / baseRate }
            var wall: TimeInterval = 0
            var source = anchor
            var rate = baseRate
            let step = 0.001
            var index = 0
            while source < target, wall < 3_600 {
                if index < segments.count, wall >= segments[index].start {
                    let segment = segments[index]
                    let t = segment.duration > 0 ? min(1, (wall - segment.start) / segment.duration) : 1
                    rate = max(0.01, segment.from + (segment.to - segment.from) * t)
                    if t >= 1 { index += 1 }
                } else if index < segments.count {
                    let gap = segments[index].start - wall
                    let reach = source + gap * rate
                    if reach < target {
                        wall += gap
                        source = reach
                        continue
                    }
                    return wall + (target - source) / rate
                } else {
                    return wall + (target - source) / rate
                }
                source += rate * step
                wall += step
            }
            return wall
        }
    }
}
