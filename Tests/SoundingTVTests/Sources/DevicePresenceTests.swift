import XCTest
@testable import SoundingTV

final class DevicePresenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let account = "acct"
    private let ownID = "this-phone"

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func session(
        device: String,
        name: String,
        deviceClass: DeviceClass = .tv,
        track: String = "t1",
        title: String = "Harbour Lights",
        playing: Bool = true,
        updated: TimeInterval = 0,
        started: TimeInterval? = nil,
        account: String? = nil
    ) -> ContinueSession {
        ContinueSession(
            deviceID: device,
            deviceName: name,
            deviceClass: deviceClass,
            account: account ?? self.account,
            sessionID: "s-\(device)",
            trackID: track,
            title: title,
            artist: "Low Sun",
            duration: 600,
            position: 30,
            queueTrackIDs: [track, "next"],
            queueIndex: 0,
            isPlaying: playing,
            updatedAt: at(updated),
            startedAt: started.map(at)
        )
    }

    private func entries(
        _ sessions: [ContinueSession],
        source: DevicePresenceSource = .cloud,
        live: [DevicePresenceLiveReport] = [],
        outputs: [DevicePresenceOutput] = [],
        currentOutputID: String? = nil,
        localTrackID: String? = nil,
        now: TimeInterval
    ) -> [DevicePresenceEntry] {
        DevicePresence.entries(
            records: sessions.map { DevicePresenceRecord(session: $0, source: source) },
            live: live,
            outputs: outputs,
            currentOutputID: currentOutputID,
            ownDeviceID: ownID,
            account: account,
            localTrackID: localTrackID,
            now: at(now)
        )
    }

    private func report(
        outputID: String = "linked.living",
        name: String = "Living Room",
        track: String? = "t9",
        title: String = "Night Bus",
        playing: Bool = true,
        received: TimeInterval = 0,
        started: TimeInterval = 0
    ) -> DevicePresenceLiveReport {
        DevicePresenceLiveReport(
            outputID: outputID,
            deviceName: name,
            deviceClass: .tv,
            trackID: track,
            title: title,
            artist: "Glass District",
            artworkURL: nil,
            isPlaying: playing,
            position: 12,
            duration: 300,
            receivedAt: at(received),
            startedAt: at(started)
        )
    }

    // MARK: - Staleness

    func testRecentPlayingRecordIsLive() {
        let list = entries([session(device: "tv", name: "Living Room", updated: 0)], now: 30)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.freshness, .live)
        XCTAssertEqual(list.first?.sentence(at: at(30)), "Living Room is playing Harbour Lights")
        XCTAssertEqual(list.first?.caption(at: at(30)), "Playing on Living Room")
    }

    func testPlayingRecordPastTheLiveWindowIsNeverCalledLive() {
        let list = entries([session(device: "tv", name: "Living Room", updated: 0)], now: 180)
        XCTAssertEqual(list.first?.freshness, .stale)
        XCTAssertEqual(list.first?.sentence(at: at(180)), "Living Room was playing Harbour Lights \u{00B7} a few minutes ago")
        XCTAssertEqual(list.first?.caption(at: at(180)), "Living Room \u{00B7} a few minutes ago")
    }

    func testOldEntriesAreHidden() {
        XCTAssertTrue(entries([session(device: "tv", name: "Living Room", updated: 0)], now: 31 * 60).isEmpty)
        XCTAssertTrue(entries([session(device: "tv", name: "Living Room", playing: false, updated: 0)], now: 31 * 60).isEmpty)
    }

    func testPausedRecordSaysWhenOnlyOnceItIsOld() {
        let fresh = entries([session(device: "tv", name: "Living Room", playing: false, updated: 0)], now: 30)
        XCTAssertEqual(fresh.first?.freshness, .paused)
        XCTAssertEqual(fresh.first?.sentence(at: at(30)), "Living Room paused Harbour Lights")
        let old = entries([session(device: "tv", name: "Living Room", playing: false, updated: 0)], now: 12 * 60)
        XCTAssertEqual(old.first?.sentence(at: at(12 * 60)), "Living Room paused Harbour Lights \u{00B7} 12 min ago")
    }

    func testFinishedQueueIsNotPlaying() {
        var finished = session(device: "tv", name: "Living Room", updated: 0)
        finished.queueTrackIDs = ["t1"]
        finished.queueIndex = 0
        finished.position = 599
        let list = entries([finished], now: 30)
        XCTAssertEqual(list.first?.freshness, .paused)
        XCTAssertEqual(list.first?.isPlaying, false)
    }

    func testNextChangeIsTheLiveWindowEdge() {
        let list = entries([session(device: "tv", name: "Living Room", updated: 0)], now: 10)
        XCTAssertEqual(DevicePresence.nextChange(for: list, after: at(10)), at(DevicePresence.liveWindow))
    }

    func testCompanionEntryAgesOnceItCanNoLongerBeTrusted() {
        let list = entries([], live: [report(received: 0)], now: 0)
        XCTAssertEqual(list.first?.evaluated(at: at(600), trustsLive: true)?.freshness, .live)
        XCTAssertEqual(list.first?.evaluated(at: at(600), trustsLive: false)?.freshness, .stale)
        XCTAssertNil(list.first?.evaluated(at: at(40 * 60), trustsLive: false))
    }

    // MARK: - Merging

    func testOwnDeviceAndOtherAccountsAreLeftOut() {
        let list = entries([
            session(device: ownID, name: "Alex's iPhone", deviceClass: .phone),
            session(device: "other", name: "Someone's iPad", deviceClass: .pad, account: "someone-else"),
            session(device: "mac", name: "MacBook Pro", deviceClass: .mac),
        ], now: 10)
        XCTAssertEqual(list.map(\.displayName), ["MacBook Pro"])
    }

    func testNewestRecordWinsAcrossCloudAndLink() {
        let older = DevicePresenceRecord(session: session(device: "mac", name: "Mac", track: "old", updated: 0), source: .link)
        let newer = DevicePresenceRecord(session: session(device: "mac", name: "Mac", track: "new", updated: 20), source: .cloud)
        let list = DevicePresence.entries(records: [older, newer], ownDeviceID: ownID, account: account, now: at(30))
        XCTAssertEqual(list.map(\.trackID), ["new"])
        XCTAssertEqual(list.first?.source, .cloud)
    }

    func testSameMomentPrefersLink() {
        let cloud = DevicePresenceRecord(session: session(device: "mac", name: "Mac", updated: 0), source: .cloud)
        let link = DevicePresenceRecord(session: session(device: "mac", name: "Mac", updated: 0), source: .link)
        let list = DevicePresence.entries(records: [cloud, link], ownDeviceID: ownID, account: account, now: at(5))
        XCTAssertEqual(list.first?.source, .link)
    }

    func testSameNamedDeviceWithNewIdentityIsOneEntry() {
        let list = entries([
            session(device: "old-install", name: "Alex\u{2019}s iPad", deviceClass: .pad, track: "a", updated: 0),
            session(device: "new-install", name: "alex's ipad", deviceClass: .pad, track: "b", updated: 10),
        ], now: 20)
        XCTAssertEqual(list.map(\.trackID), ["b"])
    }

    func testLiveCompanionStateReplacesTheRecord() {
        let list = entries(
            [session(device: "tv", name: "Living Room", track: "t1", updated: 0)],
            live: [report(track: "t9", received: 400)],
            outputs: [DevicePresenceOutput(id: "linked.living", name: "Living Room", deviceClass: .tv)],
            now: 400
        )
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.trackID, "t9")
        XCTAssertEqual(list.first?.source, .companion)
        XCTAssertEqual(list.first?.freshness, .live)
        XCTAssertEqual(list.first?.id, "device:tv")
        XCTAssertEqual(list.first?.outputID, "linked.living")
    }

    func testCompanionMatchesARenamedRecordByTrack() {
        let list = entries(
            [session(device: "tv", name: "Apple TV", track: "t9", updated: 0)],
            live: [report(name: "Living Room", track: "t9", received: 10)],
            now: 10
        )
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.displayName, "Living Room")
    }

    func testIdleCompanionHidesAnOldClaim() {
        let list = entries(
            [session(device: "tv", name: "Living Room", updated: 0)],
            live: [report(track: nil, playing: false, received: 30)],
            now: 30
        )
        XCTAssertTrue(list.isEmpty)
    }

    func testRecordsMatchLinkedOutputsByName() {
        let outputs = [DevicePresenceOutput(id: "linked.living", name: "Living Room", deviceClass: .tv)]
        let list = entries([session(device: "tv", name: "living room")], outputs: outputs, currentOutputID: "linked.living", now: 5)
        XCTAssertEqual(list.first?.outputID, "linked.living")
        XCTAssertEqual(list.first?.isOutput, true)
        let notOutput = entries([session(device: "tv", name: "Living Room")], outputs: outputs, now: 5)
        XCTAssertEqual(notOutput.first?.isOutput, false)
    }

    func testThePausedCopyOfWhatMovedHereIsHidden() {
        let list = entries([
            session(device: "tv", name: "Living Room", track: "t1", playing: false, updated: 0),
            session(device: "mac", name: "Mac", deviceClass: .mac, track: "t1", playing: true, updated: 0),
        ], localTrackID: "t1", now: 10)
        XCTAssertEqual(list.map(\.displayName), ["Mac"])
    }

    // MARK: - Selection

    func testOutputComesFirst() {
        let outputs = [DevicePresenceOutput(id: "linked.living", name: "Living Room", deviceClass: .tv)]
        let list = entries([
            session(device: "mac", name: "Mac", deviceClass: .mac, updated: 50, started: 50),
            session(device: "tv", name: "Living Room", playing: false, updated: 0),
        ], outputs: outputs, currentOutputID: "linked.living", now: 60)
        XCTAssertEqual(DevicePresence.primary(in: list)?.displayName, "Living Room")
        XCTAssertEqual(DevicePresence.others(list, excludingOutput: true).map(\.displayName), ["Mac"])
    }

    func testMostRecentlyStartedLiveDeviceIsNext() {
        let list = entries([
            session(device: "mac", name: "Mac", deviceClass: .mac, updated: 50, started: 10),
            session(device: "pad", name: "iPad", deviceClass: .pad, updated: 40, started: 30),
        ], now: 60)
        XCTAssertEqual(list.map(\.displayName), ["iPad", "Mac"])
    }

    func testLiveBeforePausedBeforeStale() {
        let list = entries([
            session(device: "stale", name: "Kitchen", updated: 0),
            session(device: "paused", name: "Bedroom", playing: false, updated: 400),
            session(device: "live", name: "Mac", deviceClass: .mac, updated: 450),
        ], now: 500)
        XCTAssertEqual(list.map(\.freshness), [.live, .paused, .stale])
        XCTAssertEqual(list.map(\.displayName), ["Mac", "Bedroom", "Kitchen"])
    }

    func testMoreLabel() {
        XCTAssertNil(DevicePresence.moreLabel(count: 0))
        XCTAssertNil(DevicePresence.moreLabel(count: 1))
        XCTAssertEqual(DevicePresence.moreLabel(count: 2), "+1")
        XCTAssertEqual(DevicePresence.moreLabel(count: 4), "+3")
    }

    // MARK: - Words

    func testYouAndTheyPhrasing() {
        let list = entries([session(device: "tv", name: "Living Room", title: "Night Bus")], now: 10)
        XCTAssertEqual(
            DevicePresence.summary(localTitle: "Harbour Lights", others: list, now: at(10)),
            "You\u{2019}re playing Harbour Lights. Living Room is playing Night Bus."
        )
        XCTAssertEqual(DevicePresence.summary(localTitle: nil, others: list, now: at(10)), "Living Room is playing Night Bus.")
        XCTAssertEqual(DevicePresence.summary(localTitle: "Harbour Lights", others: [], now: at(10)), "You\u{2019}re playing Harbour Lights.")
        XCTAssertEqual(DevicePresence.summary(localTitle: nil, others: [], now: at(10)), "")
    }

    func testUnnamedDeviceAndTrackFallBack() {
        let list = entries([session(device: "tv", name: " ", title: "")], now: 10)
        XCTAssertEqual(list.first?.sentence(at: at(10)), "Apple TV is playing a track")
    }

    func testAgoWords() {
        XCTAssertEqual(DevicePresence.ago(20), "just now")
        XCTAssertEqual(DevicePresence.ago(150), "a few minutes ago")
        XCTAssertEqual(DevicePresence.ago(25 * 60), "25 min ago")
        XCTAssertEqual(DevicePresence.ago(65 * 60), "1 hr ago")
        XCTAssertEqual(DevicePresence.ago(3 * 3600), "3 hr ago")
    }

    @MainActor
    func testContinueCaptionNeverClaimsOldPlayback() {
        let now = Date()
        let live = ContinueFrom.Offer(session: sessionAt(now.addingTimeInterval(-20), playing: true), position: 14)
        XCTAssertEqual(live.miniCaption(at: now), "Playing on Living Room \u{00B7} 0:14")
        let old = ContinueFrom.Offer(session: sessionAt(now.addingTimeInterval(-2 * 3600), playing: true), position: 14)
        XCTAssertEqual(old.miniCaption(at: now), "From Living Room \u{00B7} 2 hr ago")
        let paused = ContinueFrom.Offer(session: sessionAt(now.addingTimeInterval(-2 * 3600), playing: false), position: 14)
        XCTAssertEqual(paused.miniCaption(at: now), "Paused on Living Room \u{00B7} 0:14")
    }

    private func sessionAt(_ updated: Date, playing: Bool) -> ContinueSession {
        ContinueSession(
            deviceID: "tv", deviceName: "Living Room", deviceClass: .tv, account: account, sessionID: "s",
            trackID: "t1", title: "Harbour Lights", artist: "Low Sun", duration: 600, position: 14,
            queueTrackIDs: ["t1", "t2"], queueIndex: 0, isPlaying: playing, updatedAt: updated
        )
    }

    // MARK: - Wire

    func testStartTimeRoundTripsAndOldRecordsStillDecode() throws {
        let original = session(device: "tv", name: "Living Room", updated: 10, started: 4)
        let data = try XCTUnwrap(original.encoded())
        XCTAssertEqual(ContinueSession.decode(data)?.startedAt, at(4))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["b"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try XCTUnwrap(ContinueSession.decode(legacyData))
        XCTAssertNil(decoded.startedAt)
        let list = DevicePresence.entries(
            records: [DevicePresenceRecord(session: decoded, source: .cloud)],
            ownDeviceID: ownID, account: account, now: at(20)
        )
        XCTAssertEqual(list.first?.startedAt, decoded.updatedAt)
    }

    func testWatchPayloadRoundTrips() throws {
        let list = entries([session(device: "tv", name: "Living Room")], now: 10)
        let payload = WatchDevicePresence(entries: list)
        let data = try XCTUnwrap(WatchLinkCodec.encode(payload))
        let decoded = try XCTUnwrap(WatchLinkCodec.decode(WatchDevicePresence.self, from: data))
        XCTAssertEqual(decoded.visible(at: at(10), trustsLive: true).map(\.displayName), ["Living Room"])
        XCTAssertEqual(decoded.visible(at: at(200), trustsLive: true).first?.freshness, .stale)
    }
}
