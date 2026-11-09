#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class AutoMixStyleTests: XCTestCase {

    typealias T = AutoMixTimingTests

    static var pairs: [(name: String, outgoing: TrackFeatures, incoming: TrackFeatures)] {
        var out: [(String, TrackFeatures, TrackFeatures)] = []
        for (name, shape) in T.gateShapes {
            out.append((name, T.features(name, shape), T.incoming))
            for c in T.introCases {
                out.append(("\(name)→\(c.name)", T.features(name, shape), T.introTrack(c.name, c.intro)))
            }
        }
        out.append(("peaks", T.peakTrack, T.incoming))
        out.append(("loud-outro", T.loudBeatOutro, T.introTrack("groove-in", [T.Segment(bars: 32, level: -10, density: 0.35, envelope: 0.6)])))
        return out
    }

    static func style(_ leans: [AutoMixMove: AutoMixLean], nudges: AutoMixNudges = AutoMixNudges()) -> AutoMixStyle {
        var style = AutoMixStyle()
        for (move, lean) in leans { style.setLean(lean, for: move) }
        style.nudges = nudges
        return style
    }

    static let cutsEverything = style(
        Dictionary(uniqueKeysWithValues: AutoMixMove.allCases.map { ($0, $0 == .quickCut ? AutoMixLean.favourite : .rarely) }),
        nudges: AutoMixNudges(move: .quickCut, moveMixes: 5, blendBars: 4, blendMixes: 5, keySteps: 1, keyMixes: 5)
    )

    static let blendsEverything = style(
        Dictionary(uniqueKeysWithValues: AutoMixMove.allCases.map { ($0, $0 == .longBlend ? AutoMixLean.favourite : .rarely) }),
        nudges: AutoMixNudges(move: .longBlend, moveMixes: 5, blendBars: 32, blendMixes: 5, keySteps: 0, keyMixes: 5)
    )

    static func history(_ style: AutoMixStyle) -> SetHistory {
        var history = SetHistory.empty
        history.style = style
        return history
    }

    static func ranked(_ pair: (name: String, outgoing: TrackFeatures, incoming: TrackFeatures), _ style: AutoMixStyle) -> [ScoredPlan] {
        PhantomDJEngine.rank(.init(
            outgoing: pair.outgoing.planningView(),
            candidates: [pair.incoming.entryView()],
            profile: .automaticDJ,
            history: history(style),
            seedComponents: ["style", pair.name]
        )).ranked
    }

    static func family(_ plan: DJTransitionPlan) -> AutoMixMove? {
        AutoMixMove.of(templateId: plan.templateId, move: plan.move)
    }

    static func key(_ plan: DJTransitionPlan) -> String {
        "\(plan.templateId.rawValue)|\(plan.incomingTrackId)|\(Int(plan.exit.seconds * 100))|\(Int(plan.entry.seconds * 100))|\(Int(plan.overlapSeconds * 100))|\(plan.move?.kind.rawValue ?? "-")"
    }

    // MARK: - Mapping

    func testDefaultStyleIsNeutral() {
        let style = AutoMixStyle.standard
        for move in AutoMixMove.allCases + [nil] {
            for bars in AutoMixTransitionFeatures.blendBuckets {
                for steps in [nil, 0, 1, 3] {
                    XCTAssertEqual(style.adjustment(move: move, blendBars: bars, keySteps: steps), 0)
                }
            }
        }
        XCTAssertEqual(style.allowedMidTrackMoves, Set(MixPerformanceMove.Kind.allCases))
    }

    func testEveryPlannerMoveHasAFamily() {
        for kind in MixMove.Kind.allCases where kind != .jump {
            XCTAssertNotNil(AutoMixMove.of(moveType: kind.rawValue), kind.rawValue)
        }
        for id in DJProfile.automaticDJ.admissibleTemplates {
            XCTAssertNotNil(AutoMixMove.of(moveType: id.rawValue), id.rawValue)
        }
        XCTAssertEqual(AutoMixMove.of(templateId: DJMoveIDs.echoBuild, move: .fxBuild(.echo, bars: 4)), .echoOut)
        XCTAssertEqual(AutoMixMove.of(templateId: DJMoveIDs.filterBuild, move: .fxBuild(.filterSweep, bars: 4)), .filterFade)
    }

    func testPreferenceAdjustmentIsClampedAndCombinedWithLearning() {
        let extreme = Self.cutsEverything
        XCTAssertEqual(extreme.adjustment(move: .quickCut, blendBars: 4, keySteps: 0), AutoMixStyle.maximumAdjustment, accuracy: 1e-9)
        XCTAssertEqual(extreme.adjustment(move: .longBlend, blendBars: 32, keySteps: 3), -AutoMixStyle.maximumAdjustment, accuracy: 1e-9)
        XCTAssertEqual(AutoMixStyle.personalAdjustment(learned: 0.06, style: 0.08), AutoMixStyle.maximumPersonalAdjustment)
        XCTAssertEqual(AutoMixStyle.personalAdjustment(learned: -0.06, style: -0.08), -AutoMixStyle.maximumPersonalAdjustment)
        XCTAssertEqual(AutoMixStyle.personalAdjustment(learned: 0.03, style: -0.02), 0.01, accuracy: 1e-9)
    }

    func testLoopMixLeanIsAScoreNudgeLikeEveryOtherMove() {
        func nudge(_ lean: AutoMixLean) -> Double {
            Self.style([.loopMix: lean]).adjustment(move: .loopMix, blendBars: 16, keySteps: 0)
        }
        XCTAssertEqual(nudge(.sometimes), 0)
        XCTAssertGreaterThan(nudge(.favourite), 0)
        XCTAssertLessThan(nudge(.rarely), 0)
    }

    func testMidTrackMovesFollowTheToggles() {
        var style = AutoMixStyle()
        style.setAllowed(false, .echoThrow)
        style.setAllowed(false, .lowPassDip)
        XCTAssertEqual(style.allowedMidTrackMoves, [.loopRoll, .highPassBuild])
        let data = try! JSONEncoder().encode(style)
        XCTAssertEqual(try! JSONDecoder().decode(AutoMixStyle.self, from: data), style)
    }

    func testHourStripFollowsTheLeans() {
        let style = AutoMixStyle.standard
        let hour = style.hour(count: 10)
        XCTAssertEqual(hour.count, 10)
        let counts = Dictionary(grouping: hour, by: { $0 }).mapValues(\.count)
        XCTAssertGreaterThan(counts[.longBlend] ?? 0, counts[.loopMix] ?? 0)
        XCTAssertLessThanOrEqual(abs((counts[.loopMix] ?? 0) - (counts[.filterFade] ?? 0)), 1, "the loop mix is one neutral candidate")
        XCTAssertGreaterThanOrEqual(counts[.filterFade] ?? 0, counts[.quickCut] ?? 0)
        XCTAssertEqual(style.hourSummary, "Mostly long blends, with the odd loop mix, filter fade or drop-in.")
        XCTAssertNotEqual(hour.first, hour.dropFirst().first)
    }

    // MARK: - Choice distribution

    func testPreferencesShiftTheMoveChoice() {
        var neutralCuts = 0, favouredCuts = 0, neutralBlends = 0, favouredBlends = 0
        var cutGapNeutral = 0.0, cutGapFavoured = 0.0, comparisons = 0
        for pair in Self.pairs {
            let neutral = Self.ranked(pair, .standard)
            let cuts = Self.ranked(pair, Self.cutsEverything)
            let blends = Self.ranked(pair, Self.blendsEverything)
            if let top = neutral.first(where: { $0.score > 0 }) {
                if Self.family(top.plan) == .quickCut { neutralCuts += 1 }
                if Self.family(top.plan) == .longBlend { neutralBlends += 1 }
            }
            if let top = cuts.first(where: { $0.score > 0 }), Self.family(top.plan) == .quickCut { favouredCuts += 1 }
            if let top = blends.first(where: { $0.score > 0 }), Self.family(top.plan) == .longBlend { favouredBlends += 1 }
            func gap(_ ranked: [ScoredPlan]) -> Double? {
                guard let best = ranked.first(where: { $0.score > 0 })?.score,
                      let cut = ranked.first(where: { $0.score > 0 && Self.family($0.plan) == .quickCut })?.score else { return nil }
                return best - cut
            }
            if let a = gap(neutral), let b = gap(cuts) {
                cutGapNeutral += a
                cutGapFavoured += b
                comparisons += 1
            }
        }
        XCTAssertGreaterThan(comparisons, 0)
        XCTAssertLessThan(cutGapFavoured, cutGapNeutral, "Quick Cut as a favourite should close the gap to the best plan")
        XCTAssertGreaterThan(favouredCuts, neutralCuts, "Quick Cut as a favourite should win more often (\(neutralCuts) → \(favouredCuts) of \(Self.pairs.count))")
        XCTAssertGreaterThanOrEqual(favouredBlends, neutralBlends, "Long Blend as a favourite should not win less often (\(neutralBlends) → \(favouredBlends))")
    }

    // MARK: - Hard rules always win

    func testExtremePreferencesNeverReviveAVetoedPlan() {
        for style in [Self.cutsEverything, Self.blendsEverything] {
            for pair in Self.pairs {
                let neutral = Self.ranked(pair, .standard)
                let preferred = Dictionary(Self.ranked(pair, style).map { (Self.key($0.plan), $0.score) }, uniquingKeysWith: { a, _ in a })
                for plan in neutral where plan.score == 0 {
                    if let score = preferred[Self.key(plan.plan)] {
                        XCTAssertEqual(score, 0, "\(pair.name): \(plan.rationale.headline) was vetoed and came back at \(score)")
                    }
                }
            }
        }
    }

    func testGateQuickCutFavouriteNeverCutsMidVocal() {
        let history = Self.history(Self.cutsEverything)
        for pair in Self.pairs {
            guard let plan = DJSessionDirector.decidePlan(outgoing: pair.outgoing, candidates: [pair.incoming], profile: .automaticDJ, history: history, userTransitionSeconds: nil) else {
                XCTFail("\(pair.name): no plan"); continue
            }
            let exit = plan.mixPointSeconds
            let inside = pair.outgoing.vocalRanges.contains { exit > $0.lowerBound + 0.1 && exit < $0.upperBound - 0.1 }
            XCTAssertFalse(inside, "\(pair.name): mixes out at \(exit) inside a vocal")
            let entryInside = pair.incoming.vocalRanges.contains { plan.entrySeconds > $0.lowerBound + 0.1 && plan.entrySeconds < $0.upperBound - 0.1 }
            XCTAssertFalse(entryInside, "\(pair.name): lands at \(plan.entrySeconds) inside a vocal")
            XCTAssertLessThanOrEqual(plan.feedback?.vocalOverlapSeconds ?? 0, 0.05, "\(pair.name): two vocals at once")
            XCTAssertTrue(pair.outgoing.contentBounds.isAboveFloor(pair.outgoing, at: exit), "\(pair.name): exit in sub-floor energy")
        }
    }

    func testGateExtremePreferencesKeepThePeakAndPhraseRails() {
        let outgoing = T.peakTrack
        let runs = DJMoveRails.payoffRuns(outgoing)
        let starts = outgoing.barStarts
        let lastPeakEnd = DJMoveRails.energyPayoffEnd(outgoing) ?? 0
        let meaty = DJMoveRails.meatyBars(outgoing) ?? []
        for style in [Self.cutsEverything, Self.blendsEverything] {
            for incoming in [T.introTrack("in-a", [T.Segment(bars: 32, level: -11, density: 0.35, envelope: 0.55)]), T.incoming] {
                guard let plan = DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .automaticDJ, history: Self.history(style), userTransitionSeconds: nil) else {
                    XCTFail("no plan"); continue
                }
                let exit = plan.mixPointSeconds
                let end = exit + plan.transitionSeconds
                for run in runs {
                    let dropAt = starts[run.lowerBound]
                    XCTAssertFalse(dropAt > exit && dropAt < exit + 8 * T.bar, "exit \(exit) is within 8 bars before the drop at \(dropAt)")
                }
                let covered = starts.indices.filter { starts[$0] >= exit - 0.1 && starts[$0] < end - 0.1 && meaty[$0] }.count
                XCTAssertLessThanOrEqual(covered, DJMoveRails.meatyBarsAllowed, "mix from \(exit) to \(end) runs over \(covered) peak bars")
                XCTAssertGreaterThanOrEqual(exit, lastPeakEnd - T.bar - 0.1, "exit \(exit) before the last peak ends at \(lastPeakEnd)")
                let bar = outgoing.beatGrid!.barDuration
                let offset = exit.truncatingRemainder(dividingBy: bar)
                XCTAssertTrue(offset < 0.05 || bar - offset < 0.05, "exit \(exit) is off the bar")
            }
        }
        for c in T.introCases {
            let incoming = T.introTrack(c.name, c.intro)
            for style in [Self.cutsEverything, Self.blendsEverything] {
                guard let plan = DJSessionDirector.decidePlan(outgoing: T.features("out", T.Shape(bodyEnd: 250, outroLevel: 0.45, outroEnd: 280)), candidates: [incoming], profile: .automaticDJ, history: Self.history(style), userTransitionSeconds: nil) else {
                    XCTFail(c.name); continue
                }
                let phrase = incoming.beatGrid!.phraseDuration
                let offset = plan.entrySeconds.truncatingRemainder(dividingBy: phrase)
                XCTAssertTrue(offset < 0.05 || phrase - offset < 0.05, "\(c.name): entry \(plan.entrySeconds) is not on a phrase line")
                XCTAssertTrue(DJContentBounds.hasEnergy(incoming.entryView(), at: plan.entrySeconds), "\(c.name): entry in dead air")
            }
        }
    }

    // MARK: - Flair

    static func rating(_ move: String, _ bars: Int, _ liked: Bool) -> AutoMixRating {
        AutoMixRating(date: Date(timeIntervalSince1970: 0), liked: liked, features: AutoMixTransitionFeatures(moveType: move, blendBars: bars))
    }

    func testFlairOnlySpeaksWithEnoughEvidence() {
        XCTAssertTrue(AutoMixFlair.lines(ratings: [Self.rating("loopMix", 16, true), Self.rating("loopMix", 16, true)], nudges: AutoMixNudges()).isEmpty)
        let mixed = (0..<3).map { _ in Self.rating("echoOut", 0, true) } + (0..<3).map { _ in Self.rating("echoOut", 0, false) }
        XCTAssertTrue(AutoMixFlair.lines(ratings: mixed, nudges: AutoMixNudges()).isEmpty)
        let lines = AutoMixFlair.lines(ratings: AutoMixFlair.fixtureRatings(), nudges: AutoMixFlair.fixtureNudges)
        XCTAssertEqual(lines.map(\.text), ["You like long loop mixes", "Echo outs aren’t for you", "You keep it in key"])
        XCTAssertEqual(lines.map(\.evidence), ["9 Nice", "4 Not Great", "2 Saved Mixes"])
    }

    func testForgettingAFlairLineRemovesItsEvidence() {
        let ratings = AutoMixFlair.fixtureRatings()
        let line = AutoMixFlair.lines(ratings: ratings, nudges: AutoMixNudges()).first { $0.id == "move.echoOut" }!
        let kept = ratings.filter { !AutoMixFlair.matches($0, line.source) }
        XCTAssertFalse(AutoMixFlair.lines(ratings: kept, nudges: AutoMixNudges()).contains { $0.id == line.id })
        XCTAssertFalse(DJLearnedPriors(ratings: kept).avoids(moveType: "echoOut"))
        let cleared = AutoMixFlair.forgetting(.nudgedKey, in: AutoMixFlair.fixtureNudges)
        XCTAssertTrue(cleared.isEmpty)
    }

    @MainActor
    func testSavedMixTraitsBecomeNudges() {
        let entries = MixHistoryStore.fixtureEntries()
        let traits = AutoMixFlair.traits(of: entries[0])
        XCTAssertEqual(traits.move, .loopMix)
        XCTAssertEqual(traits.keySteps, 0)
        var nudges = AutoMixNudges()
        nudges.learn(move: traits.move, blendBars: traits.blendBars, keySteps: traits.keySteps)
        nudges.learn(move: traits.move, blendBars: traits.blendBars, keySteps: traits.keySteps)
        XCTAssertEqual(nudges.moveMixes, 2)
        XCTAssertEqual(nudges.keyMixes, 2)
        var style = AutoMixStyle()
        style.nudges = nudges
        XCTAssertGreaterThan(style.adjustment(move: .loopMix, blendBars: traits.blendBars ?? 16, keySteps: 0), 0)
        XCTAssertLessThan(style.adjustment(move: .echoOut, blendBars: 0, keySteps: 3), 0)
    }
}
#endif
