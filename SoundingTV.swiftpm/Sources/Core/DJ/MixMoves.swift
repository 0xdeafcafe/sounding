import Foundation

struct MixMove: Equatable, Sendable, Codable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case blend
        case cut
        case echoOut
        case breakdownExit
        case dropIn
        case dropOnTheOne
        case loopRoll
        case fxBuild
        case tempoRamp
        case bridge
        case jump
        case loopMix
    }

    enum Effect: String, Sendable, Codable, CaseIterable {
        case none
        case filterSweep
        case echo
        case reverbWash
    }

    struct Rung: Equatable, Sendable, Codable {
        var bars: Int
        var passes: Int
    }

    var kind: Kind
    var effect: Effect = .none
    var leadBars: Int = 0
    var blendBars: Int = 0
    var incomingLeadBars: Int = 0
    var ladder: [Rung] = []
    var outgoingRateTarget: Double?
    var bassSwapBar: Int?
    var tailBars: Int = 0
    var jumpBars: Int = 0
    var outLoopBars: Int = 0
    var inLoopBars: Int = 0
    var shape: MixMoveShape?
    var filter: MixFilterShape?

    var filterShape: MixFilterShape { filter ?? (kind == .loopMix ? .filterOut : .plain) }

    var landingBar: Int {
        ladder.isEmpty ? leadBars : ladder.reduce(0) { $0 + $1.bars * $1.passes }
    }

    var repeatedBars: Int {
        guard let first = ladder.first else { return 0 }
        return landingBar - first.bars
    }

    var totalBars: Int { landingBar + blendBars + tailBars }

    var hasOverlap: Bool { blendBars > 0 || incomingLeadBars > 0 }

    var phraseBars: Int { landingBar + blendBars }

    static func blend(bars: Int, swapAt: Int? = nil) -> MixMove {
        MixMove(kind: .blend, blendBars: bars, bassSwapBar: swapAt)
    }

    static let cut = MixMove(kind: .cut)

    static let echoOut = MixMove(kind: .echoOut, effect: .echo, leadBars: 1, tailBars: 4)

    static func breakdownExit(bars: Int) -> MixMove {
        MixMove(kind: .breakdownExit, effect: .filterSweep, blendBars: bars, bassSwapBar: max(1, bars / 2))
    }

    static func dropIn(buildBars: Int, outBars: Int = 1) -> MixMove {
        MixMove(kind: .dropIn, leadBars: buildBars, blendBars: outBars, incomingLeadBars: buildBars)
    }

    static func dropOnTheOne(echo: Bool) -> MixMove {
        MixMove(kind: .dropOnTheOne, effect: echo ? .echo : .none, leadBars: echo ? 1 : 0, tailBars: echo ? 2 : 0)
    }

    static func loopRoll(_ ladder: [Rung], effect: Effect = .filterSweep) -> MixMove {
        MixMove(kind: .loopRoll, effect: effect, ladder: ladder, tailBars: effect == .none ? 0 : 2)
    }

    static func fxBuild(_ effect: Effect, bars: Int) -> MixMove {
        MixMove(kind: .fxBuild, effect: effect, leadBars: bars, tailBars: 2)
    }

    static func tempoRamp(rampBars: Int, to rate: Double, blendBars: Int) -> MixMove {
        MixMove(kind: .tempoRamp, leadBars: rampBars, blendBars: blendBars, outgoingRateTarget: rate, bassSwapBar: max(1, blendBars / 2))
    }

    static func bridge(bars: Int) -> MixMove {
        MixMove(kind: .bridge, blendBars: bars, bassSwapBar: max(1, bars / 2))
    }

    static func jump(bars: Int, blendBars: Int) -> MixMove {
        MixMove(kind: .jump, blendBars: blendBars, bassSwapBar: max(1, blendBars / 2), jumpBars: bars)
    }

    static func loopMix(outLoop: Int, inLoop: Int, fadeIn: Int, fadeOut: Int, filter: MixFilterShape? = nil) -> MixMove {
        MixMove(kind: .loopMix, effect: .filterSweep, leadBars: fadeIn, blendBars: fadeOut, outLoopBars: outLoop, inLoopBars: inLoop, filter: filter)
    }

    static let standardLadder: [Rung] = [Rung(bars: 8, passes: 1), Rung(bars: 4, passes: 1), Rung(bars: 2, passes: 1), Rung(bars: 1, passes: 2)]
    static let gentleLadder: [Rung] = [Rung(bars: 8, passes: 1), Rung(bars: 4, passes: 2)]

    var baseRisk: Double {
        switch kind {
        case .blend: return 0
        case .cut: return 0.05
        case .echoOut: return 0.1
        case .breakdownExit: return 0.2
        case .dropIn: return 0.3
        case .dropOnTheOne: return 0.3
        case .fxBuild: return effect == .reverbWash ? 0.5 : 0.3
        case .bridge: return 0.45
        case .tempoRamp: return 0.5
        case .loopRoll: return 0.6
        case .jump: return 0.7
        case .loopMix: return 0
        }
    }

    var usesRiser: Bool {
        switch kind {
        case .dropIn, .loopRoll: return true
        case .fxBuild: return effect == .filterSweep || effect == .echo
        default: return false
        }
    }

    var energyDirection: Int {
        switch kind {
        case .dropIn, .dropOnTheOne, .loopRoll: return 1
        case .fxBuild: return effect == .reverbWash ? -1 : 1
        case .tempoRamp: return (outgoingRateTarget ?? 1) >= 1 ? 1 : -1
        case .breakdownExit, .echoOut: return -1
        case .blend, .cut, .bridge, .jump, .loopMix: return 0
        }
    }

    var displayName: String {
        switch kind {
        case .blend: return "Blend"
        case .cut: return "Cut"
        case .echoOut: return "Echo out"
        case .breakdownExit: return "Breakdown exit"
        case .dropIn: return "Drop-in"
        case .dropOnTheOne: return "Cut on the drop"
        case .loopRoll: return "Loop build"
        case .fxBuild:
            switch effect {
            case .echo: return "Echo build"
            case .reverbWash: return "Reverb wash"
            default: return "Filter build"
            }
        case .tempoRamp: return "Tempo ramp"
        case .bridge: return "Double-time blend"
        case .jump: return "Jump"
        case .loopMix: return "Loop mix"
        }
    }

    func headline(into title: String, durationSeconds: TimeInterval? = nil) -> String {
        let bars = kind == .dropIn ? incomingLeadBars : phraseBars
        let length = bars > 1 ? ", \(bars) bars" : ""
        switch kind {
        case .jump:
            let distance = durationSeconds.map { DJFormat.time($0) } ?? "\(jumpBars) bars"
            return "Jump ahead \(distance)\(length)"
        case .cut:
            return "Cut into \(title)"
        case .dropOnTheOne:
            return "Cut into \(title) on the drop"
        case .dropIn:
            return "Drop-in on \(title)\(length)"
        default:
            return "\(displayName) into \(title)\(length)"
        }
    }
}

enum MixFilterShape: String, Sendable, Codable, CaseIterable {
    case plain
    case highPass
    case lowPass
    case combined
    case filterOut

    var outgoingHighPass: Bool { self == .highPass || self == .combined || self == .filterOut }
    var incomingLowPass: Bool { self == .lowPass || self == .combined }
    var outgoingEQFade: Bool { self == .filterOut }

    func bands(x: Double, swap: Double, midHandover: Bool, incomingMidCut: Double) -> TransitionBandGains {
        func power(_ decibels: Double) -> Double { pow(10, decibels / 10) }
        let sf = min(0.95, max(0.05, swap))
        let before = x < sf
        let into = before ? x / sf : 1
        let after = before ? 0 : (x - sf) / max(1e-6, 1 - sf)
        var g = TransitionBandGains()
        g.outLow = before ? 1 : 0
        g.inLow = before ? 0 : 1
        if midHandover {
            g.inMid = power(TransitionLevel.midHandoverDecibels * (1 - into))
            g.outMid = power(TransitionLevel.midHandoverDecibels * after)
        }
        if incomingMidCut < 0, x < 1 - MixTimeline.midRestoreFraction { g.inMid = power(incomingMidCut) }
        if incomingLowPass {
            g.inHigh *= into * into
            g.inMid *= 0.5 + 0.5 * into
        }
        if outgoingHighPass, !outgoingEQFade { g.outMid *= 1 - 0.25 * after }
        if outgoingEQFade {
            g.outMid *= power(MixMoveBuilder.loopMixFadeDecibels * after)
            g.outHigh *= power(MixMoveBuilder.loopMixFadeDecibels * after)
        }
        return g
    }
}

struct MixMoveShape: Equatable, Sendable, Codable {
    var bassSwapBar: Double?
    var fadeIn: ClosedRange<Double>?
    var fadeOut: ClosedRange<Double>?
    var outgoingFilter: ClosedRange<Double>?
    var incomingHighPassHertz: Double?
}

struct MixMoveBuilder {
    static let cutFadeFrames: Int64 = 441
    static let loopSettleFrames: Int64 = 64
    static let buildHighPassHertz: Double = 1_400
    static let dropInHighPassHertz: Double = 220
    static let breakdownLowPassHertz: Double = 320
    static let riserMaximumBars = 8
    static let riserMinimumBars = 2
    static let riserReleaseFrames: Int64 = 1_024
    static let loopMixHighPassHertz: Double = 900
    static let loopMixFadeDecibels: Double = -40
    static let blendHighPassHertz: Double = 400
    static let blendLowPassHertz: Double = 1_000
    static let unlockedCurveCeiling: Double = 0.6

    let move: MixMove
    let input: MixTransitionTimelineInput
    let sr: Double
    let out: Int
    let inc: Int
    let r0: Double
    let r1: Double
    let ratio: Double
    let anchor: TimeInterval
    let downbeats: [TimeInterval]
    let base: Int?
    let barSeconds: Double
    let beatSeconds: Double
    let lock: Bool
    private(set) var timeline: MixTimeline

    init(move: MixMove, input: MixTransitionTimelineInput) {
        self.move = move
        self.input = input
        sr = input.sampleRate
        out = input.outgoing
        inc = input.incoming
        r0 = max(0.01, input.outgoingRate)
        r1 = max(0.01, move.outgoingRateTarget ?? input.outgoingRate)
        ratio = max(0.01, input.incomingRate) / r0
        anchor = input.anchorSourceSeconds
        let grid = input.outgoingGrid
        let measured = (grid?.downbeats ?? []).sorted()
        downbeats = measured
        base = measured.firstIndex { $0 >= input.anchorSourceSeconds - 0.002 }
        let beat = grid.map { $0.localBeatPeriod(at: input.anchorSourceSeconds) } ?? 0.5
        beatSeconds = beat > 0 ? beat : 0.5
        barSeconds = beatSeconds * 4
        lock = input.phaseLock
        timeline = MixTimeline(anchor: .deckPosition(deck: input.outgoing, frame: input.anchorSourceSeconds * input.sampleRate))
    }

    func source(_ k: Int) -> TimeInterval {
        if let base, !downbeats.isEmpty {
            let index = base + k
            if index >= 0, index < downbeats.count { return downbeats[index] }
            let last = downbeats.count - 1
            let lastBar = last > 0 ? downbeats[last] - downbeats[last - 1] : barSeconds
            return downbeats[last] + Double(index - last) * lastBar
        }
        return anchor + Double(k) * barSeconds
    }

    var offset0: TimeInterval { max(0, source(0) - anchor) / r0 }

    func wall(_ k: Int) -> TimeInterval {
        let lead = move.landingBar
        if move.kind == .loopMix, move.outLoopBars > 0 {
            let length = move.outLoopBars
            let pass = source(length) - source(0)
            return offset0 + (Double(k / length) * pass + source(k % length) - source(0)) / r0
        }
        if !move.ladder.isEmpty {
            var t = offset0
            var bars = 0
            for rung in move.ladder {
                let pass = (source(rung.bars) - source(0)) / r0
                for _ in 0..<rung.passes {
                    if bars + rung.bars > k {
                        let into = k - bars
                        return t + (source(into) - source(0)) / r0
                    }
                    t += pass
                    bars += rung.bars
                }
            }
            let tail = source(1) - source(0)
            return t + Double(k - bars) * tail / r0
        }
        guard abs(r1 - r0) > 1e-9, lead > 0 else {
            return offset0 + (source(k) - source(0)) / r0
        }
        let span = source(lead) - source(0)
        let rampWall = 2 * span / (r0 + r1)
        if k >= lead {
            return offset0 + rampWall + (source(k) - source(lead)) / r1
        }
        let s = source(k) - source(0)
        let a = (r1 - r0) / (2 * rampWall)
        let t = abs(a) < 1e-12 ? s / r0 : (-r0 + (r0 * r0 + 4 * a * s).squareRoot()) / (2 * a)
        return offset0 + t
    }

    func wall(bar position: Double) -> TimeInterval {
        let k = Int(position.rounded(.down))
        let fraction = position - Double(k)
        guard fraction > 1e-9 else { return wall(k) }
        return wall(k) + (wall(k + 1) - wall(k)) * fraction
    }

    func rateAt(bar k: Int) -> Double {
        guard move.outgoingRateTarget != nil, move.landingBar > 0 else { return r0 }
        return k >= move.landingBar ? r1 : r0 + (r1 - r0) * (wall(k) - offset0) / max(1e-9, wall(move.landingBar) - offset0)
    }

    func frames(_ seconds: TimeInterval) -> Int64 { Int64((max(0, seconds) * sr).rounded()) }

    func physical(_ position: Double) -> Double { inc == 1 ? position : 1 - position }

    mutating func at(_ seconds: TimeInterval, _ action: MixTimelineAction) {
        timeline.events.append(MixTimeline.Event(offset: frames(seconds), action: action))
    }

    mutating func atFrame(_ frame: Int64, _ action: MixTimelineAction) {
        timeline.events.append(MixTimeline.Event(offset: max(0, frame), action: action))
    }

    mutating func ramp(_ parameter: MixParameter, at seconds: TimeInterval, to value: Double, over duration: TimeInterval, curve: MixCurve = .linear) {
        at(seconds, .ramp(parameter, to: value, frames: frames(duration), curve: curve))
    }

    mutating func startIncoming(at seconds: TimeInterval, rate: Double, locks: Bool) {
        if abs(rate - input.incomingRate) > 1e-9 {
            at(seconds, .ramp(.rate(inc), to: rate, frames: 0, curve: .linear))
        }
        at(seconds, .start(deck: inc, fromFrame: input.entrySeconds * sr))
        if locks { at(seconds, .phaseLock(deck: inc, reference: out)) }
        if guardsMids { at(seconds, .ramp(.eqMid(inc), to: input.incomingMidCutDecibels, frames: 0, curve: .linear)) }
    }

    var guardsMids: Bool { input.incomingMidCutDecibels < 0 && move.hasOverlap && move.kind != .loopMix }

    mutating func cut(at seconds: TimeInterval) {
        at(seconds, .ramp(.holdTail(inc), to: 1, frames: 0, curve: .linear))
        at(seconds, .ramp(.eqLow(inc), to: 0, frames: 64, curve: .linear))
        at(seconds, .ramp(.crossfade, to: physical(1), frames: Self.cutFadeFrames, curve: .linear))
        at(seconds + Double(Self.cutFadeFrames * 2) / sr, .ramp(.holdTail(inc), to: 0, frames: 0, curve: .linear))
    }

    var level: TransitionLevel { input.level ?? .typical }

    var midHandover: Bool { level.bothBusy && !guardsMids }

    func faderShape(swapFraction: Double, locked: Bool) -> Double? {
        if level.legacyFaderLaw { return locked ? 1 : nil }
        let filter = move.filterShape
        let handover = midHandover
        let cut = guardsMids ? input.incomingMidCutDecibels : 0
        return TransitionFaderLaw.curveShape(
            outgoing: level.outgoing,
            incoming: level.incoming,
            range: locked ? 0...1 : 0...Self.unlockedCurveCeiling
        ) { x in
            filter.bands(x: x, swap: swapFraction, midHandover: handover, incomingMidCut: cut)
        }
    }

    mutating func blend(from start: Int, bars: Int, swapAt: Int?, curve: Bool) {
        if move.kind == .blend, move.filter == nil {
            eqBlend(from: start, bars: bars, swapAt: swapAt)
            return
        }
        let begin = wall(start)
        let end = wall(start + bars)
        let fadeBegin = move.shape?.fadeIn.map { wall(bar: $0.lowerBound) } ?? begin
        let fadeEnd = move.shape?.fadeOut.map { wall(bar: $0.upperBound) } ?? end
        let swapBar = start + min(max(1, swapAt ?? bars / 2), max(1, bars - 1))
        let swap = move.shape?.bassSwapBar.map { wall(bar: $0) } ?? wall(swapBar)
        let fraction = (swap - fadeBegin) / max(1e-6, fadeEnd - fadeBegin)
        if let shape = faderShape(swapFraction: fraction, locked: curve) {
            at(begin, .ramp(.crossfadeCurve, to: shape, frames: 0, curve: .linear))
        }
        ramp(.crossfade, at: fadeBegin, to: physical(1), over: max(0, fadeEnd - fadeBegin))
        let over = min(beatSeconds / max(0.01, rateAt(bar: swapBar)), max(0.01, end - swap))
        ramp(.eqLow(out), at: swap, to: MixEngine.bassKillDecibels, over: over, curve: .power)
        ramp(.eqLow(inc), at: swap, to: 0, over: over, curve: .power)
        handOver(fadeBegin: fadeBegin, swap: swap, fadeEnd: fadeEnd, filter: move.filterShape)
    }

    static let eqBlendIncomingMidDecibels: Double = -9
    static let eqBlendIncomingMidHoldDecibels: Double = -3

    mutating func eqBlend(from start: Int, bars: Int, swapAt: Int?) {
        let swapBar = start + min(max(1, swapAt ?? bars / 2), max(1, bars - 1))
        let begin = wall(start)
        let end = wall(start + bars)
        let swap = wall(swapBar)
        let faded = wall(start + min(bars >= 16 ? 4 : 2, swapBar - start))
        let restore = wall(swapBar - min(4, swapBar - start))
        let tail = start + bars - swapBar
        let highBars = min(4, tail)
        let midsEnd = wall(swapBar + max(1, min(8, tail - highBars > 0 ? tail - highBars : tail)))
        let highsStart = wall(start + bars - highBars)
        at(begin, .ramp(.crossfadeCurve, to: 1, frames: 0, curve: .linear))
        at(begin, .ramp(.eqLow(inc), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
        let over = min(beatSeconds / max(0.01, rateAt(bar: swapBar)), max(0.01, end - swap))
        if !guardsMids {
            at(begin, .ramp(.eqMid(inc), to: Self.eqBlendIncomingMidDecibels, frames: 0, curve: .linear))
            ramp(.eqMid(inc), at: faded, to: Self.eqBlendIncomingMidHoldDecibels, over: max(0.01, restore - faded))
            ramp(.eqMid(inc), at: swap, to: 0, over: over)
        }
        if let hertz = move.shape?.incomingHighPassHertz {
            at(begin, .ramp(.highPass(inc), to: hertz, frames: 0, curve: .linear))
            ramp(.highPass(inc), at: restore, to: MixEngine.filterCutoffRange.lowerBound, over: max(0.01, swap - restore), curve: .logarithmic)
        }
        ramp(.crossfade, at: begin, to: physical(0.5), over: max(0.01, faded - begin))
        ramp(.eqLow(out), at: swap, to: MixEngine.bassKillDecibels, over: over, curve: .power)
        ramp(.eqLow(inc), at: swap, to: 0, over: over, curve: .power)
        ramp(.eqMid(out), at: swap, to: Self.loopMixFadeDecibels, over: max(0.01, midsEnd - swap))
        ramp(.eqHigh(out), at: highsStart, to: Self.loopMixFadeDecibels, over: max(0.01, end - highsStart))
        ramp(.crossfade, at: highsStart, to: physical(1), over: max(0.01, end - highsStart))
    }

    mutating func handOver(fadeBegin: TimeInterval, swap: TimeInterval, fadeEnd: TimeInterval, filter: MixFilterShape) {
        if midHandover {
            at(fadeBegin, .ramp(.eqMid(inc), to: TransitionLevel.midHandoverDecibels, frames: 0, curve: .linear))
            ramp(.eqMid(inc), at: fadeBegin, to: 0, over: max(0, swap - fadeBegin))
            ramp(.eqMid(out), at: swap, to: TransitionLevel.midHandoverDecibels, over: max(0, fadeEnd - swap))
        }
        let outgoingHertz = move.kind == .loopMix ? Self.loopMixHighPassHertz : Self.blendHighPassHertz
        if filter.outgoingHighPass {
            ramp(.highPass(out), at: swap, to: outgoingHertz, over: max(0, fadeEnd - swap), curve: .logarithmic)
        }
        if filter.incomingLowPass {
            at(fadeBegin, .ramp(.lowPass(inc), to: Self.blendLowPassHertz, frames: 0, curve: .linear))
            ramp(.lowPass(inc), at: fadeBegin, to: MixEngine.filterCutoffRange.upperBound, over: max(0, swap - fadeBegin), curve: .logarithmic)
        }
        if filter.outgoingEQFade {
            ramp(.eqMid(out), at: swap, to: Self.loopMixFadeDecibels, over: max(0, fadeEnd - swap))
            ramp(.eqHigh(out), at: swap, to: Self.loopMixFadeDecibels, over: max(0, fadeEnd - swap))
        }
    }

    mutating func trims() {
        if let gain = level.incomingGain {
            at(wall(0), .ramp(.gain(inc), to: gain, frames: 0, curve: .linear))
        }
        if let gain = level.outgoingGain, move.hasOverlap {
            ramp(.gain(out), at: wall(0), to: gain, over: max(0.05, wall(min(2, max(1, move.landingBar + move.blendBars))) - wall(0)))
        }
    }

    var incomingLoopSeconds: TimeInterval {
        let bars = max(1, move.inLoopBars)
        if let grid = input.incomingGrid, let list = grid.downbeats?.sorted(),
           let index = list.firstIndex(where: { abs($0 - input.entrySeconds) < 0.01 }), index + bars < list.count {
            return list[index + bars] - list[index]
        }
        return Double(bars) * barSeconds * ratio
    }

    mutating func loopMix() {
        let outBars = max(1, move.outLoopBars)
        let begin = wall(0)
        let release = wall(move.leadBars)
        let end = wall(move.leadBars + move.blendBars)
        let shape = move.shape
        let fadeInStart = shape?.fadeIn.map { wall(bar: $0.lowerBound) } ?? begin
        let fadeInEnd = shape?.fadeIn.map { wall(bar: $0.upperBound) } ?? release
        let fadeOutStart = shape?.fadeOut.map { wall(bar: $0.lowerBound) } ?? release
        let fadeOutEnd = shape?.fadeOut.map { wall(bar: $0.upperBound) } ?? end
        let filterStart = shape?.outgoingFilter.map { wall(bar: $0.lowerBound) } ?? release
        let filterEnd = shape?.outgoingFilter.map { wall(bar: $0.upperBound) } ?? end
        let swapAt = shape?.bassSwapBar.map { wall(bar: $0) } ?? release
        at(offset0, .loop(deck: out, startFrame: (source(0) * sr).rounded(), lengthFrames: ((source(outBars) - source(0)) * sr).rounded()))
        at(begin, .ramp(.eqLow(inc), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
        startIncoming(at: begin, rate: input.incomingRate, locks: lock)
        if move.inLoopBars > 0 {
            at(begin, .loop(deck: inc, startFrame: (input.entrySeconds * sr).rounded(), lengthFrames: (incomingLoopSeconds * sr).rounded()))
            at(max(begin, release - beatSeconds / r0 / 2), .clearLoop(deck: inc))
        }
        let filter = move.filterShape
        if let shape = faderShape(swapFraction: 0.5, locked: true) {
            at(begin, .ramp(.crossfadeCurve, to: shape, frames: 0, curve: .linear))
        }
        ramp(.crossfade, at: fadeInStart, to: physical(0.5), over: fadeInEnd - fadeInStart)
        let swap = beatSeconds / r0
        ramp(.eqLow(out), at: swapAt, to: MixEngine.bassKillDecibels, over: swap, curve: .power)
        ramp(.eqLow(inc), at: swapAt, to: 0, over: swap, curve: .power)
        ramp(.crossfade, at: fadeOutStart, to: physical(1), over: fadeOutEnd - fadeOutStart)
        if filter.outgoingHighPass {
            ramp(.highPass(out), at: filterStart, to: Self.loopMixHighPassHertz, over: filterEnd - filterStart, curve: .logarithmic)
        }
        if filter.outgoingEQFade {
            ramp(.eqMid(out), at: fadeOutStart, to: Self.loopMixFadeDecibels, over: fadeOutEnd - fadeOutStart)
            ramp(.eqHigh(out), at: fadeOutStart, to: Self.loopMixFadeDecibels, over: fadeOutEnd - fadeOutStart)
        }
        if filter.incomingLowPass {
            at(begin, .ramp(.lowPass(inc), to: Self.blendLowPassHertz, frames: 0, curve: .linear))
            ramp(.lowPass(inc), at: fadeInStart, to: MixEngine.filterCutoffRange.upperBound, over: max(0, swapAt - fadeInStart), curve: .logarithmic)
        }
        if midHandover {
            at(begin, .ramp(.eqMid(inc), to: TransitionLevel.midHandoverDecibels, frames: 0, curve: .linear))
            ramp(.eqMid(inc), at: fadeInStart, to: 0, over: max(0, swapAt - fadeInStart))
            if !filter.outgoingEQFade {
                ramp(.eqMid(out), at: fadeOutStart, to: TransitionLevel.midHandoverDecibels, over: fadeOutEnd - fadeOutStart)
            }
        }
    }

    static let echoOutFeedback = 0.68
    static let echoOutSend = 0.7
    static let echoOutIncomingHighPassHertz = 350.0
    static let echoOutCrossfadeBars = 4.0
    static let echoOutHighPassBars = 1.0
    static let echoOutLowReturnBars = 0.5
    static let echoOutLowRampBars = 2.5
    static let echoOutOutgoingLowLagBars = 0.5

    var tempoMatched: Bool {
        guard let a = input.outgoingGrid?.bpm, let b = input.incomingGrid?.bpm, a > 0, b > 0 else { return false }
        return abs(b * input.incomingRate / (a * r0) - 1) < 0.01
    }

    mutating func echoOut() {
        let throwStart = wall(0)
        let landing = wall(move.landingBar)
        let beat = beatSeconds / r0
        let bar = barSeconds / r0
        let locks = lock && tempoMatched
        at(throwStart, .echoTime(seconds: beat))
        ramp(.echoFeedback, at: throwStart, to: Self.echoOutFeedback, over: 0)
        ramp(.echoSend(out), at: throwStart, to: Self.echoOutSend, over: beat)
        startIncoming(at: landing, rate: input.incomingRate, locks: locks)
        at(landing, .ramp(.crossfadeCurve, to: 0, frames: 0, curve: .linear))
        at(landing, .ramp(.eqLow(inc), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
        at(landing, .ramp(.highPass(inc), to: Self.echoOutIncomingHighPassHertz, frames: 0, curve: .linear))
        ramp(.highPass(inc), at: landing, to: MixEngine.filterCutoffRange.lowerBound, over: Self.echoOutHighPassBars * bar, curve: .logarithmic)
        ramp(.crossfade, at: landing, to: physical(1), over: Self.echoOutCrossfadeBars * bar, curve: .smooth)
        let lowsBack = landing + Self.echoOutLowReturnBars * bar
        ramp(.eqLow(inc), at: lowsBack, to: 0, over: Self.echoOutLowRampBars * bar, curve: .smooth)
        ramp(.eqLow(out), at: lowsBack + Self.echoOutOutgoingLowLagBars * bar, to: MixEngine.bassKillDecibels, over: Self.echoOutLowRampBars * bar, curve: .smooth)
        echoTail(from: landing, bars: move.tailBars)
        if locks { at(wall(move.totalBars), .phaseUnlock(deck: inc)) }
    }

    mutating func echoTail(from seconds: TimeInterval, bars: Int) {
        guard bars > 0 else { return }
        let hold = Double(max(1, bars / 2)) * barSeconds / r1
        let fade = Double(max(1, bars - bars / 2)) * barSeconds / r1
        ramp(.echoFeedback, at: seconds + hold, to: 0, over: fade)
    }

    var riserBars: Int {
        guard input.riserGain > 0, move.usesRiser else { return 0 }
        let bars = min(Self.riserMaximumBars, move.kind == .dropIn ? move.incomingLeadBars : move.landingBar)
        return bars >= Self.riserMinimumBars ? bars : 0
    }

    mutating func riser() {
        let bars = riserBars
        guard bars > 0 else { return }
        let landingFrame = frames(wall(move.landingBar))
        let startFrame = frames(wall(move.landingBar - bars))
        let span = landingFrame - startFrame
        guard span > Self.riserReleaseFrames * 4 else { return }
        let gain = min(MixRiser.fullScale, max(0, input.riserGain)) * level.riserScale
        atFrame(startFrame, .ramp(.riserSweep, to: 0, frames: 0, curve: .linear))
        atFrame(startFrame, .ramp(.riserLevel, to: 0, frames: 0, curve: .linear))
        atFrame(startFrame, .ramp(.riserSweep, to: 1, frames: span, curve: .linear))
        atFrame(startFrame, .ramp(.riserLevel, to: gain, frames: span / 3, curve: .smooth))
        atFrame(landingFrame - Self.riserReleaseFrames, .ramp(.riserLevel, to: 0, frames: Self.riserReleaseFrames, curve: .linear))
        atFrame(landingFrame, .ramp(.riserSweep, to: 0, frames: 0, curve: .linear))
    }

    mutating func build() -> MixTimeline {
        trims()
        riser()
        switch move.kind {
        case .blend, .bridge, .jump:
            startIncoming(at: wall(0), rate: input.incomingRate, locks: lock)
            blend(from: 0, bars: max(1, move.blendBars), swapAt: move.bassSwapBar, curve: lock)
        case .loopMix:
            loopMix()
        case .breakdownExit:
            startIncoming(at: wall(0), rate: input.incomingRate, locks: lock)
            blend(from: 0, bars: max(1, move.blendBars), swapAt: move.bassSwapBar, curve: lock)
            ramp(.lowPass(out), at: wall(0), to: Self.breakdownLowPassHertz, over: wall(move.blendBars) - wall(0), curve: .logarithmic)
        case .cut:
            startIncoming(at: wall(0), rate: input.incomingRate, locks: false)
            cut(at: wall(0))
        case .echoOut:
            echoOut()
        case .dropOnTheOne:
            let landing = wall(move.landingBar)
            if move.effect == .echo, move.landingBar > 0 {
                let throwStart = max(offset0, landing - beatSeconds / r0)
                at(throwStart, .echoTime(seconds: beatSeconds / r0))
                ramp(.echoFeedback, at: throwStart, to: 0.55, over: 0)
                ramp(.echoSend(out), at: throwStart, to: 0.6, over: beatSeconds / r0 * 0.5)
            }
            startIncoming(at: landing, rate: input.incomingRate, locks: false)
            cut(at: landing)
            echoTail(from: landing, bars: move.tailBars)
        case .dropIn:
            let lead = move.landingBar
            let start = wall(lead - move.incomingLeadBars)
            let landing = wall(lead)
            startIncoming(at: start, rate: r0 * ratio, locks: lock)
            at(start, .ramp(.crossfadeCurve, to: 1, frames: 0, curve: .linear))
            ramp(.crossfade, at: start, to: physical(0.5), over: landing - start)
            ramp(.highPass(out), at: start, to: Self.dropInHighPassHertz, over: landing - start, curve: .logarithmic)
            ramp(.eqLow(out), at: landing, to: MixEngine.bassKillDecibels, over: 0.004)
            ramp(.eqLow(inc), at: landing, to: 0, over: 0.004)
            if move.blendBars > 0 {
                ramp(.crossfade, at: landing, to: physical(1), over: wall(lead + move.blendBars) - landing)
            } else {
                at(landing, .ramp(.crossfade, to: physical(1), frames: Self.cutFadeFrames, curve: .linear))
            }
        case .loopRoll:
            buildLoops()
            buildEffect(from: wall(0), to: wall(move.landingBar))
            let landing = wall(move.landingBar)
            startIncoming(at: landing, rate: input.incomingRate, locks: false)
            cut(at: landing)
            echoTail(from: landing, bars: move.tailBars)
        case .fxBuild:
            let landing = wall(move.landingBar)
            buildEffect(from: wall(0), to: landing)
            startIncoming(at: landing, rate: input.incomingRate, locks: false)
            cut(at: landing)
            echoTail(from: landing, bars: move.tailBars)
        case .tempoRamp:
            let lead = move.landingBar
            if lead > 0, abs(r1 - r0) > 1e-9 {
                ramp(.rate(out), at: wall(0), to: r1, over: wall(lead) - wall(0))
            }
            startIncoming(at: wall(lead), rate: r1 * ratio, locks: lock)
            blend(from: lead, bars: max(1, move.blendBars), swapAt: move.bassSwapBar, curve: lock)
        }

        let end = wall(move.totalBars)
        let landing = wall(move.landingBar)
        if lock, move.hasOverlap {
            at(wall(move.phraseBars), .phaseUnlock(deck: inc))
        }
        if move.hasOverlap || move.kind == .blend {
            at(wall(move.phraseBars), .ramp(.crossfadeCurve, to: 0, frames: 0, curve: .linear))
        }
        at(max(end, landing + 0.02), .ramp(.crossfade, to: physical(1), frames: 0, curve: .linear))
        at(max(end, landing + 0.02), .stop(deck: out))
        if move.kind == .loopMix { at(max(end, landing + 0.02), .clearLoop(deck: out)) }
        if guardsMids {
            let restore = (max(end, landing + 0.02) - wall(0)) * MixTimeline.midRestoreFraction
            ramp(.eqMid(inc), at: max(end, landing + 0.02) - restore, to: 0, over: restore)
        }
        timeline.lengthFrames = frames(max(end, landing + 0.02))
        let ordered = timeline.events.enumerated().sorted {
            $0.element.offset != $1.element.offset ? $0.element.offset < $1.element.offset : $0.offset < $1.offset
        }
        timeline.events = ordered.map(\.element)
        return timeline
    }

    mutating func buildLoops() {
        let startFrame = (source(0) * sr).rounded()
        var bars = 0
        var t = offset0
        for (index, rung) in move.ladder.enumerated() {
            let length = ((source(rung.bars) - source(0)) * sr).rounded()
            if index == 0 {
                at(t, .loop(deck: out, startFrame: startFrame, lengthFrames: length))
            } else {
                atFrame(frames(t) + Self.loopSettleFrames, .loop(deck: out, startFrame: startFrame, lengthFrames: length))
            }
            t += length / sr / r0 * Double(rung.passes)
            bars += rung.bars * rung.passes
        }
    }

    mutating func buildEffect(from start: TimeInterval, to landing: TimeInterval) {
        let span = max(0.01, landing - start)
        switch move.effect {
        case .none:
            break
        case .filterSweep:
            ramp(.highPass(out), at: start, to: Self.buildHighPassHertz, over: span, curve: .logarithmic)
            ramp(.resonance(out), at: start, to: 0.25, over: span)
            ramp(.reverbSend(out), at: start + span * 0.5, to: 0.35, over: span * 0.5)
        case .echo:
            at(start, .echoTime(seconds: beatSeconds / r0 / 2))
            ramp(.echoFeedback, at: start, to: 0.4, over: 0)
            ramp(.echoSend(out), at: start, to: 0.55, over: span)
            ramp(.echoFeedback, at: start + span * 0.5, to: 0.62, over: span * 0.5)
            ramp(.highPass(out), at: start + span * 0.5, to: 380, over: span * 0.5, curve: .logarithmic)
        case .reverbWash:
            ramp(.reverbSend(out), at: start, to: 0.9, over: span)
            ramp(.eqLow(out), at: start, to: -18, over: span)
            ramp(.highPass(out), at: start + span * 0.5, to: 600, over: span * 0.5, curve: .logarithmic)
        }
    }
}

extension MixTimeline {
    static func move(_ move: MixMove, _ input: MixTransitionTimelineInput) -> MixTimeline {
        var builder = MixMoveBuilder(move: move, input: input)
        return builder.build()
    }
}

struct MixDeadlineLoop: Equatable, Sendable {
    static let tailMarginSeconds: TimeInterval = 0.5
    static let preferredBars = [8, 4]

    var startSeconds: TimeInterval
    var lengthSeconds: TimeInterval
    var bars: Int

    var endSeconds: TimeInterval { startSeconds + lengthSeconds }

    static func runsOut(neededSourceSeconds: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && neededSourceSeconds > duration - tailMarginSeconds
    }

    static let instrumentalFallbackBars = [2, 1]

    static func lastCleanPhrase(
        downbeats measured: [TimeInterval],
        duration: TimeInterval,
        playhead: TimeInterval,
        vocals: [ClosedRange<TimeInterval>]? = nil,
        levels: [Float]? = nil,
        contentEnd: TimeInterval? = nil
    ) -> MixDeadlineLoop? {
        let end = contentEnd.map { min($0 + tailMarginSeconds, duration) } ?? duration
        let downbeats = measured.sorted().filter { $0 >= 0 && $0 <= end }
        guard downbeats.count >= 5, duration > 0 else { return nil }
        func instrumental(_ loop: MixDeadlineLoop) -> Bool {
            guard let vocals, !vocals.isEmpty else { return true }
            return vocalSeconds(vocals, loop.startSeconds...loop.endSeconds) < 0.05
        }
        func seamless(_ loop: MixDeadlineLoop) -> Bool {
            guard let levels else { return true }
            return seamLevelsMatch(loop, levels: levels, duration: duration)
        }
        let fallback = vocals?.isEmpty == false ? preferredBars + instrumentalFallbackBars : preferredBars
        return latest(downbeats, duration: duration, playhead: playhead, bars: fallback) { instrumental($0) && seamless($0) }
            ?? latest(downbeats, duration: duration, playhead: playhead, bars: preferredBars, accept: seamless)
            ?? latest(downbeats, duration: duration, playhead: playhead, bars: preferredBars) { _ in true }
    }

    static let seamLevelRatio: Float = 0.5

    static func seamLevelsMatch(_ loop: MixDeadlineLoop, levels: [Float], duration: TimeInterval) -> Bool {
        guard levels.count >= 8, duration > 0, loop.bars > 0 else { return true }
        let bar = loop.lengthSeconds / Double(loop.bars)
        func mean(_ from: TimeInterval, _ to: TimeInterval) -> Float {
            let lo = max(0, min(levels.count - 1, Int(from / duration * Double(levels.count))))
            let hi = max(lo + 1, min(levels.count, Int((to / duration * Double(levels.count)).rounded(.up))))
            return levels[lo..<hi].reduce(0, +) / Float(hi - lo)
        }
        let head = mean(loop.startSeconds, loop.startSeconds + bar)
        let tail = mean(loop.endSeconds - bar, loop.endSeconds)
        let louder = max(head, tail)
        guard louder > 1e-4 else { return true }
        return min(head, tail) / louder >= seamLevelRatio
    }

    static func vocalSeconds(_ vocals: [ClosedRange<TimeInterval>], _ span: ClosedRange<TimeInterval>) -> TimeInterval {
        vocals.reduce(0) { $0 + max(0, min($1.upperBound, span.upperBound) - max($1.lowerBound, span.lowerBound)) }
    }

    private static func latest(
        _ downbeats: [TimeInterval],
        duration: TimeInterval,
        playhead: TimeInterval,
        bars choices: [Int],
        accept: (MixDeadlineLoop) -> Bool
    ) -> MixDeadlineLoop? {
        let usable = duration - tailMarginSeconds
        for bars in choices where downbeats.count > bars {
            for end in stride(from: downbeats.count - 1, through: bars, by: -1) {
                let stop = downbeats[end]
                guard stop <= usable else { continue }
                guard stop > playhead + 0.05 else { break }
                let start = downbeats[end - bars]
                let length = stop - start
                let bar = length / Double(bars)
                let even = (0..<bars).allSatisfy { k in
                    abs((downbeats[end - bars + k + 1] - downbeats[end - bars + k]) - bar) < bar * 0.04
                }
                guard even else { continue }
                let loop = MixDeadlineLoop(startSeconds: start, lengthSeconds: length, bars: bars)
                if accept(loop) { return loop }
            }
        }
        return nil
    }
}

final class MixVocalMap: @unchecked Sendable {
    static let shared = MixVocalMap()
    private let lock = NSLock()
    private var entries: [(trackId: String, vocals: [ClosedRange<TimeInterval>]?, levels: [Float]?)] = []
    private let limit = 24

    func record(_ features: TrackFeatures) {
        let vocals = features.provenance.contains(.measuredVocals) ? features.vocalRanges : nil
        lock.lock()
        entries.removeAll { $0.trackId == features.trackId }
        entries.append((features.trackId, vocals, features.envelope.isEmpty ? nil : features.envelope))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
    }

    func vocals(for trackId: String?) -> [ClosedRange<TimeInterval>]? {
        guard let trackId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.trackId == trackId }?.vocals
    }

    func levels(for trackId: String?) -> [Float]? {
        guard let trackId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.trackId == trackId }?.levels
    }

    private var contentEnds: [String: TimeInterval] = [:]

    func recordContentEnd(_ seconds: TimeInterval, for trackId: String) {
        lock.lock()
        if contentEnds.count > limit * 2 { contentEnds.removeAll() }
        contentEnds[trackId] = seconds
        lock.unlock()
    }

    func contentEnd(for trackId: String?) -> TimeInterval? {
        guard let trackId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return contentEnds[trackId]
    }
}