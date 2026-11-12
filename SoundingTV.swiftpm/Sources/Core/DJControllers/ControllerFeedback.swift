import Foundation

struct DeckFeedbackState: Hashable, Sendable {
    var isLoaded = false
    var isPlaying = false
    var isCueing = false
    var isSynced = false
    var isLooping = false
    var isLocked = false
    var hotCues: Set<Int> = []
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var level: Double = 0
    var beatPhase: Double?

    var remaining: TimeInterval { max(0, duration - position) }
    var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

enum ControllerFeedbackSignal: Hashable, Sendable {
    case play
    case cue
    case sync
    case loop
    case hotCue(Int)
    case loaded
    case trackEnding
    case beat
    case progress
    case jogRing
    case level

    var isContinuous: Bool {
        switch self {
        case .progress, .jogRing, .level: return true
        case .play, .cue, .sync, .loop, .hotCue, .loaded, .trackEnding, .beat: return false
        }
    }
}

struct ControllerFeedbackMapping: Hashable, Sendable {
    struct Output: Hashable, Sendable {
        var midi: ControllerMapping.MessageType
        var channel: UInt8
        var number: UInt8
        var deck: MixEngine.Deck
        var signal: ControllerFeedbackSignal
        var onValue: UInt8 = 0x7F
        var offValue: UInt8 = 0x00

        static func led(_ channel: UInt8, _ number: UInt8, _ deck: MixEngine.Deck, _ signal: ControllerFeedbackSignal) -> Output {
            Output(midi: .note, channel: channel, number: number, deck: deck, signal: signal)
        }

        static func meter(_ channel: UInt8, _ number: UInt8, _ deck: MixEngine.Deck, _ signal: ControllerFeedbackSignal, top: UInt8 = 0x7F) -> Output {
            Output(midi: .cc, channel: channel, number: number, deck: deck, signal: signal, onValue: top, offValue: 0)
        }

        var key: ControllerFeedbackKey {
            ControllerFeedbackKey(midi: midi, channel: channel, number: number)
        }
    }

    var outputs: [Output]

    static let none = ControllerFeedbackMapping(outputs: [])

    var isEmpty: Bool { outputs.isEmpty }

    var problems: [String] {
        var found: [String] = []
        var seen: Set<ControllerFeedbackKey> = []
        for (position, output) in outputs.enumerated() {
            let label = "output \(position + 1)"
            if output.channel > 15 { found.append("\(label): channel") }
            if output.number > 127 || output.onValue > 127 || output.offValue > 127 { found.append("\(label): number") }
            if output.midi == .pitchBend { found.append("\(label): pitch bend can't drive a light") }
            if case .hotCue(let index) = output.signal, !(0..<DeckControl.hotCueCount).contains(index) {
                found.append("\(label): hot cue")
            }
            if !seen.insert(output.key).inserted { found.append("\(label): duplicate") }
        }
        return found
    }
}

struct ControllerFeedbackKey: Hashable, Sendable {
    var midi: ControllerMapping.MessageType
    var channel: UInt8
    var number: UInt8
}

struct ControllerFeedbackValue: Hashable, Sendable {
    var message: ControllerMIDIMessage
    var isContinuous: Bool
}

enum ControllerFeedbackRenderer {
    static let trackEndingSeconds: TimeInterval = 30
    static let pauseBlinkPeriod: TimeInterval = 1
    static let warningBlinkPeriod: TimeInterval = 0.5
    static let beatFlash = 0.15
    static let platterSecondsPerTurn: TimeInterval = 60 / (100.0 / 3)
    static let meterFloorDecibels = -48.0

    static func render(
        _ mapping: ControllerFeedbackMapping,
        states: [MixEngine.Deck: DeckFeedbackState],
        clock: TimeInterval
    ) -> [ControllerFeedbackKey: ControllerFeedbackValue] {
        var result: [ControllerFeedbackKey: ControllerFeedbackValue] = [:]
        for output in mapping.outputs {
            let state = states[output.deck] ?? DeckFeedbackState()
            let raw = value(of: output, state: state, clock: clock)
            let message: ControllerMIDIMessage
            switch output.midi {
            case .note: message = ControllerMIDIMessage(kind: .noteOn, channel: output.channel, number: output.number, value: UInt16(raw))
            case .cc, .pitchBend: message = ControllerMIDIMessage(kind: .controlChange, channel: output.channel, number: output.number, value: UInt16(raw))
            }
            result[output.key] = ControllerFeedbackValue(message: message, isContinuous: output.signal.isContinuous)
        }
        return result
    }

    static func value(of output: ControllerFeedbackMapping.Output, state: DeckFeedbackState, clock: TimeInterval) -> UInt8 {
        guard !state.isLocked else { return output.offValue }
        if output.signal.isContinuous {
            let fraction = continuous(output.signal, state: state)
            let span = Double(Int(output.onValue) - Int(output.offValue))
            let scaled = Double(output.offValue) + (span * fraction).rounded()
            return UInt8(min(127, max(0, scaled)))
        }
        return lit(output.signal, state: state, clock: clock) ? output.onValue : output.offValue
    }

    static func lit(_ signal: ControllerFeedbackSignal, state: DeckFeedbackState, clock: TimeInterval) -> Bool {
        switch signal {
        case .play:
            if state.isPlaying { return true }
            return state.isLoaded && blink(clock, period: pauseBlinkPeriod)
        case .cue:
            return state.isCueing || (state.isLoaded && !state.isPlaying)
        case .sync:
            return state.isLoaded && state.isSynced
        case .loop:
            return state.isLoaded && state.isLooping
        case .hotCue(let index):
            return state.isLoaded && state.hotCues.contains(index)
        case .loaded:
            return state.isLoaded
        case .trackEnding:
            guard state.isLoaded, state.isPlaying, state.duration > 0, state.remaining <= trackEndingSeconds else { return false }
            return blink(clock, period: warningBlinkPeriod)
        case .beat:
            guard state.isPlaying, let phase = state.beatPhase else { return false }
            return phase < beatFlash
        case .progress, .jogRing, .level:
            return continuous(signal, state: state) > 0.5
        }
    }

    static func continuous(_ signal: ControllerFeedbackSignal, state: DeckFeedbackState) -> Double {
        guard state.isLoaded else { return 0 }
        switch signal {
        case .progress:
            return state.progress
        case .jogRing:
            let turns = state.position / platterSecondsPerTurn
            return turns - floor(turns)
        case .level:
            return meter(rms: state.level)
        default:
            return lit(signal, state: state, clock: 0) ? 1 : 0
        }
    }

    static func meter(rms: Double) -> Double {
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - meterFloorDecibels) / -meterFloorDecibels))
    }

    static func blink(_ clock: TimeInterval, period: TimeInterval) -> Bool {
        guard period > 0 else { return true }
        let phase = clock / period
        return phase - floor(phase) < 0.5
    }

    static func blackout(_ mapping: ControllerFeedbackMapping) -> [ControllerMIDIMessage] {
        mapping.outputs.map { output in
            switch output.midi {
            case .note: ControllerMIDIMessage(kind: .noteOn, channel: output.channel, number: output.number, value: UInt16(output.offValue))
            case .cc, .pitchBend: ControllerMIDIMessage(kind: .controlChange, channel: output.channel, number: output.number, value: UInt16(output.offValue))
            }
        }
    }
}

struct ControllerFeedbackThrottle: Sendable {
    var continuousInterval: TimeInterval = 1.0 / 15
    var continuousRefresh: TimeInterval = 0.5
    var continuousDeadband: UInt16 = 2
    var maximumPerFlush = 24

    private struct Sent: Sendable {
        var value: UInt16
        var at: TimeInterval
    }

    private var sent: [ControllerFeedbackKey: Sent] = [:]

    init() {}

    mutating func reset() {
        sent = [:]
    }

    mutating func take(_ desired: [ControllerFeedbackKey: ControllerFeedbackValue], now: TimeInterval) -> [ControllerMIDIMessage] {
        var lights: [(ControllerFeedbackKey, ControllerMIDIMessage)] = []
        var meters: [(ControllerFeedbackKey, ControllerMIDIMessage, TimeInterval)] = []

        for (key, wanted) in desired {
            let value = wanted.message.value
            guard let previous = sent[key] else {
                if wanted.isContinuous {
                    meters.append((key, wanted.message, -.infinity))
                } else {
                    lights.append((key, wanted.message))
                }
                continue
            }
            guard previous.value != value else { continue }
            if wanted.isContinuous {
                let age = now - previous.at
                guard age >= continuousInterval else { continue }
                let change = value > previous.value ? value - previous.value : previous.value - value
                let reachesEdge = value == 0 || value == 127
                guard change >= continuousDeadband || reachesEdge || age >= continuousRefresh else { continue }
                meters.append((key, wanted.message, previous.at))
            } else {
                lights.append((key, wanted.message))
            }
        }

        lights.sort { Self.order($0.0, $1.0) }
        meters.sort { $0.2 == $1.2 ? Self.order($0.0, $1.0) : $0.2 < $1.2 }

        var output: [ControllerMIDIMessage] = []
        output.reserveCapacity(min(maximumPerFlush, lights.count + meters.count))
        for (key, message) in lights where output.count < maximumPerFlush {
            output.append(message)
            sent[key] = Sent(value: message.value, at: now)
        }
        for (key, message, _) in meters where output.count < maximumPerFlush {
            output.append(message)
            sent[key] = Sent(value: message.value, at: now)
        }
        return output
    }

    private static func order(_ lhs: ControllerFeedbackKey, _ rhs: ControllerFeedbackKey) -> Bool {
        if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
        if lhs.number != rhs.number { return lhs.number < rhs.number }
        return lhs.midi == .note && rhs.midi != .note
    }
}

enum DeckFeedbackMath {
    static let syncTolerance = 0.001

    static func beatPhase(position: TimeInterval, anchor: TimeInterval, beatPeriod: Double) -> Double? {
        guard beatPeriod > 0, position.isFinite, anchor.isFinite else { return nil }
        let beats = (position - anchor) / beatPeriod
        return beats - floor(beats)
    }

    static func isTempoMatched(beatPeriod: Double, rate: Double, otherBeatPeriod: Double, otherRate: Double) -> Bool {
        guard beatPeriod > 0, otherBeatPeriod > 0, rate > 0, otherRate > 0 else { return false }
        let tempo = rate / beatPeriod
        let other = otherRate / otherBeatPeriod
        let ratio = tempo / other
        let nearest = [0.5, 1, 2].min { abs(ratio - $0) < abs(ratio - $1) } ?? 1
        return abs(ratio / nearest - 1) <= syncTolerance
    }
}

@MainActor
protocol DeckFeedbackSource: AnyObject {
    func feedbackState(for deck: MixEngine.Deck) -> DeckFeedbackState
}

extension DeckControlSurface {
    func basicFeedbackState(for deck: MixEngine.Deck) -> DeckFeedbackState {
        let group = DeckGroup.deck(deck)
        func on(_ control: DeckControl, index: Int = 0) -> Bool {
            (value(of: DeckControlAddress(group: group, control: control, index: index)) ?? 0) > 0.5
        }
        var state = DeckFeedbackState()
        state.isPlaying = on(.play)
        state.isCueing = on(.cue)
        state.isLooping = on(.loopToggle)
        state.hotCues = Set((0..<DeckControl.hotCueCount).filter { on(.hotCue, index: $0) })
        state.isLoaded = state.isPlaying || state.isCueing || state.isLooping || !state.hotCues.isEmpty
        return state
    }

    func currentFeedback(for deck: MixEngine.Deck) -> DeckFeedbackState {
        if let source = self as? any DeckFeedbackSource {
            return source.feedbackState(for: deck)
        }
        return basicFeedbackState(for: deck)
    }
}
