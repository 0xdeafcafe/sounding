#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class AutoMixPlannerTests: XCTestCase {

    struct BarSpec {
        var level: Float = -8
        var low: Float = -6
        var mid: Float = -8
        var tonality: Float = 2.2
        var vocal = false
        var loop: Float = 0.9
        var density: Float = 0.4
        var beats: [Float]? = nil
    }

    static let bpm = 124.0
    static var bar: TimeInterval { 240 / bpm }
    static var beat: TimeInterval { 60 / bpm }

    static let techno = GenreResolution(genre: .techno, family: .techno, confidenceValue: 0.9, source: .genreField, evidence: [], alternatives: [], bpmHint: nil)

    static func track(_ id: String, _ bars: [BarSpec], key: String = "8A", vocalsMeasured: Bool = true, genre: GenreResolution? = nil, downbeatsMeasured: Bool = true) -> TrackFeatures {
        let duration = Double(bars.count) * bar + 0.5
        let beats = stride(from: 0, to: duration + bar, by: beat).map { $0 }
        let grid = BeatGrid(anchor: 0, beatPeriod: beat, confidence: 0.92, beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, phraseOffsetBars: 0)
        let starts = Array(grid.downbeats!.prefix(bars.count))
        var vocals: [ClosedRange<TimeInterval>] = []
        var open: TimeInterval?
        for (index, spec) in bars.enumerated() {
            if spec.vocal, open == nil { open = starts[index] + 0.3 }
            if !spec.vocal, let start = open { vocals.append(start...(starts[index] - 0.3)); open = nil }
        }
        if let start = open { vocals.append(start...(duration - 1)) }
        var profile = BarProfile(
            level: bars.map(\.level), density: bars.map(\.density),
            loop4: bars.map(\.loop), loop8: bars.map(\.loop),
            bands: bars.flatMap { [$0.low / 4.343, $0.mid / 4.343, $0.mid / 4.343, $0.mid / 4.343] },
            tonality: bars.map(\.tonality)
        )
        if bars.contains(where: { $0.beats != nil }) {
            profile.beats = bars.flatMap { $0.beats ?? Array(repeating: $0.level, count: BarProfile.beatsPerBar) }
        }
        let envelope = (0..<Int(duration)).map { second -> Float in
            let index = min(bars.count - 1, Int(Double(second) / bar))
            return pow(10, bars[index].level / 20) * 2
        }
        var provenance: FeatureProvenance = [.measuredTempo, .measuredBeatGrid, .measuredDownbeats, .measuredBeatParity, .measuredKey]
        if vocalsMeasured { provenance.insert(.measuredVocals) }
        if !downbeatsMeasured { provenance.remove(.measuredDownbeats); provenance.insert(.guessedBarPhase) }
        return TrackFeatures(
            trackId: id, title: id, artist: "artist-\(id)", duration: duration, beatGrid: grid,
            keyRegions: [KeyRegion(key: CamelotKey.parse(key)!, start: 0, end: duration)],
            phraseBoundaries: stride(from: 0, to: starts.count, by: 8).map { starts[$0] },
            energyLevel: 6, envelope: envelope, genre: genre, vocalRanges: vocals,
            provenance: provenance, barProfile: profile, barStarts: starts
        )
    }

    static func outgoingBars(vocals: ClosedRange<Int>? = nil) -> [BarSpec] {
        var bars = [BarSpec](repeating: BarSpec(), count: 160)
        for b in 0..<16 { bars[b] = BarSpec(level: -20, low: -20) }
        for b in 64..<72 { bars[b] = BarSpec(level: -20, low: -22) }
        for b in 72..<88 { bars[b].density = 0.9 }
        if let vocals { for b in vocals { bars[b].vocal = true } }
        return bars
    }

    static func incomingBars() -> [BarSpec] {
        var bars = [BarSpec](repeating: BarSpec(), count: 160)
        for b in 0..<16 { bars[b] = BarSpec(level: -9, low: -26, mid: -20, tonality: 1.2) }
        return bars
    }

    static var outgoing: TrackFeatures { track("out", outgoingBars()) }
    static var incoming: TrackFeatures { track("in", incomingBars()) }
    static var club: DJProfile { DJProfile.automaticDJ.applying(blend: .normal) }

    static func downbeat(_ track: TrackFeatures, _ bar: Int) -> TimeInterval { track.barStarts[bar] }

    static func blend(exit: Int, entry: TimeInterval, bars: Int, rate: Double = 1, swapSeconds: TimeInterval? = nil, outgoing: TrackFeatures = outgoing) -> DJPlanShape {
        DJPlanShape(
            templateId: DJTemplates.bassSwapBlend, exit: downbeat(outgoing, exit), entry: entry,
            overlap: Double(bars) * bar, rate: rate, move: nil,
            bassSwapAt: Double(bars / 2) * bar, bassSwapSeconds: swapSeconds ?? beat
        )
    }

    static func loop(exit: Int, entry: TimeInterval, outLoop: Int = 4, inLoop: Int = 4, hold: Int = 16, outgoing: TrackFeatures = outgoing) -> DJPlanShape {
        let move = MixMove.loopMix(outLoop: outLoop, inLoop: inLoop, fadeIn: hold, fadeOut: 4)
        return DJPlanShape(
            templateId: DJMoveIDs.loopMix, exit: downbeat(outgoing, exit), entry: entry,
            overlap: Double(move.totalBars) * bar, rate: 1, move: move,
            bassSwapAt: Double(hold) * bar, bassSwapSeconds: beat
        )
    }

    // MARK: - Loop mix is one candidate

    func testLoopsNeverStartInADropOpening() {
        var flat = Self.outgoingBars()
        for b in 0..<flat.count { flat[b].density = 0.4 }
        let track = Self.track("flat", flat)
        let onset = Self.downbeat(track, 72)
        XCTAssertTrue(DJMoveRails.dropOnsets(track).contains { abs($0 - onset) < 0.05 }, "the energy profile marks bar 72 as a drop onset")
        XCTAssertTrue(DJMoveRails.inDropOpening(track, at: onset))
        XCTAssertTrue(DJMoveRails.inDropOpening(track, at: Self.downbeat(track, 79)))
        XCTAssertFalse(DJMoveRails.inDropOpening(track, at: Self.downbeat(track, 80)))
        let roll = DJTransitionPlan(
            templateId: DJMoveIDs.loopRoll, profileId: Self.club.id, outgoingTrackId: track.trackId, incomingTrackId: "in",
            exit: DJMoveSupport.exitPoint(track, onset, confidence: 1), entry: DJMoveSupport.entryPoint(Self.incoming, 0, confidence: 1),
            overlapSeconds: 16 * Self.bar, bassSwapAtSeconds: 0, bassSwapSeconds: Self.beat, incomingRateRatio: 1, tempoFactor: 1,
            tempoLabel: "", accent: nil, profileMinimumScore: 0, move: .loopRoll(MixMove.standardLadder)
        )
        XCTAssertNotNil(DJMoveRails.dropOpeningVeto(roll, outgoing: track))
    }

    func testLoopMixNeverReleasesIntoABreakdown() {
        var bars = Self.incomingBars()
        for b in 0..<16 { bars[b] = BarSpec(level: -9, loop: 0.95, density: 0.3) }
        for b in 20..<28 { bars[b] = BarSpec(level: -24, low: -30) }
        let incoming = Self.track("in-break", bars)
        let window = LoopMixPlanner.Window(bar: 8, bars: 8, seconds: Self.downbeat(incoming, 8), endSeconds: Self.downbeat(incoming, 16), density: 0.3, level: -9, loopability: 1)
        XCTAssertTrue(LoopMixPlanner.releaseDips(incoming, window))
        let early = LoopMixPlanner.Window(bar: 0, bars: 8, seconds: 0, endSeconds: Self.downbeat(incoming, 8), density: 0.3, level: -9, loopability: 1)
        XCTAssertFalse(LoopMixPlanner.releaseDips(incoming, early))
    }

    func testBeatLevelsCatchADipShorterThanABar() {
        var bars = Self.incomingBars()
        bars[40].beats = [-8, -8, -8, -20]
        let incoming = Self.track("in-fill", bars)
        XCTAssertEqual(incoming.barProfile?.level[40], -8, "the bar level alone misses the fill")
        XCTAssertTrue(DJContentBounds.dips(incoming, from: Self.downbeat(incoming, 39), to: Self.downbeat(incoming, 42)))
        XCTAssertFalse(DJContentBounds.dips(incoming, from: Self.downbeat(incoming, 44), to: Self.downbeat(incoming, 47)))
        let levels = DJLookAhead.Levels(incoming)
        XCTAssertEqual(levels?.level.count, bars.count * BarProfile.beatsPerBar)
        XCTAssertLessThan(levels?.relative(Self.downbeat(incoming, 40) + 3.5 * Self.beat) ?? 0, -10)
    }

    func testLookAheadReadsEightBarsPastTheHandover() {
        var bars = Self.incomingBars()
        for b in 28..<32 { bars[b] = BarSpec(level: -24, low: -30) }
        let incoming = Self.track("in-later", bars)
        let late = DJLookAhead.read(Self.blend(exit: 120, entry: 0, bars: 24), outgoing: Self.outgoing, incoming: incoming)
        XCTAssertEqual(late?.breaksSoon, true, "the incoming breaks down 4 bars after the outgoing has gone")
        let clear = DJLookAhead.read(Self.blend(exit: 120, entry: 0, bars: 24), outgoing: Self.outgoing, incoming: Self.incoming)
        XCTAssertEqual(clear?.breaksSoon, false)
    }

    func testEchoThrowNeverStartsFromAQuietBar() {
        var bars = Self.outgoingBars()
        bars[119] = BarSpec(level: -22, low: -26)
        let outgoing = Self.track("out-quiet", bars)
        XCTAssertTrue(DJPhraseCut.quietThrow(outgoing, line: Self.downbeat(outgoing, 120)))
        XCTAssertFalse(DJPhraseCut.quietThrow(outgoing, line: Self.downbeat(outgoing, 128)))
    }

    func testLookAheadSeesTheIncomingBreakAfterTheHandover() {
        var bars = Self.incomingBars()
        for b in 0..<16 { bars[b] = BarSpec() }
        for b in 16..<20 { bars[b] = BarSpec(level: -26, low: -30) }
        let incoming = Self.track("in-hole", bars)
        let into = DJLookAhead.read(Self.blend(exit: 120, entry: 0, bars: 16), outgoing: Self.outgoing, incoming: incoming)
        XCTAssertNotNil(into)
        XCTAssertGreaterThan(into?.fall ?? 0, DJLookAhead.fallDecibels, "the incoming break lands as the outgoing leaves")
        let clear = DJLookAhead.read(Self.blend(exit: 120, entry: Self.downbeat(incoming, 20), bars: 16), outgoing: Self.outgoing, incoming: incoming)
        XCTAssertLessThanOrEqual(clear?.fall ?? 99, DJLookAhead.fallDecibels)
    }

    func testLoopMixIsOneScoredCandidate() {
        let inputs = PhantomDJEngine.PlanningInputs(
            outgoing: Self.outgoing.planningView(), candidates: [Self.incoming.entryView()],
            profile: Self.club, seedComponents: ["loop-candidate"]
        )
        let result = PhantomDJEngine.rank(inputs)
        let loops = result.ranked.filter { $0.plan.move?.kind == .loopMix }
        XCTAssertFalse(loops.isEmpty, "the loop mix must be enumerated next to the blends")
        for loop in loops where loop.score > 0 {
            XCTAssertEqual(loop.rationale.templateName, "Loop mix")
            XCTAssertNil(DJPlanValidator.reason(DJPlanShape(loop.plan), outgoing: inputs.outgoing, incoming: inputs.candidates[0], profile: Self.club))
        }
        let holds = Set(loops.compactMap { $0.plan.move?.leadBars })
        XCTAssertTrue(holds.isSubset(of: Set(LoopMixPlanner.holdBars)))
        let rates = Set(loops.map { $0.plan.incomingRateRatio })
        XCTAssertFalse(rates.isEmpty)

        let chosen = PhantomDJEngine.select(result, inputs: inputs)
        let blends = result.ranked.filter { $0.fires && $0.plan.move == nil && $0.plan.templateId != DJTemplates.cutOnTheOne }
        if chosen?.move?.kind == .loopMix {
            XCTAssertGreaterThan(loops.map(\.score).max() ?? 0, blends.map(\.score).max() ?? 0)
        } else if let best = loops.filter(\.fires).map(\.score).max(), let blend = blends.map(\.score).max() {
            XCTAssertLessThanOrEqual(best, blend)
        }
    }

    func testLoopMixLeanIsANeutralNudge() {
        XCTAssertEqual(AutoMixMove.loopMix.defaultLean, .sometimes)
        XCTAssertEqual(AutoMixStyle.standard.adjustment(move: .loopMix, blendBars: 16, keySteps: 0), 0)
        var style = AutoMixStyle()
        style.setLean(.favourite, for: .loopMix)
        XCTAssertEqual(style.adjustment(move: .loopMix, blendBars: 16, keySteps: 0), AutoMixStyle.leanWeight, accuracy: 1e-9)
    }

    func testLyricLoopNeedsTheWholeLineInsideTheLoop() {
        var bars = Self.outgoingBars()
        for b in 132...133 { bars[b].vocal = true; bars[b].level = -20; bars[b].low = -20 }
        for b in 128...139 where !bars[b].vocal { bars[b].level = -20; bars[b].low = -20 }
        let lyric = Self.track("lyric", bars)
        XCTAssertNotNil(LoopMixPlanner.window(lyric, bar: 132, bars: 4), "a whole line inside a loop is allowed")
        XCTAssertNil(LoopMixPlanner.window(lyric, bar: 129, bars: 4), "a loop that ends inside the line is not")
        XCTAssertNil(LoopMixPlanner.window(lyric, bar: 133, bars: 4), "a loop that starts inside the line is not")
    }

    // MARK: - One validator

    func testValidatorPassesAnOrdinaryBlend() {
        XCTAssertNil(DJPlanValidator.reason(Self.blend(exit: 112, entry: 0, bars: 32), outgoing: Self.outgoing, incoming: Self.incoming, profile: Self.club))
    }

    func testValidatorRejectsAdversarialPlans() {
        let o = Self.outgoing, i = Self.incoming, club = Self.club
        func reason(_ shape: DJPlanShape, outgoing: TrackFeatures = o, incoming: TrackFeatures = i, profile: DJProfile? = club) -> String? {
            DJPlanValidator.reason(shape, outgoing: outgoing, incoming: incoming, profile: profile)
        }
        XCTAssertNotNil(reason(Self.loop(exit: 120, entry: 0, hold: 24)), "loops repeat for at most 16 bars")
        XCTAssertNotNil(reason(Self.blend(exit: 112, entry: 0, bars: 32, rate: 1.05)), "rate beyond the profile")
        XCTAssertNotNil(reason(Self.blend(exit: 112, entry: 0, bars: 32, swapSeconds: 2 * Self.beat)), "bass swap longer than a beat")
        XCTAssertNotNil(reason(Self.blend(exit: 72, entry: 0, bars: 16)), "mixing over the first bars of a drop")
        XCTAssertNotNil(reason(Self.blend(exit: 150, entry: 0, bars: 16)), "the outgoing would run out")
        XCTAssertNotNil(reason(Self.blend(exit: 112, entry: i.duration - 40, bars: 16)), "the incoming would run out")
        var late = i
        late.contentStart = 20
        XCTAssertNotNil(reason(Self.blend(exit: 112, entry: 0, bars: 16), incoming: late), "entering in silence")
        XCTAssertNotNil(reason(DJPlanShape(templateId: nil, exit: .nan, entry: 0, overlap: 10, rate: 1, move: nil, bassSwapAt: 0, bassSwapSeconds: 0)))
    }

    func testValidatorFollowsTheRateNotTheNominalTimeline() {
        var outBars = Self.outgoingBars()
        for b in 128...129 { outBars[b].vocal = true }
        let o = Self.track("vocal-out", outBars)
        var inBars = Self.incomingBars()
        let exit = o.barStarts[112]
        let outVocal = o.vocalRanges[0]
        let rate = 1.25
        let wall = outVocal.lowerBound - exit
        let inStart = inBars.indices.first { Double($0) * Self.bar >= wall * rate - 0.01 }!
        inBars[inStart].vocal = true
        inBars[inStart + 1].vocal = true
        let i = Self.track("vocal-in", inBars)
        let shape = Self.blend(exit: 112, entry: 0, bars: 32, rate: rate, outgoing: o)
        let nominal = DJMixRules.vocalOverlapSeconds(outgoing: o.vocalRanges, from: exit, length: shape.overlap, incoming: i.vocalRanges, entry: 0)
        XCTAssertLessThan(nominal, Self.beat, "the old linear check misses this clash")
        XCTAssertEqual(DJPlanValidator.reason(shape, outgoing: o, incoming: i, profile: nil), "the vocals would overlap")
    }

    func testValidatorFollowsTheLoopedSource() {
        var outBars = Self.outgoingBars()
        for b in 120...123 { outBars[b].level = -10; outBars[b].low = -20 }
        outBars[121].vocal = true
        let o = Self.track("loop-vocal-out", outBars)
        var inBars = Self.incomingBars()
        inBars[5].vocal = true
        let i = Self.track("loop-vocal-in", inBars)
        let shape = Self.loop(exit: 120, entry: 0, outLoop: 4, inLoop: 4, hold: 8, outgoing: o)
        let reason = DJPlanValidator.reason(shape, outgoing: o, incoming: i, profile: nil)
        XCTAssertEqual(reason, "the vocals would overlap", "the outgoing lyric repeats while the incoming sings after the release")

        var seam = Self.outgoingBars()
        for b in 122...125 { seam[b].vocal = true }
        let cut = Self.track("seam", seam)
        XCTAssertNotNil(DJPlanValidator.reason(Self.loop(exit: 120, entry: 0, outgoing: cut), outgoing: cut, incoming: Self.incoming, profile: nil))
    }

    func testEveryFinalPlanPassesTheValidator() {
        let shapes: [[BarSpec]] = [Self.outgoingBars(), Self.outgoingBars(vocals: 100...140), Self.outgoingBars(vocals: 150...159)]
        for (n, bars) in shapes.enumerated() {
            let o = Self.track("o\(n)", bars)
            for incoming in [Self.incoming, Self.track("v\(n)", Self.incomingBars().enumerated().map { k, b in var c = b; c.vocal = (20...40).contains(k); return c })] {
                guard let plan = DJSessionDirector.decidePlan(outgoing: o, candidates: [incoming], profile: Self.club, history: .empty, userTransitionSeconds: nil) else { continue }
                XCTAssertNil(DJPlanValidator.reason(plan, outgoing: o.planningView(), incoming: incoming.entryView(), profile: Self.club), "\(n): \(plan.reasoning)")
            }
        }
    }

    // MARK: - Handover-led blends

    func testAutoBlendLengthFollowsTheGenre() {
        XCTAssertEqual(Self.club.transitionBarsRange.upperBound, 48)
        XCTAssertEqual(Self.club.referenceBars(outgoing: Self.outgoing, incoming: Self.incoming), 24, "124 BPM with no genre reads as house, aimed at 0.85 of its median")
        func genre(_ g: MusicGenre, _ f: GenreFamily) -> TrackFeatures {
            TrackFeatures(trackId: g.rawValue, duration: 300, beatGrid: Self.outgoing.beatGrid, genre: GenreResolution(genre: g, family: f, confidenceValue: 0.9, source: .genreField, evidence: [], alternatives: [], bpmHint: nil))
        }
        XCTAssertEqual(DJBlendTarget.bars(outgoing: genre(.techno, .techno), incoming: genre(.techno, .techno)), 32)
        XCTAssertEqual(DJBlendTarget.bars(outgoing: genre(.trance, .trance), incoming: genre(.trance, .trance)), 32)
        XCTAssertEqual(DJBlendTarget.bars(outgoing: genre(.deepHouse, .house), incoming: genre(.deepHouse, .house)), 24)
        XCTAssertEqual(DJBlendTarget.bars(outgoing: genre(.disco, .disco), incoming: genre(.nuDisco, .disco)), 24)
        XCTAssertEqual(DJBlendTarget.bars(outgoing: genre(.hardstyle, .hardDance), incoming: genre(.hardTechno, .techno)), 32)
        let short = DJProfile.automaticDJ.applying(blend: .short)
        XCTAssertEqual(short.transitionBarsRange.upperBound, 16)
        XCTAssertEqual(short.referenceBars(outgoing: genre(.trance, .trance), incoming: nil), 16, "Short wins over the genre")
        let long = DJProfile.automaticDJ.applying(blend: .long)
        XCTAssertEqual(long.referenceBars(outgoing: genre(.disco, .disco), incoming: nil), 64, "Long wins over the genre")
    }

    func testThirtyTwoBarsWhenBothRunwaysAllow() throws {
        let arrivals = DJHandover.arrivals(Self.incoming.entryView(), profile: Self.club)
        XCTAssertEqual(arrivals.first.map { ($0 / Self.bar).rounded() }, 16, "the bass arrives on bar 16")
        let outgoing = Self.track("techno-out", Self.outgoingBars(), genre: Self.techno)
        let incoming = Self.track("techno-in", Self.incomingBars(), genre: Self.techno)
        let plan = try XCTUnwrap(DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: Self.club, history: .empty, userTransitionSeconds: nil))
        XCTAssertNotEqual(plan.templateId, DJTemplates.cutOnTheOne, plan.reasoning)
        XCTAssertEqual((plan.transitionSeconds / Self.bar).rounded(), 32, plan.reasoning)
        XCTAssertEqual((plan.bassSwapAtSeconds / Self.bar).rounded(), 16, "the swap sits mid-blend")
        XCTAssertLessThanOrEqual(plan.bassSwapSeconds, Self.beat + 0.001, "the swap takes at most a beat")
        let incomingAtSwap = plan.entrySeconds + plan.bassSwapAtSeconds * plan.incomingRateRatio
        XCTAssertEqual(incomingAtSwap, Self.incoming.barStarts[16], accuracy: Self.beat / 2, "the swap lands on the incoming's bass arrival")
    }

    func testShortIntroCapsTheBlend() throws {
        var bars = Self.incomingBars()
        for b in 8..<16 { bars[b] = BarSpec() }
        let shortIntro = Self.track("short-intro", bars)
        let plan = try XCTUnwrap(DJSessionDirector.decidePlan(outgoing: Self.outgoing, candidates: [shortIntro], profile: Self.club, history: .empty, userTransitionSeconds: nil))
        XCTAssertLessThanOrEqual((plan.transitionSeconds / Self.bar).rounded(), 24, "an 8-bar intro leaves no room for a 32-bar handover")
        XCTAssertEqual(plan.entrySeconds + plan.bassSwapAtSeconds * plan.incomingRateRatio, shortIntro.barStarts[8], accuracy: Self.beat / 2, "the swap still lands on the bass arrival")
    }

    func testPlainBlendsDoNotWaitForTheLastLabelledDrop() {
        var o = Self.outgoing
        o = TrackFeatures(
            trackId: o.trackId, title: o.title, artist: o.artist, duration: o.duration, beatGrid: o.beatGrid,
            keyRegions: o.keyRegions, sections: [TrackSection(kind: .drop, start: o.barStarts[72], end: o.barStarts[150])],
            phraseBoundaries: o.phraseBoundaries, energyLevel: 6, envelope: o.envelope, vocalRanges: o.vocalRanges,
            provenance: o.provenance.union(.measuredStructure), barProfile: o.barProfile, barStarts: o.barStarts
        )
        let payoff = DJMoveRails.payoffEnd(o) ?? 0
        XCTAssertEqual(payoff, o.barStarts[88], accuracy: 0.05, "the peak is the first 16 bars after the breakdown, not the whole labelled drop")
    }

    // MARK: - Key and level

    func testDrumsOnlyOverlapWaivesTheKeyRail() {
        let clash = Self.track("clash", Self.incomingBars(), key: "3B")
        let shape = Self.blend(exit: 112, entry: 0, bars: 8)
        let map = DJSourceMap(shape, outgoing: Self.outgoing, incoming: clash)
        XCTAssertEqual(DJMixRules.percussiveOnly(clash, sourceRanges: map.incomingOverlapRanges), true)
        XCTAssertNil(DJPlanValidator.keyReason(map, shape: shape, outgoing: Self.outgoing, incoming: clash, profile: Self.club))

        var harmonic = Self.incomingBars()
        for b in 0..<16 { harmonic[b].tonality = 3; harmonic[b].mid = -8 }
        let tonal = Self.track("tonal", harmonic, key: "3B")
        XCTAssertNotNil(DJPlanValidator.keyReason(DJSourceMap(shape, outgoing: Self.outgoing, incoming: tonal), shape: shape, outgoing: Self.outgoing, incoming: tonal, profile: Self.club))

        let unknown = Self.track("unknown", Self.incomingBars(), key: "3B", vocalsMeasured: false)
        XCTAssertNotNil(DJPlanValidator.keyReason(DJSourceMap(shape, outgoing: Self.outgoing, incoming: unknown), shape: shape, outgoing: Self.outgoing, incoming: unknown, profile: Self.club), "no evidence keeps the veto")
    }

    func testLevelGateJudgesTheResidualAfterTheTrim() {
        var loud = Self.incomingBars()
        for b in loud.indices { loud[b].level += 8 }
        let i = Self.track("loud", loud)
        let raw = abs(Self.outgoing.barProfile!.level[120] - i.barProfile!.level[0])
        XCTAssertGreaterThan(raw, LoopMixPlanner.maxLevelStepDecibels)
        let residual = DJMixRules.residualLevelStep(outgoing: Self.outgoing, outgoingLevel: Self.outgoing.barProfile!.level[120], incoming: i, incomingLevel: i.barProfile!.level[0])
        XCTAssertLessThan(residual, raw)
    }

    // MARK: - Track selection

    func testSeamFeasibilityCostsATrackThatOnlyAllowsACut() {
        var noIntro = Self.incomingBars()
        for b in 0..<16 { noIntro[b] = BarSpec() }
        let cutOnly = Self.track("cut-only", noIntro)
        XCTAssertLessThan(DJFlowSelector.seamCost(from: Self.outgoing, to: Self.incoming), DJFlowSelector.seamCost(from: Self.outgoing, to: cutOnly) + 1e-9)
        let ungridded = TrackFeatures(trackId: "no-grid", duration: 300, provenance: [.measuredTempo])
        XCTAssertEqual(DJFlowSelector.seamCost(from: Self.outgoing, to: ungridded), 0.5)
    }

    // MARK: - Beat-only grids and the echo out

    func testBeatOnlyTracksOnlyTakeLongBlends() {
        let beatOnly = Self.track("out", Self.outgoingBars(), downbeatsMeasured: false)
        XCTAssertTrue(beatOnly.isBeatOnly)
        XCTAssertFalse(Self.outgoing.isBeatOnly)
        func reason(_ shape: DJPlanShape) -> String? {
            DJPlanValidator.reason(shape, outgoing: beatOnly, incoming: Self.incoming, profile: Self.club)
        }
        XCTAssertNil(reason(Self.blend(exit: 112, entry: 0, bars: 32)))
        XCTAssertNil(reason(Self.blend(exit: 112, entry: 0, bars: 16)))
        XCTAssertNotNil(reason(Self.blend(exit: 112, entry: 0, bars: 8)), "a wrong bar shows in a short blend")
        let cut = DJPlanShape(templateId: DJTemplates.cutOnTheOne, exit: Self.downbeat(beatOnly, 112), entry: 0, overlap: 0.05, rate: 1, move: nil, bassSwapAt: 0, bassSwapSeconds: 0.05)
        XCTAssertNotNil(reason(cut))
        let echo = DJPlanShape(templateId: DJMoveIDs.echoOut, exit: Self.downbeat(beatOnly, 112), entry: 0, overlap: 5 * Self.bar, rate: 1, move: .echoOut, bassSwapAt: Self.bar, bassSwapSeconds: Self.beat)
        XCTAssertNotNil(reason(echo))
    }

    func testEchoOutFadesTheOutgoingUnderARingingTail() {
        let grid = Self.outgoing.beatGrid
        let input = MixTransitionTimelineInput(
            outgoing: 0, incoming: 1, sampleRate: 48_000, anchorSourceSeconds: Self.downbeat(Self.outgoing, 112), window: 0, entrySeconds: 0,
            outgoingRate: 1, incomingRate: 1, outgoingGrid: grid, incomingGrid: grid, stages: [],
            bassSwapAtSeconds: nil, bassSwapSeconds: nil, filterAccent: nil, defersIncomingStart: false, phaseLock: true, move: .echoOut
        )
        let timeline = MixTimeline.transition(input)
        let barFrames = Self.bar * 48_000
        func seconds(_ frames: Int64) -> Double { Double(frames) / barFrames }
        var startBar: Double?
        var fadeBars: Double?
        var feedbackDecayBar: Double?
        for event in timeline.events {
            switch event.action {
            case .start(let deck, _) where deck == 1:
                startBar = seconds(event.offset)
            case .ramp(let parameter, _, let frames, _) where parameter == .crossfade && frames > 0:
                fadeBars = seconds(frames)
            case .ramp(let parameter, let value, _, _) where parameter == .echoFeedback && value == 0:
                feedbackDecayBar = seconds(event.offset)
            default:
                break
            }
        }
        XCTAssertEqual(startBar ?? -1, 1, accuracy: 0.01, "the incoming starts on the line, a bar after the echo is thrown")
        XCTAssertEqual(fadeBars ?? 0, MixMoveBuilder.echoOutCrossfadeBars, accuracy: 0.01, "the outgoing fader comes down over four bars")
        XCTAssertGreaterThanOrEqual((feedbackDecayBar ?? 0) - 1, 2, "the tail rings at least two bars under the incoming")
        XCTAssertGreaterThanOrEqual(MixMove.echoOut.tailBars, 4)
    }
}
#endif
