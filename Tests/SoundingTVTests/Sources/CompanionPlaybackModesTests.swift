import XCTest
@testable import SoundingTV

final class CompanionPlaybackModesTests: XCTestCase {
    private let credentials = SessionCredentials.generate()!

    private func playbackState(
        revision: Int = 7,
        isShuffleEnabled: Bool? = true,
        repeatMode: RemoteRepeatMode? = .one
    ) -> PlaybackStatePayload {
        PlaybackStatePayload.create(
            isPlaying: true,
            positionSeconds: 42,
            durationSeconds: 300,
            trackId: "123",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isDJEngineLive: false,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            revision: revision,
            sessionId: credentials.sessionId,
            secret: credentials.secret
        )
    }

    private func json(_ message: TokenTransferMessage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: message.encode()) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> TokenTransferMessage {
        try TokenTransferMessage.decode(from: JSONSerialization.data(withJSONObject: object))
    }

    func testShuffleAndRepeatStateRoundTripsThroughThePlaybackSnapshot() throws {
        for mode in RemoteRepeatMode.allCases {
            for shuffle in [false, true] {
                let message = TokenTransferMessage.playbackState(
                    sessionId: credentials.sessionId,
                    playback: playbackState(isShuffleEnabled: shuffle, repeatMode: mode)
                )
                let framed = try message.framed()
                var framer = MessageFramer()
                framer.append(framed)
                let decoded = try XCTUnwrap(try framer.next())
                let playback = try XCTUnwrap(decoded.playback)

                XCTAssertEqual(decoded.type, .playbackState)
                XCTAssertEqual(playback, message.playback)
                XCTAssertEqual(playback.modes?.isShuffleEnabled, shuffle)
                XCTAssertEqual(playback.modes?.remoteRepeatMode, mode)
                XCTAssertTrue(playback.verify(sessionId: credentials.sessionId, secret: credentials.secret))
            }
        }
    }

    func testOlderClientsStillVerifyAStateThatCarriesModes() throws {
        let message = TokenTransferMessage.playbackState(sessionId: credentials.sessionId, playback: playbackState())
        var object = try json(message)
        var playback = try XCTUnwrap(object["playback"] as? [String: Any])
        XCTAssertNotNil(playback["modes"])
        playback["modes"] = nil
        object["playback"] = playback

        let stripped = try XCTUnwrap(try decode(object).playback)

        XCTAssertNil(stripped.modes)
        XCTAssertTrue(stripped.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testStateFromAnOlderTVDecodesWithoutModes() throws {
        let message = TokenTransferMessage.playbackState(
            sessionId: credentials.sessionId,
            playback: playbackState(isShuffleEnabled: nil, repeatMode: nil)
        )
        let playback = try XCTUnwrap(try json(message)["playback"] as? [String: Any])
        XCTAssertNil(playback["modes"])

        let decoded = try XCTUnwrap(try TokenTransferMessage.decode(from: message.encode()).playback)
        XCTAssertNil(decoded.modes)
        XCTAssertTrue(decoded.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testTamperedModesFailVerification() throws {
        let message = TokenTransferMessage.playbackState(sessionId: credentials.sessionId, playback: playbackState())
        var object = try json(message)
        var playback = try XCTUnwrap(object["playback"] as? [String: Any])
        var modes = try XCTUnwrap(playback["modes"] as? [String: Any])
        modes["isShuffleEnabled"] = false
        playback["modes"] = modes
        object["playback"] = playback

        let tampered = try XCTUnwrap(try decode(object).playback)

        XCTAssertFalse(tampered.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testModesCannotBeMovedOntoAnotherSnapshot() {
        let first = playbackState(revision: 1, isShuffleEnabled: true, repeatMode: .all)
        var second = playbackState(revision: 2, isShuffleEnabled: false, repeatMode: .off)
        second.modes = first.modes

        XCTAssertFalse(second.verify(sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testModesSignedForAnotherDeviceFailVerification() {
        let other = SessionCredentials.generate()!
        let state = playbackState()
        XCTAssertFalse(state.modes!.verify(
            revision: state.revision,
            issuedAtMillis: state.issuedAtMillis,
            sessionId: credentials.sessionId,
            secret: other.secret
        ))
    }

    func testShuffleAndRepeatCommandsRoundTripThroughTheEncoder() throws {
        let signer = CompanionCommandSigner(sessionId: credentials.sessionId, secret: credentials.secret)
        let commands: [(MessageType, Double)] = [
            (.transportShuffle, 1),
            (.transportShuffle, 0),
        ] + RemoteRepeatMode.allCases.map { (.transportRepeat, $0.wireValue) }

        for (type, value) in commands {
            let message = signer.control(type, value: value)
            var framer = MessageFramer()
            framer.append(try message.framed())
            let decoded = try XCTUnwrap(try framer.next())
            let control = try XCTUnwrap(decoded.control)

            XCTAssertEqual(decoded.type, type)
            XCTAssertTrue(decoded.type.isControlCommand)
            XCTAssertFalse(decoded.type.isContinuousControl)
            XCTAssertEqual(control.value, value)
            XCTAssertTrue(control.isFresh())
            XCTAssertTrue(control.verify(type: type, sessionId: credentials.sessionId, secret: credentials.secret))
            XCTAssertFalse(control.verify(type: .transportPlay, sessionId: credentials.sessionId, secret: credentials.secret))
        }
    }

    func testRepeatModesMapOntoThePlayerModes() {
        for mode in RemoteRepeatMode.allCases {
            XCTAssertEqual(RemoteRepeatMode(wireValue: mode.wireValue), mode)
            XCTAssertNotNil(RepeatMode(rawValue: mode.rawValue))
        }
        for mode in RepeatMode.allCases {
            XCTAssertNotNil(RemoteRepeatMode(rawValue: mode.rawValue))
        }
        XCTAssertNil(RemoteRepeatMode(wireValue: 7))
        XCTAssertNil(RemoteRepeatMode(wireValue: -1))
    }
}
