#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class AutoMixFlowTests: XCTestCase {

    private func track(
        _ id: String,
        artist: String? = nil,
        key: String? = "8A",
        bpm: Double? = 124,
        energy: Int? = 6,
        family: GenreFamily? = nil,
        genre: MusicGenre = .unknown
    ) -> TrackFeatures {
        TrackFeatures(
            trackId: id,
            title: id,
            artist: artist ?? "artist-\(id)",
            duration: 300,
            beatGrid: bpm.flatMap { BeatGrid.tempoOnly($0) },
            keyRegions: key.flatMap(CamelotKey.parse).map { [KeyRegion(key: $0, start: 0, end: 300)] } ?? [],
            energyLevel: energy,
            genre: family.map {
                GenreResolution(
                    genre: genre, family: $0, confidenceValue: 0.9, source: .tags,
                    evidence: [], alternatives: [], bpmHint: nil
                )
            }
        )
    }

    private let club = DJProfile.automaticDJ

    func testCamelotVetoBeyondTwoSteps() {
        let outgoing = track("out", key: "8A")
        let clash = track("clash", key: "2A")
        let near = track("near", key: "9A")
        let veto = DJFlowSelector.stepCost(from: outgoing, to: clash, queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: [])
        XCTAssertNotNil(veto.vetoReason)
        XCTAssertEqual(DJFlowSelector.camelotDistance(outgoing, track("x", key: "8B")), 1)
        XCTAssertEqual(DJFlowSelector.camelotDistance(outgoing, track("x", key: "10A")), 2)
        XCTAssertNil(DJFlowSelector.stepCost(from: outgoing, to: track("x", key: "10A"), queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: []).vetoReason)
        XCTAssertNotNil(DJFlowSelector.stepCost(from: outgoing, to: track("x", key: "10B"), queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: []).vetoReason)

        let choice = DJFlowSelector.choose(outgoing: outgoing, candidates: [clash, near], history: .empty, profile: club, keepQueueOrder: false)
        XCTAssertEqual(choice?.trackId, "near")
        XCTAssertEqual(choice?.queueIndex, 1)
    }

    func testBeatlessTrackSkipsKeyAndTempoVeto() {
        let outgoing = track("out", key: "8A", bpm: 124)
        let ambient = track("ambient", key: "2B", bpm: 80, family: .ambient, genre: .ambient)
        XCTAssertTrue(DJFlowSelector.isBeatless(ambient))
        XCTAssertNil(DJFlowSelector.stepCost(from: outgoing, to: ambient, queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: []).vetoReason)
    }

    func testTempoIsOctaveFoldedWithinSixPercent() {
        let outgoing = track("out", bpm: 124)
        XCTAssertEqual(DJFlowSelector.tempoPercent(outgoing, track("half", bpm: 62.5))!, 0.806, accuracy: 0.01)
        XCTAssertEqual(DJFlowSelector.tempoPercent(outgoing, track("double", bpm: 250))!, 0.806, accuracy: 0.01)
        XCTAssertNil(DJFlowSelector.stepCost(from: outgoing, to: track("ok", bpm: 131), queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: []).vetoReason)
        XCTAssertNotNil(DJFlowSelector.stepCost(from: outgoing, to: track("fast", bpm: 133), queueIndex: 0, energyGoal: 6, history: .empty, recentInPath: []).vetoReason)

        let choice = DJFlowSelector.choose(
            outgoing: outgoing,
            candidates: [track("fast", bpm: 140), track("half", bpm: 62.5)],
            history: .empty, profile: club, keepQueueOrder: false
        )
        XCTAssertEqual(choice?.trackId, "half")
    }

    func testTrackCooldownVetoesRecentPlays() {
        let outgoing = track("out")
        let history = SetHistory(recentTrackIds: ["again"])
        XCTAssertNotNil(DJFlowSelector.stepCost(from: outgoing, to: track("again"), queueIndex: 0, energyGoal: 6, history: history, recentInPath: []).vetoReason)
        let choice = DJFlowSelector.choose(
            outgoing: outgoing,
            candidates: [track("again"), track("fresh", key: "9A")],
            history: history, profile: club, keepQueueOrder: false
        )
        XCTAssertEqual(choice?.trackId, "fresh")
    }

    func testArtistCooldownPrefersAnotherArtist() {
        let outgoing = track("out", artist: "Same")
        let choice = DJFlowSelector.choose(
            outgoing: outgoing,
            candidates: [track("a", artist: "Same"), track("b", artist: "Other")],
            history: .empty, profile: club, keepQueueOrder: false
        )
        XCTAssertEqual(choice?.trackId, "b")

        let earlier = DJFlowSelector.choose(
            outgoing: track("out"),
            candidates: [track("a", artist: "Played"), track("b", artist: "Other")],
            history: SetHistory(recentArtists: ["Played"]), profile: club, keepQueueOrder: false
        )
        XCTAssertEqual(earlier?.trackId, "b")
    }

    func testEnergyFollowsTheArc() {
        XCTAssertEqual(DJFlowSelector.arc(from: 4, target: 9, steps: 3, stepLimit: 2), [6, 8, 9])
        XCTAssertEqual(DJFlowSelector.arc(from: 7, target: 3, steps: 3, stepLimit: 1), [6, 5, 4])
        XCTAssertEqual(DJFlowSelector.arc(from: 5, target: nil, steps: 2, stepLimit: 2), [5, 5])

        let outgoing = track("out", energy: 5)
        let calm = track("calm", energy: 4)
        let lift = track("lift", energy: 7)
        let up = DJFlowSelector.choose(outgoing: outgoing, candidates: [calm, lift], history: SetHistory(energyTarget: 9), profile: club, keepQueueOrder: false)
        XCTAssertEqual(up?.trackId, "lift")
        let down = DJFlowSelector.choose(outgoing: outgoing, candidates: [lift, calm], history: SetHistory(energyTarget: 2), profile: club, keepQueueOrder: false)
        XCTAssertEqual(down?.trackId, "calm")
    }

    func testQueueFirstWhenEverythingFits() {
        let outgoing = track("out")
        let choice = DJFlowSelector.choose(
            outgoing: outgoing,
            candidates: [track("one"), track("two"), track("three")],
            history: .empty, profile: club, keepQueueOrder: false
        )
        XCTAssertEqual(choice?.trackId, "one")
        XCTAssertEqual(choice?.isReordered, false)
    }

    func testKeepQueueOrderNeverReorders() {
        let outgoing = track("out", key: "8A")
        let candidates = [track("clash", key: "2A", bpm: 150), track("near", key: "9A")]
        let choice = DJFlowSelector.choose(outgoing: outgoing, candidates: candidates, history: SetHistory(recentTrackIds: ["clash"]), profile: club, keepQueueOrder: true)
        XCTAssertEqual(choice?.trackId, "clash")
        XCTAssertEqual(choice?.queueIndex, 0)

        XCTAssertFalse(DJFlowSelector.mayReorder(keepQueueOrder: true, explicitOrders: [.mayReorder]))
        XCTAssertFalse(DJFlowSelector.mayReorder(keepQueueOrder: false, explicitOrders: [nil, .preserve]))
        XCTAssertFalse(DJFlowSelector.mayReorder(keepQueueOrder: false, explicitOrders: [.random]))
        XCTAssertTrue(DJFlowSelector.mayReorder(keepQueueOrder: false, explicitOrders: [nil, .mayReorder]))

        let preserving = club.applying(queueOrder: .preserve)
        let plan = DJSessionDirector.decideFlowPlan(outgoing: outgoing, candidates: candidates, profile: preserving, history: .empty, userTransitionSeconds: nil)
        XCTAssertEqual(plan?.selection?.trackId, "clash")
        XCTAssertNotEqual(plan?.incomingTrackId, "near")

        let flowing = club.applying(queueOrder: .mayReorder)
        XCTAssertEqual(flowing.lookaheadCandidates, 12)
        let flowPlan = DJSessionDirector.decideFlowPlan(outgoing: outgoing, candidates: candidates, profile: flowing, history: .empty, userTransitionSeconds: nil)
        XCTAssertEqual(flowPlan?.selection?.trackId, "near")
        XCTAssertEqual(flowPlan?.incomingTrackId, "near")
        XCTAssertEqual(flowPlan?.titled("Near").selection?.trackId, "near")
    }

    func testBeamLooksAhead() {
        let outgoing = track("out", key: "8A", energy: 5)
        let dead = track("dead", key: "9A", energy: 7)
        let bridge = track("bridge", key: "8A", energy: 6)
        let far = track("far", key: "3A", energy: 7)
        let choice = DJFlowSelector.choose(outgoing: outgoing, candidates: [dead, bridge, far], history: SetHistory(energyTarget: 7), profile: club, keepQueueOrder: false)
        XCTAssertNotNil(choice)
        XCTAssertEqual(choice?.path.count, 2)
        XCTAssertFalse(choice!.path.contains("far"))
    }

    func testWhyString() {
        let why = DJFlowSelector.why(from: track("a", bpm: 124, energy: 5), to: track("b", bpm: 126, energy: 7), energyGoal: 7)
        XCTAssertEqual(why, "Same key · 124 → 126 BPM · energy up")
        XCTAssertEqual(DJFlowSelector.why(from: track("a", key: nil, bpm: nil, energy: nil), to: track("b"), energyGoal: nil), "Next in the queue")
        XCTAssertEqual(DJFlowSelector.why(from: track("a", key: nil, bpm: nil, energy: 6), to: track("b", key: nil, bpm: nil, energy: 6), energyGoal: nil), "Energy holds")
    }

    func testRecentPlaysDeduplicates() {
        let recent = DJSessionDirector.recentPlays(
            log: [(id: "b", artist: "B"), (id: "a", artist: "A")],
            queueHistory: [(id: "a", artist: "A"), (id: "z", artist: "Z")]
        )
        XCTAssertEqual(recent.map(\.id), ["b", "a", "z"])
    }

    func testBlendMapsToBars() {
        XCTAssertEqual(DJBlendLength.allCases.map(\.bars), [16, 32, 64])
        XCTAssertEqual(DJProfile.weddingDJ.applying(blend: .short).transitionBarsRange, 8...16)
        XCTAssertEqual(DJProfile.weddingDJ.applying(blend: .normal).transitionBarsRange, 8...48)
        XCTAssertEqual(DJProfile.automaticDJ.applying(blend: .normal).transitionBarsRange, 8...48)
        XCTAssertEqual(DJProfile.automaticDJ.applying(blend: .long).transitionBarsRange, 8...64)
        XCTAssertEqual(DJProfile.junkie.applying(blend: .short).transitionBarsRange, 4...16)
        XCTAssertEqual(DJProfile.automaticDJ.applying(blend: .short).blendTargetBars, 16)
        XCTAssertEqual(DJProfile.automaticDJ.applying(blend: .long).blendTargetBars, 64)
        XCTAssertNil(DJProfile.automaticDJ.applying(blend: .normal).blendTargetBars, "Auto follows the genre")
        XCTAssertEqual(DJProfile.all.map(\.styleName), ["Club", "Smooth", "Adventurous"])
    }
}
#endif
