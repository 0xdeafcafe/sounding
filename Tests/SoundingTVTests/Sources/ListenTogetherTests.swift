import XCTest
@testable import SoundingTV

final class ListenTogetherTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func track(_ number: Int, description: String = "") -> Track {
        let json = """
        {
            "id": \(number),
            "title": "Track \(number)",
            "description": "\(description)",
            "permalink_url": "https://soundcloud.com/example/\(number)",
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/example/\(number)/stream",
                        "duration": 200000,
                        "quality": "hq",
                        "format": { "protocol": "hls", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private func nowPlaying(_ trackNumber: Int, counter: UInt64, origin: String, position: TimeInterval = 10, isPlaying: Bool = true, sentAt: Date? = nil) -> ListenTogetherNowPlaying {
        ListenTogetherNowPlaying(
            stamp: ListenTogetherStamp(counter: counter, origin: origin),
            tracks: [Self.track(trackNumber), Self.track(trackNumber + 1)],
            currentIndex: 0,
            position: position,
            isPlaying: isPlaying,
            sentAt: sentAt ?? t0,
            sourceTitle: "Likes"
        )
    }

    private func listening(_ origin: String, participants: [String] = ["a", "b"]) -> ListenTogetherMachine {
        var machine = ListenTogetherMachine(origin: origin)
        _ = machine.handle(.sessionArrived(signedIn: true), now: t0)
        _ = machine.handle(.participantsChanged(participants), now: t0)
        return machine
    }

    // MARK: - Codec

    func testEveryMessageRoundTrips() throws {
        let messages: [ListenTogetherMessage] = [
            .hello(origin: "a"),
            .nowPlaying(nowPlaying(1, counter: 3, origin: "a")),
            .transport(ListenTogetherTransport(
                stamp: ListenTogetherStamp(counter: 4, origin: "b"), trackID: "1", position: 42.5, isPlaying: false, sentAt: t0
            ))
        ]
        for message in messages {
            XCTAssertEqual(try ListenTogetherCodec.decode(try ListenTogetherCodec.encode(message)), message)
        }
    }

    func testUnknownVersionIsRejected() throws {
        let data = Data(#"{"v":2,"m":{"hello":{"origin":"a"}}}"#.utf8)
        XCTAssertThrowsError(try ListenTogetherCodec.decode(data)) { error in
            XCTAssertEqual(error as? ListenTogetherCodec.Failure, .unsupportedVersion(2))
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try ListenTogetherCodec.decode(Data("nope".utf8)))
    }

    func testWindowKeepsTheCurrentTrackAndTwentyUpcoming() {
        let queue = (1...40).map { Self.track($0) }
        let window = ListenTogetherCodec.window(queue, currentIndex: 5)
        XCTAssertEqual(window.currentIndex, 0)
        XCTAssertEqual(window.tracks.count, 21)
        XCTAssertEqual(window.tracks.first?.id, "6")
        XCTAssertEqual(window.tracks.last?.id, "26")
        XCTAssertTrue(ListenTogetherCodec.window(queue, currentIndex: 99).tracks.isEmpty)
    }

    func testOversizedQueueIsTrimmedFromTheEndUntilItFits() throws {
        let long = String(repeating: "x", count: 6_000)
        var message = nowPlaying(1, counter: 1, origin: "a")
        message.tracks = (1...20).map { Self.track($0, description: long) }
        XCTAssertThrowsError(try ListenTogetherCodec.encode(.nowPlaying(message)))
        let data = try XCTUnwrap(ListenTogetherCodec.fitting(message))
        XCTAssertLessThanOrEqual(data.count, ListenTogetherCodec.maxBytes)
        guard case .nowPlaying(let decoded) = try ListenTogetherCodec.decode(data) else { return XCTFail() }
        XCTAssertEqual(decoded.trackID, "1")
        XCTAssertLessThan(decoded.tracks.count, 20)
    }

    // MARK: - State machine

    func testSignedInArrivalJoinsSuspendsMixingAndSaysHello() {
        var machine = ListenTogetherMachine(origin: "a")
        let effects = machine.handle(.sessionArrived(signedIn: true), now: t0)
        XCTAssertEqual(effects, [.join, .suspendMixing, .send(.hello(origin: "a"), to: nil)])
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.participantCount, 1)
    }

    func testSignedOutArrivalPromptsAndJoinsOnlyAfterSignIn() {
        var machine = ListenTogetherMachine(origin: "a")
        XCTAssertEqual(machine.handle(.sessionArrived(signedIn: false), now: t0), [.promptSignIn])
        XCTAssertEqual(machine.phase, .waitingForSignIn)
        XCTAssertEqual(machine.participantCount, 0)
        XCTAssertEqual(machine.handle(.received(.hello(origin: "b")), now: t0), [])
        XCTAssertEqual(machine.handle(.signedIn, now: t0), [.join, .suspendMixing, .send(.hello(origin: "a"), to: nil)])
        XCTAssertEqual(machine.handle(.signedIn, now: t0), [])
    }

    func testLocalTrackChangeBroadcastsOnceAndIgnoresTheSameTrack() {
        var machine = listening("a")
        let queue = (1...3).map { Self.track($0) }
        let effects = machine.handle(.localTrackChanged(tracks: queue, currentIndex: 1, position: 0, isPlaying: true, sourceTitle: "Likes"), now: t0)
        guard case .send(.nowPlaying(let sent), nil) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(sent.trackID, "2")
        XCTAssertEqual(sent.tracks.map(\.id), ["2", "3"])
        XCTAssertEqual(sent.stamp, ListenTogetherStamp(counter: 1, origin: "a"))
        XCTAssertEqual(machine.handle(.localTrackChanged(tracks: queue, currentIndex: 1, position: 3, isPlaying: true, sourceTitle: nil), now: t0), [])
    }

    func testNewerRemoteTrackPlaysWithLatencyCompensationAndOlderIsIgnored() {
        var machine = listening("a")
        let effects = machine.handle(.received(.nowPlaying(nowPlaying(7, counter: 5, origin: "b", position: 30, sentAt: t0))), now: t0.addingTimeInterval(1))
        guard case .play(let applied, let position) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(applied.trackID, "7")
        XCTAssertEqual(position, 31, accuracy: 0.001)
        XCTAssertEqual(machine.counter, 5)
        XCTAssertEqual(machine.handle(.received(.nowPlaying(nowPlaying(9, counter: 4, origin: "b"))), now: t0), [])
    }

    func testLatencyCompensationIsCappedAndSkippedWhilePaused() {
        var machine = listening("a")
        let late = machine.handle(.received(.nowPlaying(nowPlaying(7, counter: 1, origin: "b", position: 30, sentAt: t0))), now: t0.addingTimeInterval(60))
        XCTAssertEqual(late, [.play(nowPlaying(7, counter: 1, origin: "b", position: 30, sentAt: t0), position: 35)])
        var paused = listening("a")
        let effects = paused.handle(.received(.nowPlaying(nowPlaying(7, counter: 1, origin: "b", position: 30, isPlaying: false, sentAt: t0))), now: t0.addingTimeInterval(3))
        XCTAssertEqual(effects, [.play(nowPlaying(7, counter: 1, origin: "b", position: 30, isPlaying: false, sentAt: t0), position: 30)])
    }

    func testConcurrentChangesResolveByStampOnEveryDevice() {
        var a = listening("a")
        var b = listening("b")
        let queue = (1...4).map { Self.track($0) }
        let fromA = a.handle(.localTrackChanged(tracks: queue, currentIndex: 1, position: 0, isPlaying: true, sourceTitle: nil), now: t0)
        let fromB = b.handle(.localTrackChanged(tracks: queue, currentIndex: 2, position: 0, isPlaying: true, sourceTitle: nil), now: t0)
        guard case .send(let messageA, _) = fromA.first, case .send(let messageB, _) = fromB.first else { return XCTFail() }
        _ = a.handle(.received(messageB), now: t0)
        _ = b.handle(.received(messageA), now: t0)
        XCTAssertEqual(a.current?.trackID, "3")
        XCTAssertEqual(b.current?.trackID, "3")
    }

    func testRemotelyAppliedTrackIsNotEchoedBack() {
        var machine = listening("a")
        _ = machine.handle(.received(.nowPlaying(nowPlaying(7, counter: 2, origin: "b"))), now: t0)
        let echo = machine.handle(.localTrackChanged(tracks: [Self.track(7)], currentIndex: 0, position: 10, isPlaying: true, sourceTitle: nil), now: t0)
        XCTAssertEqual(echo, [])
    }

    func testTransportIsSentOnlyForRealChanges() {
        var machine = listening("a")
        _ = machine.handle(.localTrackChanged(tracks: [Self.track(1)], currentIndex: 0, position: 0, isPlaying: true, sourceTitle: nil), now: t0)
        XCTAssertEqual(machine.handle(.localTransport(trackID: "1", position: 10.5, isPlaying: true), now: t0.addingTimeInterval(10)), [])
        let paused = machine.handle(.localTransport(trackID: "1", position: 10, isPlaying: false), now: t0.addingTimeInterval(10))
        guard case .send(.transport(let pause), nil) = paused.first else { return XCTFail("\(paused)") }
        XCTAssertFalse(pause.isPlaying)
        let seek = machine.handle(.localTransport(trackID: "1", position: 90, isPlaying: false), now: t0.addingTimeInterval(11))
        guard case .send(.transport(let jump), nil) = seek.first else { return XCTFail("\(seek)") }
        XCTAssertEqual(jump.position, 90)
        XCTAssertEqual(machine.handle(.localTransport(trackID: "other", position: 0, isPlaying: true), now: t0), [])
    }

    func testRemoteTransportAppliesForTheCurrentTrackAndSuppressesItsEcho() {
        var machine = listening("a")
        _ = machine.handle(.received(.nowPlaying(nowPlaying(7, counter: 2, origin: "b", position: 0))), now: t0)
        let transport = ListenTogetherTransport(stamp: ListenTogetherStamp(counter: 3, origin: "b"), trackID: "7", position: 50, isPlaying: false, sentAt: t0)
        XCTAssertEqual(machine.handle(.received(.transport(transport)), now: t0), [.applyTransport(position: 50, isPlaying: false)])
        XCTAssertEqual(machine.handle(.received(.transport(transport)), now: t0), [])
        XCTAssertEqual(machine.handle(.localTransport(trackID: "7", position: 50, isPlaying: false), now: t0.addingTimeInterval(1)), [])
        let otherTrack = ListenTogetherTransport(stamp: ListenTogetherStamp(counter: 9, origin: "b"), trackID: "8", position: 5, isPlaying: true, sentAt: t0)
        XCTAssertEqual(machine.handle(.received(.transport(otherTrack)), now: t0), [])
    }

    func testOnlyOneParticipantAnswersAHello() {
        var leader = listening("a", participants: ["a", "b", "c"])
        _ = leader.handle(.localTrackChanged(tracks: [Self.track(1)], currentIndex: 0, position: 0, isPlaying: true, sourceTitle: nil), now: t0)
        var follower = listening("b", participants: ["a", "b", "c"])
        _ = follower.handle(.received(.nowPlaying(leader.current!)), now: t0)

        let answer = leader.handle(.received(.hello(origin: "c")), now: t0.addingTimeInterval(4))
        guard case .send(.nowPlaying(let snapshot), "c") = answer.first else { return XCTFail("\(answer)") }
        XCTAssertEqual(snapshot.position, 4, accuracy: 0.001)
        XCTAssertEqual(follower.handle(.received(.hello(origin: "c")), now: t0), [])

        _ = follower.handle(.participantsChanged(["b", "c"]), now: t0)
        XCTAssertTrue(follower.answersHello)
    }

    func testNobodyAnswersWithoutState() {
        var machine = listening("a")
        XCTAssertEqual(machine.handle(.received(.hello(origin: "b")), now: t0), [])
    }

    func testActivityFallbackIsBeatenByAnyRealStamp() {
        var machine = listening("a")
        _ = machine.handle(.received(.nowPlaying(nowPlaying(1, counter: 0, origin: ""))), now: t0)
        let effects = machine.handle(.received(.nowPlaying(nowPlaying(2, counter: 1, origin: "b"))), now: t0)
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(machine.current?.trackID, "2")
    }

    func testEndingResumesMixingOnlyIfItHadJoined() {
        var machine = listening("a")
        XCTAssertEqual(machine.handle(.sessionEnded, now: t0), [.resumeMixing])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.current)
        var waiting = ListenTogetherMachine(origin: "a")
        _ = waiting.handle(.sessionArrived(signedIn: false), now: t0)
        XCTAssertEqual(waiting.handle(.sessionEnded, now: t0), [])
    }
}
