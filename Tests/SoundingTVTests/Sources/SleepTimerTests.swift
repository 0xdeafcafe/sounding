import XCTest
@testable import SoundingTV

final class SleepTimerTests: XCTestCase {
    private let credentials = SessionCredentials.generate()!

    private func playback(sleep: SleepTimerStatus?) -> PlaybackStatePayload {
        PlaybackStatePayload.create(
            isPlaying: true,
            positionSeconds: 12,
            durationSeconds: 300,
            trackId: "1",
            title: "One",
            artist: "A",
            artworkURL: nil,
            isDJEngineLive: false,
            sleepTimer: sleep,
            revision: 7,
            sessionId: credentials.sessionId,
            secret: credentials.secret
        )
    }

    private func roundTrip(_ message: TokenTransferMessage) throws -> TokenTransferMessage {
        var framer = MessageFramer()
        framer.append(try message.framed())
        return try XCTUnwrap(try framer.next())
    }

    func testFadeIsFullUntilTheLastThirtySecondsThenReachesSilence() {
        XCTAssertEqual(SleepTimer.gain(remaining: 600), 1)
        XCTAssertEqual(SleepTimer.gain(remaining: 30), 1)
        XCTAssertEqual(SleepTimer.gain(remaining: 15), 0.5, accuracy: 0.001)
        XCTAssertLessThan(SleepTimer.gain(remaining: 1), 0.01)
        XCTAssertEqual(SleepTimer.gain(remaining: 0), 0)
        XCTAssertEqual(SleepTimer.gain(remaining: -3), 0)
        var previous = 1.0
        for second in stride(from: 30.0, through: 0, by: -0.5) {
            let gain = SleepTimer.gain(remaining: second)
            XCTAssertLessThanOrEqual(gain, previous)
            previous = gain
        }
    }

    func testWireModesRoundTripAndRejectNonsense() {
        for mode in [SleepTimerMode.minutes(15), .minutes(60), .endOfTrack, .endOfMix] {
            XCTAssertEqual(SleepTimerMode(wireKind: mode.wireKind, minutes: mode.wireMinutes), mode)
        }
        XCTAssertNil(SleepTimerMode(wireKind: 0, minutes: 0))
        XCTAssertNil(SleepTimerMode(wireKind: 1, minutes: 0))
        XCTAssertNil(SleepTimerMode(wireKind: 1, minutes: .nan))
        XCTAssertNil(SleepTimerMode(wireKind: 9, minutes: 30))
    }

    func testPlaybackStateCarriesTheSleepTimerAndStillVerifies() throws {
        let ends = Date(timeIntervalSince1970: 1_800_000_000)
        let message = TokenTransferMessage.playbackState(
            sessionId: credentials.sessionId,
            playback: playback(sleep: SleepTimerStatus(mode: .minutes(30), endsAt: ends))
        )
        let decoded = try XCTUnwrap(try roundTrip(message).playback)

        XCTAssertTrue(decoded.verify(sessionId: credentials.sessionId, secret: credentials.secret))
        XCTAssertEqual(decoded.sleepTimerStatus, SleepTimerStatus(mode: .minutes(30), endsAt: ends))
    }

    func testPlaybackStateFromAnOlderTVHasNoSleepTimer() throws {
        let message = TokenTransferMessage.playbackState(sessionId: credentials.sessionId, playback: playback(sleep: nil))
        let decoded = try XCTUnwrap(try roundTrip(message).playback)

        XCTAssertNil(decoded.sleepTimerStatus)
        XCTAssertTrue(decoded.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testATamperedSleepTimerFailsVerification() throws {
        var state = playback(sleep: SleepTimerStatus(mode: .endOfTrack, endsAt: nil))
        let original = try XCTUnwrap(state.sleepTimer)
        state.sleepTimer = SleepTimerStatePayload(kind: 1, minutes: 60, endsAtMillis: nil, signature: original.signature)

        XCTAssertFalse(state.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testSleepTimerIsAControlCommand() {
        XCTAssertTrue(MessageType.transportSleepTimer.isControlCommand)
        XCTAssertFalse(MessageType.transportSleepTimer.isContinuousControl)
    }

    func testEndOfTrackWithoutATracklistIsTheEndOfTheTrack() {
        XCTAssertEqual(SleepTimer.endOfTrackTarget(position: 100, duration: 300, tracklist: nil), 300)
    }
}
