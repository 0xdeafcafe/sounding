import XCTest
@testable import SoundingTV

final class ContinueSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        device: String,
        track: String = "100",
        secondsAgo: TimeInterval,
        position: TimeInterval = 60,
        duration: TimeInterval = 240,
        playing: Bool = false,
        queue: [String]? = nil,
        account: String = "acct"
    ) -> ContinueSession {
        let ids = queue ?? [track]
        return ContinueSession(
            deviceID: device,
            deviceName: device,
            deviceClass: .phone,
            account: account,
            sessionID: "s-\(device)",
            trackID: track,
            title: "Track \(track)",
            artist: "Artist",
            duration: duration,
            position: position,
            queueTrackIDs: ids,
            queueIndex: ids.firstIndex(of: track) ?? 0,
            isPlaying: playing,
            updatedAt: now.addingTimeInterval(-secondsAgo)
        )
    }

    private func offer(_ sessions: [ContinueSession], own: Date? = nil, dismissed: Set<String> = []) -> ContinueSession? {
        ContinueSessions.offer(in: sessions, ownDeviceID: "me", account: "acct", ownLatest: own, dismissed: dismissed, now: now)
    }

    func testMergingKeepsTheNewestSessionPerDevice() {
        let old = session(device: "phone", track: "1", secondsAgo: 600)
        let new = session(device: "phone", track: "2", secondsAgo: 60)
        let mac = session(device: "mac", secondsAgo: 300)
        let merged = ContinueSessions.merging([[old, mac], [new]], now: now)
        XCTAssertEqual(merged.map(\.deviceID), ["phone", "mac"])
        XCTAssertEqual(merged.first?.trackID, "2")
        XCTAssertEqual(merged, ContinueSessions.merging([[new], [mac, old], merged], now: now))
    }

    func testMergingDropsSessionsOlderThanAWeek() {
        let stale = session(device: "phone", secondsAgo: ContinueSessions.keepFor + 1)
        XCTAssertTrue(ContinueSessions.merging([[stale]], now: now).isEmpty)
    }

    func testOffersTheNewestOtherDeviceWithinTwelveHours() {
        let phone = session(device: "phone", secondsAgo: 120)
        let mac = session(device: "mac", secondsAgo: 60)
        let mine = session(device: "me", secondsAgo: 10)
        XCTAssertEqual(offer([phone, mac, mine])?.deviceID, "mac")

        let tooOld = session(device: "phone", secondsAgo: ContinueSessions.offerWindow + 1)
        XCTAssertNil(offer([tooOld]))
    }

    func testNoOfferWhenThisDevicePlayedMoreRecently() {
        let phone = session(device: "phone", secondsAgo: 300)
        XCTAssertNil(offer([phone], own: now.addingTimeInterval(-60)))
        XCTAssertEqual(offer([phone], own: now.addingTimeInterval(-600))?.deviceID, "phone")
    }

    func testDismissedOtherAccountAndFinishedSessionsAreNotOffered() {
        let phone = session(device: "phone", secondsAgo: 60)
        XCTAssertNil(offer([phone], dismissed: [phone.dismissalKey]))
        XCTAssertNil(offer([session(device: "phone", secondsAgo: 60, account: "other")]))
        XCTAssertNil(offer([session(device: "phone", secondsAgo: 60, position: 240)]))
        XCTAssertNotNil(offer([session(device: "phone", secondsAgo: 60, position: 240, queue: ["100", "101"])]))
    }

    func testPositionAdvancesOnlyBrieflyWhilePlaying() {
        let playing = session(device: "phone", secondsAgo: 10, position: 60, playing: true)
        XCTAssertEqual(playing.position(at: now), 70, accuracy: 0.01)
        let silent = session(device: "phone", secondsAgo: 600, position: 60, playing: true)
        XCTAssertEqual(silent.position(at: now), 60 + ContinueSessions.liveSlack, accuracy: 0.01)
        let paused = session(device: "phone", secondsAgo: 600, position: 60)
        XCTAssertEqual(paused.position(at: now), 60, accuracy: 0.01)
    }

    func testQueueWindowKeepsTheCurrentTrackAndSomeHistory() {
        let ids = (0..<300).map(String.init)
        let window = ContinueSession.window(ids, index: 150, current: "150")
        XCTAssertEqual(window.ids.count, ContinueSession.queueLimit)
        XCTAssertEqual(window.ids[window.index], "150")
        XCTAssertEqual(window.index, ContinueSession.queueLimit / 5)

        let early = ContinueSession.window(ids, index: 3, current: "3")
        XCTAssertEqual(early.ids.first, "0")
        XCTAssertEqual(early.ids[early.index], "3")

        let late = ContinueSession.window(ids, index: 299, current: "299")
        XCTAssertEqual(late.ids.last, "299")
        XCTAssertEqual(late.ids[late.index], "299")
    }

    func testSessionRoundTripsAndToleratesMissingFields() throws {
        let original = session(device: "phone", secondsAgo: 5, queue: ["99", "100", "101"])
        let decoded = try XCTUnwrap(ContinueSession.decode(XCTUnwrap(original.encoded())))
        XCTAssertEqual(decoded, original)

        let sparse = try XCTUnwrap(ContinueSession.decode(Data(#"{"d":"tv","i":"7","u":1000,"c":"toaster"}"#.utf8)))
        XCTAssertEqual(sparse.queueTrackIDs, ["7"])
        XCTAssertEqual(sparse.deviceClass, .phone)
        XCTAssertFalse(sparse.isPlaying)
    }

    func testWirePayloadIsSignedAndBound() throws {
        let secret = Data(repeating: 7, count: 32)
        let body = try XCTUnwrap(session(device: "phone", secondsAgo: 0).encoded())
        let payload = ContinueSessionPayload.create(body: body, sessionId: "abc", secret: secret)
        XCTAssertTrue(payload.verify(sessionId: "abc", secret: secret))
        XCTAssertFalse(payload.verify(sessionId: "other", secret: secret))

        let message = TokenTransferMessage.continueSession(sessionId: "abc", payload: payload)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.type, .continueSession)
        XCTAssertEqual(decoded.continueSession, payload)
    }
}
