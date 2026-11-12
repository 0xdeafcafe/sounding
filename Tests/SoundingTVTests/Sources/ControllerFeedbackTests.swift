import Foundation
import XCTest
@testable import SoundingTV

final class ControllerFeedbackTests: XCTestCase {
    private let mapping = ControllerProfiles.pioneerDDJ400.feedback

    private func loaded(_ change: (inout DeckFeedbackState) -> Void = { _ in }) -> DeckFeedbackState {
        var state = DeckFeedbackState()
        state.isLoaded = true
        state.duration = 240
        change(&state)
        return state
    }

    private func value(_ desired: [ControllerFeedbackKey: ControllerFeedbackValue], _ type: ControllerMapping.MessageType, _ channel: UInt8, _ number: UInt8) -> UInt16? {
        desired[ControllerFeedbackKey(midi: type, channel: channel, number: number)]?.message.value
    }

    // MARK: Mapping

    func testDDJ400FeedbackTableIsValid() {
        XCTAssertEqual(mapping.problems, [])
        XCTAssertEqual(mapping.outputs.count, 30)
        XCTAssertEqual(mapping.outputs.filter { $0.signal.isContinuous }.count, 2)
    }

    func testProblemsCatchDuplicatesAndBadPads() {
        let broken = ControllerFeedbackMapping(outputs: [
            .led(0, 0x0B, .a, .play),
            .led(0, 0x0B, .a, .cue),
            .led(16, 0x01, .a, .loop),
            .led(0, 0x02, .a, .hotCue(9)),
        ])
        XCTAssertEqual(broken.problems.count, 3)
    }

    // MARK: Lights

    func testPlayLightsWhilePlayingAndBlinksWhilePaused() {
        let playing = ControllerFeedbackRenderer.render(mapping, states: [.a: loaded { $0.isPlaying = true }], clock: 0.75)
        XCTAssertEqual(value(playing, .note, 0, 0x0B), 0x7F)

        let pausedOn = ControllerFeedbackRenderer.render(mapping, states: [.a: loaded()], clock: 0.25)
        let pausedOff = ControllerFeedbackRenderer.render(mapping, states: [.a: loaded()], clock: 0.75)
        XCTAssertEqual(value(pausedOn, .note, 0, 0x0B), 0x7F)
        XCTAssertEqual(value(pausedOff, .note, 0, 0x0B), 0)
        XCTAssertEqual(value(pausedOff, .note, 0, 0x0C), 0x7F)

        let empty = ControllerFeedbackRenderer.render(mapping, states: [:], clock: 0.25)
        XCTAssertEqual(value(empty, .note, 0, 0x0B), 0)
        XCTAssertEqual(value(empty, .note, 0, 0x0C), 0)
    }

    func testSyncLoopAndPadsFollowTheirDeck() {
        let states: [MixEngine.Deck: DeckFeedbackState] = [
            .a: loaded { $0.isSynced = true; $0.hotCues = [0, 3] },
            .b: loaded { $0.isLooping = true; $0.isPlaying = true },
        ]
        let desired = ControllerFeedbackRenderer.render(mapping, states: states, clock: 0)
        XCTAssertEqual(value(desired, .note, 0, 0x58), 0x7F)
        XCTAssertEqual(value(desired, .note, 1, 0x58), 0)
        XCTAssertEqual(value(desired, .note, 1, 0x10), 0x7F)
        XCTAssertEqual(value(desired, .note, 1, 0x11), 0x7F)
        XCTAssertEqual(value(desired, .note, 1, 0x4D), 0x7F)
        XCTAssertEqual(value(desired, .note, 0, 0x10), 0)
        XCTAssertEqual(value(desired, .note, 7, 0), 0x7F)
        XCTAssertEqual(value(desired, .note, 7, 1), 0)
        XCTAssertEqual(value(desired, .note, 7, 3), 0x7F)
        XCTAssertEqual(value(desired, .note, 9, 0), 0)
    }

    func testLockedDeckGoesDark() {
        let locked = loaded { $0.isPlaying = true; $0.isLocked = true; $0.hotCues = [0]; $0.level = 1 }
        let desired = ControllerFeedbackRenderer.render(mapping, states: [.a: locked], clock: 0.25)
        for output in mapping.outputs where output.deck == .a {
            XCTAssertEqual(desired[output.key]?.message.value, UInt16(output.offValue), "\(output)")
        }
    }

    func testBlackoutTurnsEveryOutputOff() {
        let messages = ControllerFeedbackRenderer.blackout(mapping)
        XCTAssertEqual(messages.count, mapping.outputs.count)
        XCTAssertTrue(messages.allSatisfy { $0.value == 0 })
    }

    func testTrackEndingBlinksInTheLastThirtySeconds() {
        let warning = ControllerFeedbackMapping.Output.led(0, 0x40, .a, .trackEnding)
        let early = loaded { $0.isPlaying = true; $0.position = 100 }
        let late = loaded { $0.isPlaying = true; $0.position = 220 }
        XCTAssertFalse(ControllerFeedbackRenderer.lit(warning.signal, state: early, clock: 0.1))
        XCTAssertTrue(ControllerFeedbackRenderer.lit(warning.signal, state: late, clock: 0.1))
        XCTAssertFalse(ControllerFeedbackRenderer.lit(warning.signal, state: late, clock: 0.3))
    }

    // MARK: Continuous

    func testMeterScalesFromMinus48Decibels() {
        XCTAssertEqual(ControllerFeedbackRenderer.meter(rms: 0), 0)
        XCTAssertEqual(ControllerFeedbackRenderer.meter(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(ControllerFeedbackRenderer.meter(rms: pow(10, -24.0 / 20)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ControllerFeedbackRenderer.meter(rms: 4), 1)
        XCTAssertEqual(ControllerFeedbackRenderer.meter(rms: .nan), 0)

        let desired = ControllerFeedbackRenderer.render(mapping, states: [.b: loaded { $0.level = 1 }], clock: 0)
        XCTAssertEqual(value(desired, .cc, 1, 0x02), 127)
        XCTAssertEqual(value(desired, .cc, 0, 0x02), 0)
    }

    func testProgressAndJogRingScale() {
        let ring = ControllerFeedbackMapping.Output.meter(2, 0x10, .a, .jogRing)
        let bar = ControllerFeedbackMapping.Output.meter(2, 0x11, .a, .progress)
        let turn = ControllerFeedbackRenderer.platterSecondsPerTurn
        XCTAssertEqual(ControllerFeedbackRenderer.value(of: ring, state: loaded { $0.position = 0 }, clock: 0), 0)
        XCTAssertEqual(ControllerFeedbackRenderer.value(of: ring, state: loaded { $0.position = turn * 3.25 }, clock: 0), 32)
        XCTAssertEqual(ControllerFeedbackRenderer.value(of: ring, state: loaded { $0.position = turn * 0.75 }, clock: 0), 95)
        XCTAssertEqual(ControllerFeedbackRenderer.value(of: bar, state: loaded { $0.position = 120 }, clock: 0), 64)
        XCTAssertEqual(ControllerFeedbackRenderer.value(of: bar, state: DeckFeedbackState(), clock: 0), 0)
    }

    func testTempoMatchAndBeatPhase() {
        XCTAssertTrue(DeckFeedbackMath.isTempoMatched(beatPeriod: 0.5, rate: 1, otherBeatPeriod: 0.5, otherRate: 1))
        XCTAssertTrue(DeckFeedbackMath.isTempoMatched(beatPeriod: 60.0 / 124, rate: 128.0 / 124, otherBeatPeriod: 60.0 / 128, otherRate: 1))
        XCTAssertTrue(DeckFeedbackMath.isTempoMatched(beatPeriod: 60.0 / 64, rate: 1, otherBeatPeriod: 60.0 / 128, otherRate: 1))
        XCTAssertFalse(DeckFeedbackMath.isTempoMatched(beatPeriod: 60.0 / 124, rate: 1, otherBeatPeriod: 60.0 / 128, otherRate: 1))
        XCTAssertEqual(DeckFeedbackMath.beatPhase(position: 10.25, anchor: 0.25, beatPeriod: 0.5) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(DeckFeedbackMath.beatPhase(position: 0, anchor: 0.25, beatPeriod: 0.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(DeckFeedbackMath.beatPhase(position: 1, anchor: 0, beatPeriod: 0))
    }

    // MARK: Throttle

    func testThrottleSendsLightsOnceAndOnlyOnChange() {
        var throttle = ControllerFeedbackThrottle()
        throttle.maximumPerFlush = 64
        let playing = ControllerFeedbackRenderer.render(mapping, states: [.a: loaded { $0.isPlaying = true }], clock: 0)
        XCTAssertEqual(throttle.take(playing, now: 0).count, mapping.outputs.count)
        XCTAssertEqual(throttle.take(playing, now: 0.04), [])

        let stopped = ControllerFeedbackRenderer.render(mapping, states: [.a: loaded { $0.isPlaying = true; $0.isLooping = true }], clock: 0)
        let changes = throttle.take(stopped, now: 0.08)
        XCTAssertEqual(Set(changes.map(\.number)), [0x10, 0x11, 0x4D])

        throttle.reset()
        XCTAssertEqual(throttle.take(stopped, now: 0.12).count, mapping.outputs.count)
    }

    func testThrottleCapsMeterRate() {
        var throttle = ControllerFeedbackThrottle()
        let meter = ControllerFeedbackMapping(outputs: [.meter(0, 0x02, .a, .level)])
        var sent = 0
        var clock = 0.0
        while clock < 1 {
            let rms = 0.05 + 0.9 * abs(sin(clock * 40))
            let desired = ControllerFeedbackRenderer.render(meter, states: [.a: loaded { $0.level = rms }], clock: clock)
            sent += throttle.take(desired, now: clock).count
            clock += 0.005
        }
        XCTAssertGreaterThan(sent, 5)
        XCTAssertLessThanOrEqual(sent, 16)
    }

    func testThrottleSkipsTinyMeterChangesButRefreshes() {
        var throttle = ControllerFeedbackThrottle()
        let key = ControllerFeedbackKey(midi: .cc, channel: 0, number: 2)
        func meter(_ value: UInt16) -> [ControllerFeedbackKey: ControllerFeedbackValue] {
            [key: ControllerFeedbackValue(message: ControllerMIDIMessage(kind: .controlChange, channel: 0, number: 2, value: value), isContinuous: true)]
        }
        XCTAssertEqual(throttle.take(meter(60), now: 0).count, 1)
        XCTAssertEqual(throttle.take(meter(61), now: 0.1).count, 0)
        XCTAssertEqual(throttle.take(meter(70), now: 0.12).count, 1)
        XCTAssertEqual(throttle.take(meter(71), now: 0.7).count, 1)
        XCTAssertEqual(throttle.take(meter(0), now: 0.78).count, 1)
    }

    func testThrottleNeverExceedsTheFlushBudget() {
        var throttle = ControllerFeedbackThrottle()
        var outputs: [ControllerFeedbackMapping.Output] = []
        for number in 0..<100 {
            outputs.append(.led(UInt8(number / 64), UInt8(number % 64), .a, .loaded))
        }
        let big = ControllerFeedbackMapping(outputs: outputs)
        let desired = ControllerFeedbackRenderer.render(big, states: [.a: loaded()], clock: 0)
        var delivered = 0
        var flushes = 0
        while delivered < 100, flushes < 10 {
            let batch = throttle.take(desired, now: Double(flushes) * 0.04)
            XCTAssertLessThanOrEqual(batch.count, throttle.maximumPerFlush)
            delivered += batch.count
            flushes += 1
        }
        XCTAssertEqual(delivered, 100)
        XCTAssertEqual(flushes, 5)
    }

    // MARK: Wire

    func testUniversalPacketWordRoundTrips() {
        let messages = [
            ControllerMIDIMessage(kind: .noteOn, channel: 7, number: 3, value: 0x7F),
            ControllerMIDIMessage(kind: .controlChange, channel: 1, number: 0x02, value: 64),
            ControllerMIDIMessage(kind: .pitchBend, channel: 0, number: 0, value: 9000),
        ]
        for message in messages {
            XCTAssertEqual(ControllerMIDIMessage(universalPacketWord: message.universalPacketWord), message)
        }
        XCTAssertEqual(messages[0].universalPacketWord, 0x2097_037F)
    }

    // MARK: Surface

    @MainActor
    func testBasicFeedbackReadsTheSurface() {
        let surface = FakeSurface()
        surface.values[DeckControlAddress(group: .deck(.a), control: .play)] = 1
        surface.values[DeckControlAddress(group: .deck(.a), control: .hotCue, index: 2)] = 1
        let state = surface.currentFeedback(for: .a)
        XCTAssertTrue(state.isLoaded)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.hotCues, [2])
        XCTAssertFalse(surface.currentFeedback(for: .b).isLoaded)
    }
}

@MainActor
private final class FakeSurface: DeckControlSurface {
    var values: [DeckControlAddress: Double] = [:]
    func value(of address: DeckControlAddress) -> Double? { values[address] }
    func setValue(_ value: Double, for address: DeckControlAddress) {}
    func press(_ address: DeckControlAddress, isDown: Bool) {}
    func jog(_ group: DeckGroup, ticks: Double) {}
}
