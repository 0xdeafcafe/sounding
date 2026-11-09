import XCTest
@testable import SoundingTV

final class PlayHistoryTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func play(_ id: String, _ secondsAfterAnchor: TimeInterval, local: Bool = false) -> RecentPlay {
        RecentPlay(
            trackID: id,
            playedAt: anchor.addingTimeInterval(secondsAfterAnchor),
            title: "Track \(id)",
            artist: "Artist \(id)",
            duration: 240,
            isLocal: local
        )
    }

    func testMergingKeepsTheNewestPlayOfEachTrackNewestFirst() {
        let phone = [play("1", 300), play("2", 100)]
        let mac = [play("2", 400), play("3", 200)]
        let merged = RecentPlays.merging([phone, mac])
        XCTAssertEqual(merged.map(\.trackID), ["2", "1", "3"])
        XCTAssertEqual(merged.first?.playedAt, anchor.addingTimeInterval(400))
    }

    func testMergingIsOrderIndependentAndIdempotent() {
        let a = [play("1", 10), play("2", 20)]
        let b = [play("2", 20), play("3", 30)]
        let ab = RecentPlays.merging([a, b])
        XCTAssertEqual(ab, RecentPlays.merging([b, a]))
        XCTAssertEqual(ab, RecentPlays.merging([ab, a]))
    }

    func testMergingTrimsToTheLimit() {
        let many = (0..<60).map { play(String($0), TimeInterval($0)) }
        let merged = RecentPlays.merging([many])
        XCTAssertEqual(merged.count, RecentPlays.limit)
        XCTAssertEqual(merged.first?.trackID, "59")
    }

    func testRecentPlayRoundTripsAndToleratesMissingFields() throws {
        let original = play("-42", 5, local: true)
        let decoded = try JSONDecoder().decode(RecentPlay.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)

        let sparse = try JSONDecoder().decode(RecentPlay.self, from: Data(#"{"i":"-7","t":1000}"#.utf8))
        XCTAssertTrue(sparse.isLocal)
        XCTAssertEqual(sparse.title, "")
    }

    func testThirtySecondsOrNinetyPercentQualifies() {
        XCTAssertEqual(PlayQualification.threshold(duration: 300), 30)
        XCTAssertEqual(PlayQualification.threshold(duration: 20), 18, accuracy: 0.001)
        XCTAssertEqual(PlayQualification.threshold(duration: 0), 30)
        XCTAssertEqual(PlayQualification.threshold(duration: .nan), 30)
    }

    func testReplayingTheSameTrackStraightAwayIsNotASecondPlay() {
        let first = anchor
        XCTAssertTrue(PlayQualification.isRepeat(of: first, at: first.addingTimeInterval(60), duration: 300))
        XCTAssertFalse(PlayQualification.isRepeat(of: first, at: first.addingTimeInterval(200), duration: 300))
        XCTAssertFalse(PlayQualification.isRepeat(of: nil, at: first, duration: 300))
    }

    func testOutboxDropsOwnMusicDuplicatesStaleAndExhaustedReports() {
        let now = anchor
        var queue: [PendingPlayReport] = []
        let report = PendingPlayReport(id: "a", trackID: "100", playedAt: now)
        queue = PlayReportOutbox.enqueue(report, into: queue, now: now)
        queue = PlayReportOutbox.enqueue(report, into: queue, now: now)
        queue = PlayReportOutbox.enqueue(PendingPlayReport(id: "b", trackID: "-5", playedAt: now), into: queue, now: now)
        XCTAssertEqual(queue.map(\.id), ["a"])

        let stale = PendingPlayReport(id: "c", trackID: "200", playedAt: now.addingTimeInterval(-PlayReportOutbox.maximumAge - 1))
        let exhausted = PendingPlayReport(id: "d", trackID: "300", playedAt: now, attempts: PlayReportOutbox.maximumAttempts)
        XCTAssertEqual(PlayReportOutbox.pruned(queue + [stale, exhausted], now: now).map(\.id), ["a"])
    }

    func testOutboxKeepsTheNewestWhenFull() {
        let now = anchor
        var queue: [PendingPlayReport] = []
        for index in 0..<(PlayReportOutbox.capacity + 5) {
            queue = PlayReportOutbox.enqueue(
                PendingPlayReport(id: String(index), trackID: String(1_000 + index), playedAt: now),
                into: queue,
                now: now
            )
        }
        XCTAssertEqual(queue.count, PlayReportOutbox.capacity)
        XCTAssertEqual(queue.last?.id, String(PlayReportOutbox.capacity + 4))
    }

    func testPlayHistoryWritesOnlyInvalidatePlayHistory() throws {
        let post = try XCTUnwrap(URL(string: "https://api-v2.soundcloud.com/me/play-history"))
        let history = try XCTUnwrap(URL(string: "https://api-v2.soundcloud.com/me/play-history/tracks?limit=25"))
        let likes = try XCTUnwrap(URL(string: "https://api-v2.soundcloud.com/users/1/track_likes?limit=50"))
        XCTAssertTrue(SoundCloudCachePolicy.invalidates(history, afterMutationOf: post))
        XCTAssertFalse(SoundCloudCachePolicy.invalidates(likes, afterMutationOf: post))

        let like = try XCTUnwrap(URL(string: "https://api-v2.soundcloud.com/users/1/track_likes/2"))
        XCTAssertTrue(SoundCloudCachePolicy.invalidates(likes, afterMutationOf: like))
    }

    private func historyTrack(_ id: String) -> Track {
        let json = """
        {
            "id": \(id),
            "title": "Track \(id)",
            "permalink_url": "https://soundcloud.com/maren/\(id)",
            "created_at": 1756728000000,
            "user": { "id": 1, "username": "maren", "permalink": "maren", "permalink_url": "https://soundcloud.com/maren" },
            "media": { "transcodings": [{
                "url": "https://api-v2.soundcloud.com/media/\(id)/stream",
                "duration": 240000,
                "quality": "hq",
                "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                "preset": "aac_256k"
            }] }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private func entry(_ id: String, _ secondsAfterAnchor: TimeInterval?) -> ListeningHistoryEntry {
        ListeningHistoryEntry(track: historyTrack(id), playedAt: secondsAfterAnchor.map { anchor.addingTimeInterval($0) })
    }

    func testHistoryDropsLocalPlaysSoundCloudAlreadyReported() {
        let remote = [entry("1", 600), entry("2", 100)]
        let local = [entry("1", 590), entry("3", 300), entry("2", 900)]
        let merged = ListeningHistoryMerge.merged(remote: remote, local: local, remoteHasMore: false)
        XCTAssertEqual(merged.map(\.track.id), ["2", "1", "3", "2"])
    }

    func testHistoryKeepsOlderLocalPlaysOutUntilPagingReachesThem() {
        let remote = [entry("1", 600), entry("2", 500)]
        let local = [entry("3", 100)]
        XCTAssertEqual(ListeningHistoryMerge.merged(remote: remote, local: local, remoteHasMore: true).map(\.track.id), ["1", "2"])
        XCTAssertEqual(ListeningHistoryMerge.merged(remote: remote, local: local, remoteHasMore: false).map(\.track.id), ["1", "2", "3"])
    }

    func testUndatedHistoryLeadsAndSuppressesItsOwnTracks() {
        let remote = [entry("1", nil), entry("2", nil)]
        let local = [entry("2", 100), entry("4", 50)]
        let merged = ListeningHistoryMerge.merged(remote: remote, local: local, remoteHasMore: false)
        XCTAssertEqual(merged.map(\.track.id), ["1", "2", "4"])
        let days = ListeningHistoryMerge.days(merged, now: anchor.addingTimeInterval(200))
        XCTAssertEqual(days.first?.title, ListeningHistoryMerge.undatedTitle)
        XCTAssertEqual(days.first?.entries.count, 2)
    }

    func testHistoryDayTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = anchor
        XCTAssertEqual(ListeningHistoryMerge.title(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(ListeningHistoryMerge.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        let older = ListeningHistoryMerge.title(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(older == "Today" || older == "Yesterday" || older.isEmpty)
        let entries = [entry("1", 0), entry("2", -10), entry("3", -86_400)]
        XCTAssertEqual(ListeningHistoryMerge.days(entries, now: now, calendar: calendar).map(\.entries.count), [2, 1])
    }

    func testPlayHistoryContextsDecodeEachKind() throws {
        let json = """
        {"collection":[
            {"played_at":1785611853632,"kind":"system_playlist","context_urn":"soundcloud:system-playlists:track-stations:1","system_playlist":{"urn":"soundcloud:system-playlists:track-stations:1","title":"Station","likes_count":0,"is_public":true,"tracks":[]},"playlist":null,"user":null,"station":null},
            {"played_at":1785611800000,"kind":"user","context_urn":"soundcloud:users:1","user":{"id":1,"username":"maren","permalink":"maren","permalink_url":"https://soundcloud.com/maren"},"playlist":null,"system_playlist":null,"station":null},
            {"played_at":1785611700000,"kind":"playlist","context_urn":"soundcloud:playlists:9","playlist":null,"user":null,"system_playlist":null,"station":null}
        ],"next_href":null}
        """
        let page = try JSONDecoder().decode(Page<PlayHistoryContext>.self, from: Data(json.utf8))
        XCTAssertEqual(page.collection.count, 2)
        guard case .station = page.collection[0].entry, case .user = page.collection[1].entry else {
            return XCTFail("Unexpected kinds")
        }
        let roundTrip = try JSONDecoder().decode(PlayHistoryContext.self, from: JSONEncoder().encode(page.collection[1]))
        XCTAssertEqual(roundTrip.id, page.collection[1].id)
    }

    func testRecentlyPlayedReferencesAcceptBothShapes() throws {
        let list = #"[{"id":5,"urn":"soundcloud:tracks:5"},{"urn":"soundcloud:tracks:7"},{"id":5}]"#
        XCTAssertEqual(try JSONDecoder().decode(SoundCloudTrackReferences.self, from: Data(list.utf8)).ids, ["5", "7"])
        let page = #"{"collection":[{"id":9}],"next_href":null}"#
        XCTAssertEqual(try JSONDecoder().decode(SoundCloudTrackReferences.self, from: Data(page.utf8)).ids, ["9"])
    }
}
