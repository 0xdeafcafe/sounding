#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class AutoMixTimingTests: XCTestCase {

    struct Shape {
        var duration: TimeInterval = 300
        var leadingSilence: TimeInterval = 0
        var bodyEnd: TimeInterval = 260
        var outroLevel: Float = 0.45
        var outroEnd: TimeInterval? = nil
        var fadeEnd: TimeInterval? = nil
        var blip: ClosedRange<TimeInterval>? = nil
        var vocals: [ClosedRange<TimeInterval>] = [60...150]
        var loopableBars = false
    }

    static let bpm = 124.0
    static var bar: TimeInterval { 4 * 60 / bpm }

    static func features(_ id: String, _ shape: Shape) -> TrackFeatures {
        let count = Int(shape.duration)
        var envelope = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) + 0.5
            var v: Float = 0
            if t >= shape.leadingSilence, t < shape.bodyEnd {
                v = 0.8 + 0.05 * Float(sin(t))
            } else if t >= shape.bodyEnd, let fade = shape.fadeEnd, t < fade {
                v = 0.8 * Float(1 - (t - shape.bodyEnd) / (fade - shape.bodyEnd))
            } else if t >= shape.bodyEnd, let outro = shape.outroEnd, t < outro {
                v = shape.outroLevel + 0.03 * Float(sin(t))
            }
            if let blip = shape.blip, blip.contains(t) { v = 0.8 }
            envelope[i] = max(0, v)
        }
        let grid = BeatGrid(anchor: shape.leadingSilence, beatPeriod: 60 / bpm, confidence: 0.9)
        var barStarts: [TimeInterval] = []
        var profile: BarProfile?
        if shape.loopableBars {
            var t = shape.leadingSilence
            while t + bar <= shape.duration { barStarts.append(t); t += bar }
            let level = barStarts.map { start -> Float in
                let i = min(count - 1, Int(start))
                return envelope[i] > 0.01 ? 20 * log10(envelope[i]) : -90
            }
            let density = barStarts.map { start -> Float in start > shape.bodyEnd - 40 ? 0.3 : 0.9 }
            let ones = [Float](repeating: 1, count: barStarts.count)
            profile = BarProfile(level: level, density: density, loop4: ones, loop8: ones)
        }
        return TrackFeatures(
            trackId: id,
            title: id,
            artist: "artist-\(id)",
            duration: shape.duration,
            beatGrid: grid,
            keyRegions: [KeyRegion(key: CamelotKey.parse("8A")!, start: 0, end: shape.duration)],
            energyLevel: 6,
            envelope: envelope,
            vocalRanges: shape.vocals,
            provenance: [.measuredTempo, .measuredBeatGrid, .measuredDownbeats, .measuredKey, .measuredVocals],
            barProfile: profile,
            barStarts: barStarts
        )
    }

    static var incoming: TrackFeatures {
        features("in", Shape(duration: 320, bodyEnd: 300, vocals: [96...200]))
    }

    static func plan(_ outgoing: TrackFeatures, earliestExit: TimeInterval = 0, history: SetHistory = .empty, profile: DJProfile = .automaticDJ) -> PhantomDJEngine.Plan? {
        DJSessionDirector.decidePlan(
            outgoing: outgoing, candidates: [incoming], profile: profile,
            history: history, userTransitionSeconds: nil, earliestExit: earliestExit
        )
    }

    static let gateShapes: [(String, Shape)] = [
        ("trailing-silence", Shape(bodyEnd: 250)),
        ("long-fade", Shape(bodyEnd: 220, fadeEnd: 300)),
        ("long-outro", Shape(bodyEnd: 200, outroEnd: 245)),
        ("outro-then-silence", Shape(duration: 330, bodyEnd: 210, outroEnd: 260)),
        ("leading-and-trailing", Shape(leadingSilence: 30, bodyEnd: 250)),
        ("broken-silence", Shape(bodyEnd: 230, blip: 262...270)),
    ]

    // MARK: - Content bounds

    func testTrailingSilenceIsTrimmed() {
        let bounds = Self.features("a", Shape(bodyEnd: 250)).contentBounds
        XCTAssertEqual(bounds.end, 250, accuracy: 3)
        XCTAssertEqual(bounds.start, 0)
    }

    func testLeadingSilenceIsTrimmed() {
        let bounds = Self.features("a", Shape(leadingSilence: 30, bodyEnd: 280)).contentBounds
        XCTAssertEqual(bounds.start, 30, accuracy: 3)
    }

    func testBrokenSilenceAtTheEndIsTrimmed() {
        let bounds = Self.features("a", Shape(bodyEnd: 230, blip: 262...270)).contentBounds
        XCTAssertEqual(bounds.end, 230, accuracy: 3)
    }

    func testLongFadeEndsAtTheEnergyFloor() {
        let bounds = Self.features("a", Shape(bodyEnd: 220, fadeEnd: 300)).contentBounds
        XCTAssertLessThan(bounds.end, 290)
        XCTAssertGreaterThan(bounds.end, 260)
    }

    func testFullTrackIsNotTrimmed() {
        let bounds = Self.features("a", Shape(bodyEnd: 300)).contentBounds
        XCTAssertEqual(bounds.end, 300)
    }

    // MARK: - Gates

    func testGateNoMixStartInSubFloorEnergy() {
        for (name, shape) in Self.gateShapes {
            let outgoing = Self.features(name, shape)
            let bounds = outgoing.contentBounds
            guard let plan = Self.plan(outgoing) else { return XCTFail("\(name): no plan") }
            XCTAssertLessThan(plan.mixPointSeconds, bounds.end - Self.bar, "\(name): mix starts at \(plan.mixPointSeconds), content ends \(bounds.end)")
            XCTAssertTrue(bounds.isAboveFloor(outgoing, at: plan.mixPointSeconds), "\(name): mix starts in dead air at \(plan.mixPointSeconds)")
            XCTAssertGreaterThanOrEqual(plan.entrySeconds, Self.incoming.contentBounds.start - 0.5, "\(name)")
        }
    }

    func testGateLongOutroStartsAtLeastEightBarsBeforeContentEnd() {
        for (name, shape) in Self.gateShapes {
            let outgoing = Self.features(name, shape)
            let bounds = outgoing.contentBounds
            guard bounds.outroSeconds(outgoing) >= DJContentBounds.longOutroBars * Self.bar else { continue }
            guard let plan = Self.plan(outgoing) else { return XCTFail("\(name): no plan") }
            XCTAssertLessThanOrEqual(
                plan.mixPointSeconds, bounds.end - DJContentBounds.outroLeadBars * Self.bar + 0.05,
                "\(name): mix starts \(Int((bounds.end - plan.mixPointSeconds) / Self.bar)) bars before content end"
            )
        }
    }

    func testLongOutroIsDetected() {
        let outgoing = Self.features("o", Shape(bodyEnd: 200, outroEnd: 245))
        XCTAssertGreaterThanOrEqual(outgoing.contentBounds.outroSeconds(outgoing), 16 * Self.bar)
        XCTAssertNotNil(outgoing.planningView().latestMixStart)
    }

    func testLoopMixNeverLoopsDeadAir() {
        let outgoing = Self.features("loop", Shape(bodyEnd: 220, vocals: [40...120], loopableBars: true)).planningView()
        let windows = LoopMixPlanner.outgoingWindows(outgoing)
        for window in windows {
            XCTAssertLessThanOrEqual(window.endSeconds, outgoing.duration + 0.01)
            XCTAssertTrue(DJContentBounds.hasEnergy(outgoing, at: window.seconds))
        }
        XCTAssertLessThanOrEqual(outgoing.duration, 222)
    }

    // MARK: - Intros

    struct Segment {
        let bars: Int
        let level: Float
        let density: Float
        let envelope: Float
        var vocal = false
    }

    static let body = Segment(bars: 120, level: -8, density: 0.7, envelope: 0.8)

    static func introTrack(_ id: String, _ intro: [Segment], tail: [Segment]? = nil) -> TrackFeatures {
        let segments = intro + (tail ?? [body])
        var levels: [Float] = [], densities: [Float] = [], starts: [TimeInterval] = [], vocals: [ClosedRange<TimeInterval>] = []
        var envelopeBars: [Float] = []
        var t = 0.0
        for segment in segments {
            let from = t
            for _ in 0..<segment.bars {
                starts.append(t); levels.append(segment.level); densities.append(segment.density); envelopeBars.append(segment.envelope)
                t += bar
            }
            if segment.vocal { vocals.append(from...t) }
        }
        let duration = t
        let envelope = (0..<Int(duration)).map { second -> Float in
            let index = min(envelopeBars.count - 1, Int(Double(second) / bar))
            return envelopeBars[index] == 0 ? 0 : envelopeBars[index] + 0.03 * Float(sin(Double(second)))
        }
        let ones = [Float](repeating: 0.9, count: starts.count)
        let mid = duration * 0.55
        return TrackFeatures(
            trackId: id, title: id, artist: "artist-\(id)", duration: duration,
            beatGrid: BeatGrid(anchor: 0, beatPeriod: 60 / bpm, confidence: 0.9, downbeats: starts),
            keyRegions: [KeyRegion(key: CamelotKey.parse("8A")!, start: 0, end: duration)],
            energyLevel: 6, envelope: envelope,
            vocalRanges: vocals + [mid...(mid + 30)],
            provenance: [.measuredTempo, .measuredBeatGrid, .measuredDownbeats, .measuredKey, .measuredVocals],
            barProfile: BarProfile(level: levels, density: densities, loop4: ones, loop8: ones),
            barStarts: starts
        )
    }

    static let introCases: [(name: String, intro: [Segment], kind: DJIntro.Kind, skips: Bool)] = [
        ("leading-silence", [Segment(bars: 4, level: -90, density: 0, envelope: 0)], .silence, false),
        ("beatless-pad", [Segment(bars: 16, level: -14, density: 0.05, envelope: 0.4)], .beatless, true),
        ("spoken", [Segment(bars: 12, level: -14, density: 0.05, envelope: 0.4, vocal: true)], .vocal, true),
        ("long-quiet-build", [Segment(bars: 64, level: -20, density: 0.3, envelope: 0.3)], .quietBuild, true),
        ("beat-only-dj-intro", [Segment(bars: 32, level: -11, density: 0.35, envelope: 0.55)], .beatOnly, false),
        ("very-long-intro", [Segment(bars: 64, level: -9, density: 0.35, envelope: 0.7)], .long, true),
    ]

    func testIntroKinds() {
        for c in Self.introCases {
            let track = Self.introTrack(c.name, c.intro)
            let view = track.entryView()
            XCTAssertEqual(view.intro?.kind, c.kind, c.name)
            XCTAssertEqual(view.intro?.skipsIntro, c.skips, c.name)
        }
    }

    func testGateEntryIsOnAPhraseLineInsideTheGroove() {
        let outgoing = Self.features("out", Shape(bodyEnd: 250, outroLevel: 0.45, outroEnd: 280))
        for c in Self.introCases {
            let incoming = Self.introTrack(c.name, c.intro)
            let view = incoming.entryView()
            guard let plan = DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .automaticDJ, history: .empty, userTransitionSeconds: nil) else { XCTFail(c.name); continue }
            let entry = plan.entrySeconds
            XCTAssertGreaterThanOrEqual(entry, view.contentStart - 0.01, "\(c.name): entry \(entry) before \(view.contentStart)")
            XCTAssertTrue(DJContentBounds.hasEnergy(view, at: entry), "\(c.name): entry in dead air")
            let phrase = incoming.beatGrid!.phraseDuration
            let offset = entry.truncatingRemainder(dividingBy: phrase)
            XCTAssertTrue(offset < 0.05 || phrase - offset < 0.05, "\(c.name): entry \(entry) is not on a phrase line")
            if !c.skips {
                XCTAssertLessThan(entry - view.intro!.contentStart, Self.bar * 8 + 0.01, "\(c.name): kept intro skipped to \(entry)")
            }
            if c.skips {
                XCTAssertNotNil(plan.entryNote, c.name)
            }
        }
    }

    static let peakTrack = introTrack("peaks", [Segment(bars: 16, level: -16, density: 0.3, envelope: 0.45)], tail: [
        Segment(bars: 48, level: -8, density: 0.75, envelope: 0.8),
        Segment(bars: 16, level: -22, density: 0.08, envelope: 0.3),
        Segment(bars: 8, level: -15, density: 0.3, envelope: 0.5),
        Segment(bars: 48, level: -8, density: 0.75, envelope: 0.8),
        Segment(bars: 32, level: -12, density: 0.3, envelope: 0.55),
    ])

    func testGateNoExitBeforeADropOrAcrossAPeak() {
        let outgoing = Self.peakTrack
        let runs = DJMoveRails.payoffRuns(outgoing)
        XCTAssertEqual(runs.count, 2)
        let starts = outgoing.barStarts
        let lastPeakEnd = DJMoveRails.energyPayoffEnd(outgoing) ?? 0
        for incoming in [Self.introTrack("in-a", [Segment(bars: 32, level: -11, density: 0.35, envelope: 0.55)]), Self.incoming] {
            for earliest in [0.0, DJSessionDirector.earliestExit(position: 60)] {
                guard let plan = DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .automaticDJ, history: .empty, userTransitionSeconds: nil, earliestExit: earliest) else { XCTFail("no plan"); continue }
                let exit = plan.mixPointSeconds
                let end = exit + plan.transitionSeconds
                for run in runs {
                    let dropAt = starts[run.lowerBound]
                    XCTAssertFalse(dropAt > exit && dropAt < exit + 8 * Self.bar, "exit \(exit) is within 8 bars before the drop at \(dropAt)")
                }
                let meaty = DJMoveRails.meatyBars(outgoing) ?? []
                let covered = starts.indices.filter { starts[$0] >= exit - 0.1 && starts[$0] < end - 0.1 && meaty[$0] }.count
                XCTAssertLessThanOrEqual(covered, DJMoveRails.meatyBarsAllowed, "mix from \(exit) to \(end) runs over \(covered) peak bars")
                XCTAssertGreaterThanOrEqual(exit, lastPeakEnd - Self.bar - 0.1, "exit \(exit) before the last peak ends at \(lastPeakEnd)")
                XCTAssertNotEqual(plan.templateId, DJTemplates.cutOnTheOne, "a 32-bar sparse outro should carry a mix, got a cut at \(exit)")
            }
        }
    }

    static let loudBeatOutro = introTrack("loud-outro", [Segment(bars: 16, level: -16, density: 0.3, envelope: 0.45)], tail: [
        Segment(bars: 48, level: -8, density: 0.75, envelope: 0.8),
        Segment(bars: 16, level: -22, density: 0.08, envelope: 0.3),
        Segment(bars: 48, level: -8, density: 0.8, envelope: 0.8),
        Segment(bars: 32, level: -8, density: 0.7, envelope: 0.8),
    ])

    func testGateLoudBeatOnlyOutroIsAValidExit() {
        let outgoing = Self.loudBeatOutro
        let characters = DJMoveRails.barCharacters(outgoing) ?? []
        let lastDrop = DJMoveRails.payoffRuns(outgoing).last
        XCTAssertNotNil(lastDrop)
        let outroBars = (outgoing.barStarts.count - 32)..<outgoing.barStarts.count
        XCTAssertTrue(outroBars.allSatisfy { characters[$0].beatLed }, "a loud outro with no vocals is beat-led, not a peak")
        let windows = LoopMixPlanner.outgoingWindows(outgoing.planningView())
        XCTAssertFalse(windows.isEmpty, "the loud beat-only outro offers loop windows")
        let incoming = Self.introTrack("groove-in", [Segment(bars: 32, level: -10, density: 0.35, envelope: 0.6)])
        guard let plan = DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .automaticDJ, history: .empty, userTransitionSeconds: nil) else { return XCTFail("no plan") }
        XCTAssertNotEqual(plan.templateId, DJTemplates.cutOnTheOne, "a loud beat-only outro should carry a mix")
        if let drop = lastDrop {
            let dropEnd = drop.upperBound < outgoing.barStarts.count ? outgoing.barStarts[drop.upperBound] : outgoing.duration
            XCTAssertGreaterThanOrEqual(plan.mixPointSeconds, dropEnd - Self.bar - 0.1, "exit \(plan.mixPointSeconds) is inside the last drop ending \(dropEnd)")
        }
    }

    func testCutLandsOnAFullBarNotAPickup() {
        let incoming = Self.introTrack("pickup", [Segment(bars: 1, level: -20, density: 0.2, envelope: 0.3)])
        XCTAssertEqual(DJIntro.cutEntry(incoming, from: 0), incoming.barStarts[1], accuracy: 0.001)
        XCTAssertEqual(DJIntro.cutEntry(incoming, from: incoming.barStarts[4]), incoming.barStarts[4], accuracy: 0.001)
        let quietIntro = Self.introTrack("quiet-kick", [Segment(bars: 16, level: -17, density: 0.3, envelope: 0.4)])
        XCTAssertEqual(DJIntro.cutEntry(quietIntro, from: 0), quietIntro.barStarts[16], accuracy: 0.001)
    }

    func testEnergyMismatchCostsScore() {
        let outgoing = Self.features("out", Shape(bodyEnd: 250, outroLevel: 0.2, outroEnd: 290))
        let loud = Self.introTrack("loud", [])
        let quietExit = DJIntro.energyAdjustment(outgoing: outgoing.planningView(), exit: 270, incoming: loud.entryView(), entry: 0)
        let bodyExit = DJIntro.energyAdjustment(outgoing: outgoing.planningView(), exit: 100, incoming: loud.entryView(), entry: 0)
        XCTAssertLessThan(quietExit, 0)
        XCTAssertEqual(bodyExit, 0)
        XCTAssertGreaterThanOrEqual(quietExit, -DJIntro.maximumEnergyPenalty)
    }

    // MARK: - Turning Auto Mix on mid-track

    func testMidTrackPlanStartsAfterThePlayhead() {
        let outgoing = Self.features("mid", Shape(bodyEnd: 290))
        let position: TimeInterval = 240
        let earliest = DJSessionDirector.earliestExit(position: position)
        guard let plan = Self.plan(outgoing, earliestExit: earliest) else { return XCTFail("no plan") }
        XCTAssertGreaterThanOrEqual(plan.mixPointSeconds, position)
        let fresh = Self.plan(outgoing)
        XCTAssertNotNil(fresh)
    }

    func testEarliestExitIsZeroAtTheStart() {
        XCTAssertEqual(DJSessionDirector.earliestExit(position: 0), 0)
        XCTAssertEqual(DJSessionDirector.earliestExit(position: 100), 100 + DJSessionDirector.midTrackPlanningLead)
    }

    func testMidTrackHandoverWindow() {
        XCTAssertTrue(EngineHandoverPolicy.midTrackHandover(position: 100, duration: 300))
        XCTAssertTrue(EngineHandoverPolicy.midTrackHandover(position: 270, duration: 300))
        XCTAssertFalse(EngineHandoverPolicy.midTrackHandover(position: 290, duration: 300))
        let lateStep = EngineHandoverPolicy.step(
            engineReady: true, streamPlaying: true, streamPaused: false, position: 250,
            transitionAt: EngineHandoverPolicy.latestMidTrackTransition(duration: 300, barSeconds: nil),
            barSeconds: nil, leadBars: EngineHandoverPolicy.midTrackLeadBars
        )
        XCTAssertEqual(lateStep, .handOverNow)
        let streamStep = EngineHandoverPolicy.step(
            engineReady: true, streamPlaying: true, streamPaused: false, position: 250,
            transitionAt: EngineHandoverPolicy.latestTransition(duration: 300, barSeconds: nil),
            barSeconds: nil
        )
        XCTAssertEqual(streamStep, .stayOnStream)
    }

    // MARK: - Learned preferences

    static func rating(_ move: String, bars: Int, liked: Bool) -> AutoMixRating {
        AutoMixRating(date: Date(timeIntervalSince1970: 0), liked: liked, features: AutoMixTransitionFeatures(moveType: move, blendBars: bars))
    }

    func testLearnedAdjustmentIsBounded() {
        let many = (0..<80).map { _ in Self.rating("blend", bars: 32, liked: false) }
        let priors = DJLearnedPriors(ratings: many)
        let adjustment = priors.adjustment(moveType: "blend", blendBars: 32)
        XCTAssertGreaterThanOrEqual(adjustment, -DJLearnedPriors.maximumAdjustment)
        XCTAssertLessThan(adjustment, -0.05)
        XCTAssertEqual(priors.adjustment(moveType: "echoOut", blendBars: 8), 0)
    }

    func testAFewRatingsMoveLittle() {
        let priors = DJLearnedPriors(ratings: [Self.rating("echoOut", bars: 8, liked: true)])
        XCTAssertLessThanOrEqual(priors.adjustment(moveType: "echoOut", blendBars: 8), 0.015)
        XCTAssertGreaterThan(priors.adjustment(moveType: "echoOut", blendBars: 8), 0)
        XCTAssertFalse(priors.avoids(moveType: "echoOut"))
    }

    func testRepeatedDislikesAvoidAMove() {
        let priors = DJLearnedPriors(ratings: (0..<8).map { _ in Self.rating("loopMix", bars: 16, liked: false) })
        XCTAssertTrue(priors.avoids(moveType: "loopMix"))
    }

    func testLearnedPriorsNeverBreakTheContentRails() {
        var history = SetHistory.empty
        history.learned = DJLearnedPriors(ratings: (0..<200).map { _ in Self.rating("cutOnTheOne", bars: 0, liked: true) })
        for (name, shape) in Self.gateShapes {
            let outgoing = Self.features(name, shape)
            let bounds = outgoing.contentBounds
            guard let plan = Self.plan(outgoing, history: history) else { return XCTFail("\(name): no plan") }
            XCTAssertTrue(bounds.isAboveFloor(outgoing, at: plan.mixPointSeconds), "\(name)")
        }
    }

    func testPlanCarriesTransitionFeatures() {
        let plan = Self.plan(Self.features("f", Shape(bodyEnd: 250)))
        let features = plan?.feedback
        XCTAssertNotNil(features)
        XCTAssertEqual(features?.keyDistance, 0)
        XCTAssertEqual(features?.bpmDistancePercent, 0)
        XCTAssertEqual(features?.energyDelta, 0)
    }

    @MainActor
    func testRatingsPersistOnDeviceAndReset() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("automix-ratings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ratings.json")
        let store = AutoMixFeedbackStore(fileURL: url)
        store.offer(AutoMixTransitionFeatures(moveType: "blend", blendBars: 16), incomingTitle: "Next")
        XCTAssertNotNil(store.pending)
        store.rate(liked: true)
        XCTAssertNil(store.pending)
        XCTAssertEqual(store.ratings.count, 1)
        let reloaded = AutoMixFeedbackStore(fileURL: url)
        XCTAssertEqual(reloaded.ratings, store.ratings)
        XCTAssertEqual(reloaded.priors, store.priors)
        reloaded.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(reloaded.priors.isEmpty)
    }
}
#endif
