import Foundation

struct AutoMixLiveState: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case upcoming
        case mixing
        case finished
    }

    struct Phase: Codable, Equatable, Sendable, Identifiable {
        var name: String
        var startBar: Double
        var bars: Double

        var endBar: Double { startBar + bars }
        var id: String { "\(name)@\(startBar)" }
    }

    struct Deck: Codable, Equatable, Sendable {
        var trackId: String?
        var title: String
        var positionSeconds: Double
        var durationSeconds: Double
        var rate: Double
        var isPlaying: Bool
        var beatSeconds: Double?
        var downbeatSeconds: Double?
        var lowDb: Double = 0
        var midDb: Double = 0
        var highDb: Double = 0
        var lowPassHz: Double = 20_000
        var highPassHz: Double = 30
        var gain: Double = 1
        var loopStartSeconds: Double?
        var loopLengthSeconds: Double?

        func position(after elapsed: TimeInterval) -> Double {
            guard isPlaying, elapsed > 0 else { return positionSeconds }
            var position = positionSeconds + elapsed * rate
            if let start = loopStartSeconds, let length = loopLengthSeconds, length > 0.01,
               positionSeconds >= start - 0.05, position > start + length {
                position = start + (position - start).truncatingRemainder(dividingBy: length)
            }
            return durationSeconds > 0 ? min(position, durationSeconds) : position
        }

        var filterLabel: String? {
            if highPassHz > 60 { return "HPF \(Self.hertz(highPassHz))" }
            if lowPassHz < 16_000 { return "LPF \(Self.hertz(lowPassHz))" }
            return nil
        }

        var filterAmount: Double {
            if highPassHz > 60 { return min(1, log(highPassHz / 30) / log(20_000.0 / 30)) }
            if lowPassHz < 16_000 { return -min(1, log(20_000 / max(lowPassHz, 30)) / log(20_000.0 / 30)) }
            return 0
        }

        static func eqLevel(_ db: Double) -> Double {
            guard db.isFinite else { return 0 }
            return max(0, min(1, (db + 26) / 32))
        }

        static func hertz(_ value: Double) -> String {
            value >= 1_000 ? String(format: "%.1f kHz", value / 1_000) : "\(Int(value.rounded())) Hz"
        }
    }

    struct Rating: Codable, Equatable, Sendable {
        var score: Double
        var label: String
    }

    struct MoveCue: Codable, Equatable, Sendable {
        var title: String
        var startsAt: Date?
        var symbolName: String?
    }

    enum PhaseRole: String, Sendable {
        case loop
        case build
        case fadeIn
        case release
        case fadeOut
    }

    struct Section: Equatable, Sendable, Identifiable {
        var role: PhaseRole
        var label: String
        var startBar: Double
        var endBar: Double

        var id: String { "\(role.rawValue)@\(startBar)" }
    }

    struct Clock: Equatable, Sendable {
        var secondsUntilStart: TimeInterval
        var barsUntilStart: Int
        var beatsUntilStart: Int
        var barInMove: Double
        var phase: Phase?
        var progress: Double
        var isRiser: Bool

        var countdownText: String {
            if secondsUntilStart <= 0 { return "now" }
            if barsUntilStart >= 2 { return "in \(barsUntilStart) bars" }
            return beatsUntilStart == 1 ? "in 1 beat" : "in \(beatsUntilStart) beats"
        }
    }

    var stage: Stage
    var moveKind: String
    var moveName: String
    var headline: String
    var incomingTitle: String
    var incomingArtist: String?
    var incomingTrackId: String?
    var why: String?
    var startsAt: Date
    var barSeconds: Double
    var beatsPerBar: Int = 4
    var landingBar: Int
    var lengthBars: Int
    var phases: [Phase]
    var riserStartBar: Double?
    var crossfade: Double
    var outgoing: Deck?
    var incoming: Deck?
    var anchoredAt: Date
    var isPlaying: Bool
    var recap: String?
    var canMixNow: Bool = false
    var canExtend: Bool = false
    var outgoingTitle: String?
    var rating: Rating?
    var moveCue: MoveCue?
    var yourMove: Bool?

    var beatSeconds: Double { barSeconds / Double(max(1, beatsPerBar)) }

    func clock(at date: Date) -> Clock {
        let reference = isPlaying ? date : anchoredAt
        let until = startsAt.timeIntervalSince(reference)
        let beat = max(0.05, beatSeconds)
        let beatsLeft = max(0, Int(ceil(until / beat - 0.001)))
        let barsLeft = Int(ceil(Double(beatsLeft) / Double(max(1, beatsPerBar))))
        let barInMove = max(0, -until / max(0.1, barSeconds))
        let total = Double(max(1, lengthBars))
        let active = stage == .upcoming ? nil : phases.last { barInMove >= $0.startBar - 0.0001 } ?? phases.first
        let riser = riserStartBar.map { barInMove >= $0 && barInMove < Double(landingBar) } ?? false
        return Clock(
            secondsUntilStart: until,
            barsUntilStart: barsLeft,
            beatsUntilStart: beatsLeft,
            barInMove: min(barInMove, total),
            phase: active,
            progress: stage == .finished ? 1 : min(1, barInMove / total),
            isRiser: riser && stage == .mixing
        )
    }

    func barsFromStart(at date: Date) -> Double {
        let reference = isPlaying ? date : anchoredAt
        return -startsAt.timeIntervalSince(reference) / max(0.1, barSeconds)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0.5 else { return "now" }
        let total = Int(seconds.rounded(.up))
        return String(format: "in %d:%02d", total / 60, total % 60)
    }

    func role(of phase: Phase) -> PhaseRole {
        let name = phase.name
        if name.hasPrefix("Loop") { return .loop }
        switch name {
        case "Bass swap", "Drop", "Cut": return .release
        case "Blend in", "Jump in": return .fadeIn
        case "Build": return moveKind == "dropIn" ? .fadeIn : .build
        case "Tempo ramp": return .build
        case "Blend out", "Filter out", "Tail": return .fadeOut
        case "Echo throw": return phase.startBar < Double(landingBar) && moveKind != "echoOut" ? .build : .fadeOut
        default: return phase.startBar < Double(max(1, landingBar)) ? .build : .fadeOut
        }
    }

    var sections: [Section] {
        var out: [Section] = []
        for phase in phases {
            let kind = role(of: phase)
            let title = label(for: kind, phase: phase)
            if var last = out.last, last.role == kind, last.label == title {
                last.endBar = phase.endBar
                out[out.count - 1] = last
            } else {
                out.append(Section(role: kind, label: title, startBar: phase.startBar, endBar: phase.endBar))
            }
        }
        return out
    }

    var releaseBar: Double? {
        let all = sections
        if let release = all.first(where: { $0.role == .release }) { return release.startBar }
        guard let loop = all.last(where: { $0.role == .loop }), loop.endBar < Double(max(1, lengthBars)) else { return nil }
        return loop.endBar
    }

    private func label(for role: PhaseRole, phase: Phase) -> String {
        switch role {
        case .loop: return moveKind == "loopMix" ? "Loop, fade in" : "Loop"
        case .build: return phase.name == "Tempo ramp" ? "Tempo" : "Build"
        case .fadeIn: return "Fade in"
        case .release: return phase.name == "Bass swap" ? "Swap" : "Release"
        case .fadeOut:
            if phase.name.hasPrefix("Echo") { return "Echo out" }
            return phase.name == "Filter out" ? "Filter out" : "Fade out"
        }
    }

    var moveSummary: String {
        var steps: [String] = []
        for phase in phases {
            let step = summaryStep(for: phase, after: steps.last)
            if steps.last != step { steps.append(step) }
        }
        guard let first = steps.first else { return moveName }
        let lead = first.prefix(1).uppercased() + first.dropFirst()
        switch steps.count {
        case 1: return lead
        case 2: return "\(lead), then \(steps[1])"
        default: return ([lead] + steps.dropFirst().dropLast()).joined(separator: ", ") + ", then \(steps[steps.count - 1])"
        }
    }

    private func summaryStep(for phase: Phase, after previous: String?) -> String {
        switch role(of: phase) {
        case .loop: return moveKind == "loopMix" ? "loop and fade in" : "loop"
        case .build: return phase.name == "Tempo ramp" ? "match the tempo" : "build"
        case .fadeIn: return "fade in"
        case .release:
            switch phase.name {
            case "Bass swap": return "swap the bass"
            case "Cut": return "cut"
            default: return "drop"
            }
        case .fadeOut:
            if phase.name.hasPrefix("Echo") { return "echo out" }
            if phase.name == "Filter out" { return "filter out" }
            return previous == "echo out" || previous == "filter out" || previous == "fade" ? "fade" : "fade out"
        }
    }

    func caption(for phase: Phase?) -> String {
        guard let phase else { return "\(moveName) into \(incomingTitle)" }
        let leaving = outgoingTitle ?? outgoing?.title ?? "the last track"
        switch role(of: phase) {
        case .loop: return moveKind == "loopMix" ? "Looping, bringing in \(incomingTitle)" : "Looping"
        case .build: return phase.name == "Tempo ramp" ? "Matching the tempo" : "Building"
        case .fadeIn: return "Bringing in \(incomingTitle)"
        case .release:
            switch phase.name {
            case "Bass swap": return "Swapping the bass"
            case "Cut": return "Cutting to \(incomingTitle)"
            default: return "Dropping \(incomingTitle)"
            }
        case .fadeOut:
            if phase.name.hasPrefix("Echo") { return "Echoing out \(leaving)" }
            if phase.name == "Filter out" { return "Filtering out \(leaving)" }
            return "Fading out \(leaving)"
        }
    }

    func levels(atBar bar: Double) -> (outgoing: Double, incoming: Double) {
        let total = Double(max(1, lengthBars))
        if bar < 0 { return (1, 0) }
        if bar >= total { return (0, 1) }
        guard let phase = phases.last(where: { bar >= $0.startBar }) else { return (1, 0) }
        let fraction = max(0, min(1, (bar - phase.startBar) / max(0.001, phase.bars)))
        switch role(of: phase) {
        case .loop: return (1, moveKind == "loopMix" ? fraction : 0)
        case .build: return (1, 0)
        case .fadeIn: return (1, fraction)
        case .release: return phase.name == "Bass swap" ? (1, 1) : (0, 1)
        case .fadeOut: return (1 - fraction, 1)
        }
    }

    func deckPosition(_ deck: Deck, at date: Date) -> Double {
        deck.position(after: isPlaying ? date.timeIntervalSince(anchoredAt) : 0)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> AutoMixLiveState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AutoMixLiveState.self, from: data)
    }

    var symbolName: String {
        switch moveKind {
        case "loopRoll": return "repeat"
        case "cut", "dropOnTheOne": return "scissors"
        case "echoOut": return "dot.radiowaves.right"
        case "dropIn": return "arrow.down.to.line"
        case "fxBuild", "breakdownExit": return "camera.filters"
        case "tempoRamp": return "speedometer"
        case "jump": return "arrow.uturn.forward"
        default: return "arrow.triangle.merge"
        }
    }
}
