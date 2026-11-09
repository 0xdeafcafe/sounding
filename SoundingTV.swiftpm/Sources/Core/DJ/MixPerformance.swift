import Foundation


struct MixPerformanceMove: Equatable, Sendable, Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case loopRoll
        case highPassBuild
        case lowPassDip
        case echoThrow

        var displayName: String {
            switch self {
            case .loopRoll: return "Loop roll"
            case .highPassBuild: return "Filter build"
            case .lowPassDip: return "Filter dip"
            case .echoThrow: return "Echo throw"
            }
        }
    }

    let kind: Kind
    let startSeconds: TimeInterval
    let landingSeconds: TimeInterval
    let endSeconds: TimeInterval
    let startBar: Int
    let landingBar: Int
    let lengthBeats: Int
    let depth: Double

    var id: String { "\(kind.rawValue)-\(landingBar)" }
    var lengthSeconds: TimeInterval { landingSeconds - startSeconds }
    var span: ClosedRange<TimeInterval> { startSeconds...max(startSeconds, endSeconds) }
}

struct MixPerformanceTrack: Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case intro
        case build
        case drop
        case breakdown
        case outro
        case other
    }

    struct Section: Equatable, Sendable {
        let role: Role
        let start: TimeInterval
        let end: TimeInterval
    }

    var trackId: String
    var duration: TimeInterval
    var downbeats: [TimeInterval]
    var barsPerPhrase: Int = 8
    var phraseOffsetBars: Int = 0
    var vocals: [ClosedRange<TimeInterval>]?
    var barLevel: [Float]?
    var barDensity: [Float]?
    var barLoop: [Float]?
    var sections: [Section] = []

    static let sparseDensity: Float = 0.5
    static let loopable: Float = 0.8

    func barLength(at index: Int) -> TimeInterval {
        guard downbeats.count >= 2 else { return 2 }
        if index + 1 < downbeats.count, index >= 0 { return downbeats[index + 1] - downbeats[index] }
        return downbeats[downbeats.count - 1] - downbeats[downbeats.count - 2]
    }

    func role(at seconds: TimeInterval) -> Role {
        sections.first { seconds >= $0.start && seconds < $0.end }?.role ?? .other
    }

    func vocalSeconds(_ span: ClosedRange<TimeInterval>) -> TimeInterval {
        (vocals ?? []).reduce(0) { $0 + max(0, min($1.upperBound, span.upperBound) - max($1.lowerBound, span.lowerBound)) }
    }

    func isPhraseStart(_ bar: Int) -> Bool {
        guard barsPerPhrase > 0 else { return false }
        return ((bar - phraseOffsetBars) % barsPerPhrase + barsPerPhrase) % barsPerPhrase == 0
    }

    func meanLevel(bars range: Range<Int>) -> Float? {
        guard let barLevel else { return nil }
        let lower = max(0, range.lowerBound)
        let upper = min(barLevel.count, range.upperBound)
        guard upper > lower else { return nil }
        return barLevel[lower..<upper].reduce(0, +) / Float(upper - lower)
    }

    static let meatyDecibels: Float = 2
    static let jumpDecibels: Float = 4
    static let steadyDecibels: Float = 3

    func isMeaty(_ bar: Int) -> Bool {
        guard let barLevel, let barDensity, let median = medianLevel, bar >= 0, bar < barLevel.count, bar < barDensity.count else { return true }
        return barLevel[bar] >= median - Self.meatyDecibels && barDensity[bar] > Self.sparseDensity
    }

    func hasJump(in bars: Range<Int>) -> Bool {
        bars.contains { bar in
            guard let before = meanLevel(bars: (bar - 2)..<bar), let after = meanLevel(bars: bar..<(bar + 2)) else { return false }
            return after - before >= Self.jumpDecibels
        }
    }

    func isSteady(_ bars: Range<Int>) -> Bool {
        guard let barLevel, bars.lowerBound >= 0, bars.upperBound <= barLevel.count, !bars.isEmpty else { return false }
        let slice = barLevel[bars]
        return (slice.max() ?? 0) - (slice.min() ?? 0) <= Self.steadyDecibels
    }

    var medianLevel: Float? {
        guard let barLevel, !barLevel.isEmpty else { return nil }
        let sorted = barLevel.filter { $0 > -80 }.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }
}

enum MixPerformancePlanner {
    struct Request: Sendable {
        var track: MixPerformanceTrack
        var level: MixPerformanceLevel
        var playable: ClosedRange<TimeInterval>
        var avoiding: [ClosedRange<TimeInterval>] = []
        var seed: UInt64? = nil
        var allowed: Set<MixPerformanceMove.Kind> = Set(MixPerformanceMove.Kind.allCases)
    }

    static let vocalMarginSeconds: TimeInterval = 0.05
    static let echoTailBars = 2
    static let arrivalStepDecibels: Float = 2

    static func plan(_ request: Request) -> [MixPerformanceMove] {
        let track = request.track
        let level = request.level
        guard level != .off, track.vocals != nil, track.downbeats.count >= 4 * track.barsPerPhrase,
              track.barsPerPhrase > 0 else { return [] }
        var random = SeededRandom(seed: request.seed ?? Self.seed(track.trackId))
        guard random.unit() < level.trackChance else { return [] }

        var candidates: [(move: MixPerformanceMove, score: Double)] = []
        for bar in track.barsPerPhrase..<(track.downbeats.count - 2) where track.isPhraseStart(bar) {
            for kind in MixPerformanceMove.Kind.allCases where request.allowed.contains(kind) {
                guard let move = shape(kind, landingBar: bar, track: track, level: level),
                      admits(move, request: request),
                      let score = score(move, track: track, level: level) else { continue }
                candidates.append((move, score))
            }
        }
        guard !candidates.isEmpty else { return [] }

        var chosen: [MixPerformanceMove] = []
        var pool = candidates
        while chosen.count < level.maximumMoves, !pool.isEmpty {
            let total = pool.reduce(0) { $0 + $1.score }
            guard total > 0 else { break }
            var pick = random.unit() * total
            var index = 0
            for (i, candidate) in pool.enumerated() {
                pick -= candidate.score
                if pick <= 0 { index = i; break }
                index = i
            }
            let move = pool[index].move
            chosen.append(move)
            pool.removeAll { other in
                abs(other.move.landingBar - move.landingBar) < level.minimumGapBars
                    || other.move.kind == move.kind
            }
            if chosen.count == 1, level == .lively, random.unit() < 0.35 { break }
        }
        return chosen.sorted { $0.startSeconds < $1.startSeconds }
    }

    static func shape(_ kind: MixPerformanceMove.Kind, landingBar bar: Int, track: MixPerformanceTrack, level: MixPerformanceLevel) -> MixPerformanceMove? {
        let downbeats = track.downbeats
        guard bar > 0, bar < downbeats.count else { return nil }
        let landing = downbeats[bar]
        let lively = level == .lively
        switch kind {
        case .loopRoll:
            let bars = 2
            guard bar - bars >= 0 else { return nil }
            return MixPerformanceMove(
                kind: kind, startSeconds: downbeats[bar - bars], landingSeconds: landing, endSeconds: landing,
                startBar: bar - bars, landingBar: bar, lengthBeats: bars * 4, depth: lively ? 1 : 0.6
            )
        case .highPassBuild:
            let bars = lively ? 8 : 4
            guard bar - bars >= 0 else { return nil }
            return MixPerformanceMove(
                kind: kind, startSeconds: downbeats[bar - bars], landingSeconds: landing, endSeconds: landing,
                startBar: bar - bars, landingBar: bar, lengthBeats: bars * 4, depth: lively ? 1 : 0.6
            )
        case .lowPassDip:
            let bars = 4
            guard bar - bars >= 0 else { return nil }
            return MixPerformanceMove(
                kind: kind, startSeconds: downbeats[bar - bars], landingSeconds: landing, endSeconds: landing,
                startBar: bar - bars, landingBar: bar, lengthBeats: bars * 4, depth: lively ? 1 : 0.6
            )
        case .echoThrow:
            let beat = track.barLength(at: bar - 1) / 4
            let tailEnd = bar + echoTailBars < downbeats.count ? downbeats[bar + echoTailBars] : landing + Double(echoTailBars) * 4 * beat
            return MixPerformanceMove(
                kind: kind, startSeconds: landing - beat, landingSeconds: landing, endSeconds: tailEnd,
                startBar: bar - 1, landingBar: bar, lengthBeats: 1, depth: lively ? 1 : 0.7
            )
        }
    }

    static func admits(_ move: MixPerformanceMove, request: Request) -> Bool {
        let track = request.track
        let bar = track.barLength(at: move.landingBar)
        let guarded = (move.startSeconds - bar)...(move.endSeconds + bar)
        guard move.startSeconds >= request.playable.lowerBound + Double(track.barsPerPhrase) * bar,
              move.endSeconds + Double(track.barsPerPhrase) * bar <= request.playable.upperBound,
              move.endSeconds < track.duration - 4 * bar else { return false }
        guard !request.avoiding.contains(where: { $0.overlaps(guarded) }) else { return false }
        let beat = bar / 4
        let ear = (move.startSeconds - beat)...(max(move.endSeconds, move.landingSeconds + beat))
        guard track.vocalSeconds(ear) <= vocalMarginSeconds else { return false }
        return true
    }

    static func score(_ move: MixPerformanceMove, track: MixPerformanceTrack, level: MixPerformanceLevel) -> Double? {
        guard let median = track.medianLevel, track.barLevel != nil, track.barDensity != nil else { return nil }
        let landing = move.landingBar
        let active = move.startBar..<landing
        guard !active.contains(where: track.isMeaty) else { return nil }
        guard !track.hasJump(in: (move.startBar - settleBars + 1)..<landing) else { return nil }
        guard let before = track.meanLevel(bars: active), before >= median - quietestDecibels else { return nil }
        let after = track.meanLevel(bars: landing..<(landing + 4)) ?? before
        let step = after - before
        let arrivalRole = track.role(at: track.downbeats[landing] + 0.05)
        let arrival = arrivalRole == .drop || step >= arrivalStepDecibels
        let thirtyTwo = (landing - track.phraseOffsetBars) % max(1, track.barsPerPhrase * 2) == 0
        let structural = thirtyTwo ? 1.0 : 0.6
        switch move.kind {
        case .loopRoll:
            guard arrival else { return nil }
            let looped = move.startBar
            let loopable = track.barLoop.map { looped < $0.count && $0[looped] >= MixPerformanceTrack.loopable } ?? false
            let sparse = track.barDensity.map { looped < $0.count && $0[looped] <= MixPerformanceTrack.sparseDensity } ?? false
            guard loopable || sparse else { return nil }
            return (level == .lively ? 1.2 : 0.5) * structural
        case .highPassBuild:
            guard arrival || thirtyTwo else { return nil }
            return (arrival ? 1.4 : 0.6) * structural
        case .lowPassDip:
            guard arrivalRole != .breakdown, step > -arrivalStepDecibels, track.isSteady(active) else { return nil }
            return 1.0 * structural
        case .echoThrow:
            let dropsOut = arrivalRole == .breakdown || step <= -arrivalStepDecibels
            return (dropsOut ? 1.3 : 0.8) * structural
        }
    }

    static let settleBars = 8
    static let quietestDecibels: Float = 9

    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    struct SeededRandom {
        var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 0x9e3779b97f4a7c15 : seed }

        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}

struct MixPerformanceSchedule: Equatable, Sendable {
    var trackId: String
    var moves: [MixPerformanceMove]
    var groups: [Int32] = []

    func upcoming(after seconds: TimeInterval) -> MixPerformanceMove? {
        moves.first { $0.startSeconds > seconds }
    }

    func active(at seconds: TimeInterval) -> MixPerformanceMove? {
        moves.first { $0.span.contains(seconds) }
    }

    func barsUntil(_ move: MixPerformanceMove, from seconds: TimeInterval) -> Int {
        let bar = move.lengthSeconds * 4 / Double(max(1, move.lengthBeats))
        guard bar > 0 else { return 0 }
        return max(0, Int(((move.startSeconds - seconds) / bar).rounded(.up)))
    }
}

extension MixTimeline {
    static let performanceReleaseBeats: Double = 1
    static let rollFilterHertz: (subtle: Double, lively: Double) = (220, 420)
    static let buildFilterHertz: (subtle: Double, lively: Double) = (320, 650)
    static let dipFilterHertz: (subtle: Double, lively: Double) = (1_100, 500)
    static let dipReleaseBeats: Double = 2
    static let dipResonance: Double = 0.06

    static func performance(_ move: MixPerformanceMove, deck: Int, track: MixPerformanceTrack, sampleRate sr: Double, rate: Double) -> MixTimeline {
        let speed = max(0.01, rate)
        let wallLength = max(0, move.endSeconds - move.startSeconds) / speed
        var timeline = MixTimeline(
            anchor: .deckPosition(deck: deck, frame: move.startSeconds * sr),
            lengthFrames: Int64((wallLength * sr).rounded())
        )
        func wall(_ source: TimeInterval) -> TimeInterval { max(0, source - move.startSeconds) / speed }
        func frames(_ seconds: TimeInterval) -> Int64 { Int64((max(0, seconds) * sr).rounded()) }
        let landing = wall(move.landingSeconds)
        let beat = track.barLength(at: max(0, move.landingBar - 1)) / 4
        let release = beat * performanceReleaseBeats / speed
        let lively = move.depth >= 1
        let open = MixEngine.filterCutoffRange.lowerBound
        let closed = MixEngine.filterCutoffRange.upperBound
        switch move.kind {
        case .loopRoll:
            let span = move.landingSeconds - move.startSeconds
            let rollBeat = span / Double(max(1, move.lengthBeats))
            var rung = span / 2
            var at: TimeInterval = 0
            while rung > 0 {
                timeline.add(at / speed, .loop(deck: deck, startFrame: move.startSeconds * sr, lengthFrames: rung * sr), sampleRate: sr)
                if rung <= rollBeat + 1e-6 { break }
                at += rung
                rung /= 2
            }
            let hertz = lively ? rollFilterHertz.lively : rollFilterHertz.subtle
            let reopen = max(0, landing - release)
            timeline.add(0, .ramp(.highPass(deck), to: hertz, frames: frames(reopen), curve: .logarithmic), sampleRate: sr)
            timeline.add(reopen, .ramp(.highPass(deck), to: open, frames: frames(landing - reopen), curve: .logarithmic), sampleRate: sr)
            timeline.add(landing, .clearLoop(deck: deck), sampleRate: sr)
            timeline.add(landing, .seek(deck: deck, frame: move.landingSeconds * sr), sampleRate: sr)
        case .highPassBuild:
            let hertz = lively ? buildFilterHertz.lively : buildFilterHertz.subtle
            let reopen = max(0, landing - release)
            timeline.add(0, .ramp(.resonance(deck), to: 0.08, frames: frames(reopen), curve: .smooth), sampleRate: sr)
            timeline.add(0, .ramp(.highPass(deck), to: hertz, frames: frames(reopen), curve: .logarithmic), sampleRate: sr)
            timeline.add(reopen, .ramp(.highPass(deck), to: open, frames: frames(landing - reopen), curve: .logarithmic), sampleRate: sr)
            timeline.add(reopen, .ramp(.resonance(deck), to: 0, frames: frames(landing - reopen), curve: .smooth), sampleRate: sr)
        case .lowPassDip:
            let hertz = lively ? dipFilterHertz.lively : dipFilterHertz.subtle
            let close = wall(move.landingSeconds - 4 * beat)
            let reopen = wall(move.landingSeconds - dipReleaseBeats * beat)
            let reopenFrames = frames(landing - reopen)
            timeline.add(0, .ramp(.resonance(deck), to: dipResonance, frames: frames(close), curve: .smooth), sampleRate: sr)
            timeline.add(0, .ramp(.lowPass(deck), to: hertz, frames: frames(close), curve: .logarithmic), sampleRate: sr)
            timeline.add(reopen, .ramp(.lowPass(deck), to: closed, frames: reopenFrames, curve: .logarithmic), sampleRate: sr)
            timeline.add(reopen, .ramp(.resonance(deck), to: 0, frames: reopenFrames, curve: .smooth), sampleRate: sr)
        case .echoThrow:
            let send = lively ? 0.55 : 0.4
            let feedback = lively ? 0.5 : 0.42
            timeline.add(0, .echoTime(seconds: beat / speed), sampleRate: sr)
            timeline.add(0, .ramp(.echoFeedback, to: feedback, frames: 0, curve: .linear), sampleRate: sr)
            timeline.add(0, .ramp(.echoSend(deck), to: send, frames: 0, curve: .linear), sampleRate: sr)
            timeline.add(landing, .ramp(.echoSend(deck), to: 0, frames: 0, curve: .linear), sampleRate: sr)
            timeline.add(wallLength, .ramp(.echoFeedback, to: MixParameter.echoFeedback.defaultValue, frames: 0, curve: .linear), sampleRate: sr)
        }
        timeline.events.sort { $0.offset < $1.offset }
        return timeline
    }
}
