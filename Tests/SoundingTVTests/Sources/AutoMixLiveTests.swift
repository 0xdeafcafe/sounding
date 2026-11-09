import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class AutoMixLiveTests: XCTestCase {

    private func state(stage: AutoMixLiveState.Stage, startsIn seconds: TimeInterval, at now: Date) -> AutoMixLiveState {
        let move = MixMove.loopRoll(MixMove.standardLadder)
        let shape = AutoMixLive.phases(for: move, lengthBars: move.totalBars, bassSwapBar: nil)
        return AutoMixLiveState(
            stage: stage, moveKind: move.kind.rawValue, moveName: move.displayName,
            headline: move.headline(into: "Glue"), incomingTitle: "Glue",
            startsAt: now.addingTimeInterval(seconds), barSeconds: 2, landingBar: move.landingBar,
            lengthBars: move.totalBars, phases: shape.phases, riserStartBar: shape.riserStart,
            crossfade: 0, anchoredAt: now, isPlaying: true
        )
    }

    @MainActor
    func testLoopBuildPhasesHalve() {
        let move = MixMove.loopRoll(MixMove.standardLadder)
        let shape = AutoMixLive.phases(for: move, lengthBars: move.totalBars, bassSwapBar: nil)
        XCTAssertEqual(shape.phases.map(\.name), ["Loop 8 bars", "Loop 4 bars", "Loop 2 bars", "Loop 1 bar", "Loop 1 bar", "Drop"])
        XCTAssertEqual(shape.phases.last?.startBar, Double(move.landingBar))
        XCTAssertEqual(shape.riserStart, Double(move.landingBar - 8))
    }

    @MainActor
    func testBlendHasBassSwap() {
        let shape = AutoMixLive.phases(for: .blend(bars: 16, swapAt: 8), lengthBars: 16, bassSwapBar: nil)
        XCTAssertEqual(shape.phases.map(\.name), ["Blend in", "Bass swap", "Blend out"])
        XCTAssertEqual(shape.phases.reduce(0) { $0 + $1.bars }, 16)
        XCTAssertNil(shape.riserStart)
    }

    @MainActor
    func testCountdownTicksInBarsThenBeats() {
        let now = Date()
        let upcoming = state(stage: .upcoming, startsIn: 32, at: now)
        XCTAssertEqual(upcoming.clock(at: now).barsUntilStart, 16)
        XCTAssertEqual(upcoming.clock(at: now).countdownText, "in 16 bars")
        XCTAssertEqual(upcoming.clock(at: now.addingTimeInterval(30.6)).countdownText, "in 3 beats")
    }

    @MainActor
    func testClockFindsPhaseDuringMix() {
        let now = Date()
        let mixing = state(stage: .mixing, startsIn: -2 * 9.5, at: now)
        let clock = mixing.clock(at: now)
        XCTAssertEqual(clock.phase?.name, "Loop 4 bars")
        XCTAssertEqual(clock.barInMove, 9.5, accuracy: 0.001)
        XCTAssertTrue(clock.isRiser)
    }

    @MainActor
    func testRoundTripsThroughData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let value = state(stage: .upcoming, startsIn: 10, at: now)
        XCTAssertEqual(AutoMixLiveState.decode(value.encoded()), value)
    }

    func testDJStatePayloadStaysCompatible() throws {
        let deck = DJDeckStatePayload(
            trackId: "a", title: nil, artist: nil, positionSeconds: 1, durationSeconds: 2, isPlaying: true,
            eqLowDb: 0, eqMidDb: 0, eqHighDb: 0, filterCutoffHz: 20_000, filterResonance: 0, rate: 1,
            bpm: nil, loopStartSeconds: nil, loopLengthSeconds: nil
        )
        let secret = Data(repeating: 7, count: 32)
        let live = Data("{\"x\":1}".utf8)
        let payload = DJStatePayload.create(
            isEnabled: true, isEngineLive: true, isAutoMixEnabled: true, crossfade: 0.5,
            deckA: deck, deckB: deck, automaticMix: nil, live: live, revision: 3, sessionId: "s", secret: secret
        )
        XCTAssertTrue(payload.verify(sessionId: "s", secret: secret))
        XCTAssertEqual(payload.verifiedLive(sessionId: "s", secret: secret), live)
        XCTAssertNil(payload.verifiedLive(sessionId: "s", secret: Data(repeating: 8, count: 32)))

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        json.removeValue(forKey: "live")
        json.removeValue(forKey: "liveSignature")
        let old = try JSONDecoder().decode(DJStatePayload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.verify(sessionId: "s", secret: secret))
        XCTAssertNil(old.verifiedLive(sessionId: "s", secret: secret))
    }
}
