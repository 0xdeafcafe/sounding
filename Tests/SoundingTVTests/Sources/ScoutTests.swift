import Foundation
import XCTest
@testable import SoundingTV

final class ScoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func artist(_ id: String, followed: Bool = true, enabled: Bool = true, addedAt: Date? = nil) -> ScoutArtist {
        ScoutArtist(id: id, name: "Night Tapes", permalinkURL: nil, avatarURL: nil, isEnabled: enabled, isFollowed: followed, addedAt: addedAt ?? start.addingTimeInterval(-86_400))
    }

    private func post(_ id: String, artist: String = "a", minutes: Double = 4, at offset: TimeInterval = -600, kind: ScoutPost.Kind = .track) -> ScoutPost {
        ScoutPost(kind: kind, itemID: id, artistID: artist, artistName: "Night Tapes", title: "Title \(id)", duration: minutes * 60, postedAt: start.addingTimeInterval(offset))
    }

    // MARK: - Change detection

    func testNewPostFromScoutedArtistAlerts() {
        var ledger = ScoutLedger()
        let alerts = ScoutDetector.detect([post("1", minutes: 121)], scouts: [artist("a")], ledger: &ledger, now: start)
        XCTAssertEqual(alerts.map(\.title), ["Night Tapes just posted a 2-hour set"])
        XCTAssertEqual(alerts.first?.itemID, "1")
        XCTAssertEqual(alerts.first?.body, "Title 1")
    }

    func testSeenPostsNeverAlertTwice() {
        var ledger = ScoutLedger()
        _ = ScoutDetector.detect([post("1")], scouts: [artist("a")], ledger: &ledger, now: start)
        let again = ScoutDetector.detect([post("1")], scouts: [artist("a")], ledger: &ledger, now: start.addingTimeInterval(7200))
        XCTAssertTrue(again.isEmpty)
    }

    func testPostsBeforeScoutingStartedAreBaseline() {
        var ledger = ScoutLedger()
        let scouted = artist("a", addedAt: start.addingTimeInterval(-60))
        let alerts = ScoutDetector.detect([post("old", at: -3600)], scouts: [scouted], ledger: &ledger, now: start)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertTrue(ledger.seenPostIDs.contains("track:old"))
    }

    func testOldTracksRepostedLaterDoNotAlert() {
        var ledger = ScoutLedger()
        let scouted = artist("a", addedAt: start.addingTimeInterval(-30 * 86_400))
        let alerts = ScoutDetector.detect([post("1", at: -4 * 86_400)], scouts: [scouted], ledger: &ledger, now: start)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testUnscoutedAndDisabledArtistsAreIgnored() {
        var ledger = ScoutLedger()
        let alerts = ScoutDetector.detect(
            [post("1", artist: "other"), post("2", artist: "b")],
            scouts: [artist("a"), artist("b", enabled: false)],
            ledger: &ledger,
            now: start
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testCopyNamesTheKindOfPost() {
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", minutes: 4)), "a new track")
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", minutes: 60)), "a 1-hour set")
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", minutes: 90)), "a 90-minute set")
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", minutes: 45)), "a 45-minute set")
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", minutes: 178)), "a 3-hour set")
        XCTAssertEqual(ScoutCopy.phrase(for: post("1", kind: .playlist)), "a new release")
    }

    // MARK: - Coalescing

    func testSeveralPostsInOneCheckBecomeOneAlertForTheSet() {
        var ledger = ScoutLedger()
        let alerts = ScoutDetector.detect(
            [post("t1", minutes: 4), post("set", minutes: 120, at: -1200), post("t2", minutes: 5, at: -60)],
            scouts: [artist("a")],
            ledger: &ledger,
            now: start
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.itemID, "set")
    }

    func testAtMostOneAlertPerArtistPerHour() {
        var ledger = ScoutLedger()
        var delivered = 0
        for minute in stride(from: 0, to: 180, by: 10) {
            let now = start.addingTimeInterval(TimeInterval(minute) * 60)
            let fresh = ScoutPost(kind: .track, itemID: "p\(minute)", artistID: "a", artistName: "Night Tapes", title: "x", duration: 240, postedAt: now.addingTimeInterval(-30))
            delivered += ScoutDetector.detect([fresh], scouts: [artist("a")], ledger: &ledger, now: now).count
        }
        XCTAssertEqual(delivered, 3)
    }

    func testCoalescingIsPerArtist() {
        var ledger = ScoutLedger()
        let alerts = ScoutDetector.detect(
            [post("1", artist: "a"), post("2", artist: "b")],
            scouts: [artist("a"), artist("b")],
            ledger: &ledger,
            now: start
        )
        XCTAssertEqual(Set(alerts.map(\.artistID)), ["a", "b"])
    }

    // MARK: - Budget

    func testNoScoutsMeansNoRequests() {
        XCTAssertTrue(ScoutPlanner.plan(scouts: [], ledger: ScoutLedger(), now: start).isEmpty)
        XCTAssertTrue(ScoutPlanner.plan(scouts: [artist("a", enabled: false)], ledger: ScoutLedger(), now: start).isEmpty)
    }

    func testFollowedArtistsShareOneFeedRequest() {
        let scouts = (0..<40).map { artist("a\($0)") }
        XCTAssertEqual(ScoutPlanner.plan(scouts: scouts, ledger: ScoutLedger(), now: start), [.feed, .search("a0")])
    }

    func testAFeedSeenRecentlySkipsTheCheck() {
        var ledger = ScoutLedger()
        ledger.lastFeedSeenAt = start.addingTimeInterval(-5 * 60)
        XCTAssertTrue(ScoutPlanner.plan(scouts: [artist("a")], ledger: ledger, now: start).isEmpty)
    }

    func testScoutCannotExceedItsBudgetHoweverOftenItIsWoken() async {
        let scouts = (0..<25).map { artist("u\($0)", followed: false) } + (0..<25).map { artist("f\($0)") }
        let budget = ScoutBudget.standard
        let recorder = RequestRecorder()
        var ledger = ScoutLedger()
        for second in stride(from: 0, to: 24 * 3600, by: 15) {
            let now = start.addingTimeInterval(TimeInterval(second))
            let outcome = await ScoutRunner.run(scouts: scouts, ledger: ledger, budget: budget, now: now) { step in
                recorder.record(step, at: now)
                return ScoutFetchResult(posts: [])
            }
            ledger = outcome.ledger
        }
        let times = recorder.times
        XCTAssertGreaterThan(times.count, 0)
        XCTAssertLessThanOrEqual(maxPerWindow(times, 3600), budget.requestsPerHour)
        XCTAssertLessThanOrEqual(maxPerWindow(times, 60), 1 + budget.artistLookupsPerCheck + budget.searchesPerCheck)
        let backgroundPerHour = await MainActor.run { SoundCloudTrafficScenarioTests.backgroundPerHour }
        let backgroundPerMinute = await MainActor.run { SoundCloudTrafficScenarioTests.backgroundPerMinute }
        XCTAssertLessThanOrEqual(maxPerWindow(times, 3600), backgroundPerHour)
        XCTAssertLessThanOrEqual(maxPerWindow(times, 60), backgroundPerMinute)
        XCTAssertLessThanOrEqual(recorder.feedCount, 24 * 3600 / Int(budget.minimumFeedInterval) + 1)
    }

    func testAFailedRequestStopsTheCheck() async {
        let scouts = [artist("u1", followed: false), artist("f1")]
        let recorder = RequestRecorder()
        let now = start
        let outcome = await ScoutRunner.run(scouts: scouts, ledger: ScoutLedger(), now: now) { step in
            recorder.record(step, at: now)
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(recorder.times.count, 1)
        XCTAssertEqual(outcome.requestsMade, 1)
    }

    func testFeedTeachesWhichScoutsAreFollowed() async {
        let scouts = [artist("u1", followed: false)]
        let outcome = await ScoutRunner.run(scouts: scouts, ledger: ScoutLedger(), now: start) { _ in
            ScoutFetchResult(posts: [], followedArtistIDs: ["u1"])
        }
        XCTAssertEqual(outcome.followedArtistIDs, ["u1"])
    }

    private func maxPerWindow(_ times: [Date], _ window: TimeInterval) -> Int {
        let sorted = times.sorted()
        var best = 0
        var lower = 0
        for upper in sorted.indices {
            while sorted[upper].timeIntervalSince(sorted[lower]) >= window { lower += 1 }
            best = max(best, upper - lower + 1)
        }
        return best
    }
}

@MainActor
final class ScoutTrafficScenarioTests: XCTestCase {
    func testADayOfScoutChecksThroughTheGatewayStaysUnderTheBackgroundCeilings() async {
        let clock = TrafficVirtualClock()
        let fake = FakeSoundCloud(clock: clock)
        let name = "ScoutTrafficScenarioTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let gateway = SoundCloudGateway(
            transport: fake.transport,
            defaults: UserDefaults(suiteName: name)!,
            random: { 0.5 },
            now: { clock.now },
            sleep: { await clock.sleep($0) }
        )
        gateway.setApplicationActivity(.background)
        let scouts = (0..<30).map {
            ScoutArtist(id: "\($0)", name: "Artist \($0)", permalinkURL: nil, avatarURL: nil, isEnabled: true, isFollowed: $0 % 2 == 0, addedAt: clock.start)
        }
        var ledger = ScoutLedger()
        for minute in 0..<(24 * 60) {
            clock.advance(to: clock.start.addingTimeInterval(TimeInterval(minute) * 60))
            let outcome = await ScoutRunner.run(scouts: scouts, ledger: ledger, now: clock.now) { step in
                let path: String
                switch step {
                case .feed: path = "stream?limit=50"
                case .artist(let id): path = "users/\(id)/tracks?limit=10"
                case .search: path = "search/tracks?limit=20"
                }
                var request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/\(path)")!)
                request.setValue("OAuth scenario", forHTTPHeaderField: "Authorization")
                request.setValue(SoundCloudRequestIntent.autonomous.rawValue, forHTTPHeaderField: FakeSoundCloud.intentHeader)
                _ = try await gateway.data(for: request, context: .init(intent: .autonomous, lane: .feed, allowsBackground: true))
                return ScoutFetchResult(posts: [])
            }
            ledger = outcome.ledger
        }
        let background: (FakeSoundCloud.Wire) -> Bool = { $0.intent == "autonomous" }
        XCTAssertGreaterThan(fake.api.count, 0)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(3600, where: background), ScoutBudget.standard.requestsPerHour)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(3600, where: background), SoundCloudTrafficScenarioTests.backgroundPerHour)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(60, where: background), SoundCloudTrafficScenarioTests.backgroundPerMinute)
        XCTAssertEqual(fake.all.filter { $0.status == 429 }.count, 0)
        XCTAssertEqual(fake.api.filter { $0.path == "/stream" }.count, fake.api.filter { $0.path.hasPrefix("/stream") }.count)
        let searches = fake.api.filter { $0.path == "/search/tracks" }
        XCTAssertGreaterThanOrEqual(searches.count, 30, "every scouted artist is searched at least once a day")
        XCTAssertLessThanOrEqual(searches.count, 30 * Int(24 * 3600 / ScoutBudget.standard.searchInterval), "an artist is searched at most every 12 hours")
    }
}

final class ScoutSearchMatcherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func scout(_ id: String = "nt", name: String = "Night Tapes", followed: Bool = true) -> ScoutArtist {
        ScoutArtist(id: id, name: name, permalinkURL: nil, avatarURL: nil, isEnabled: true, isFollowed: followed, addedAt: start.addingTimeInterval(-86_400))
    }

    private func candidate(
        _ title: String,
        id: String = "900",
        by uploader: String = "Rinse FM",
        uploaderID: String = "rinse",
        minutes: Double = 120,
        description: String? = nil,
        at offset: TimeInterval = -3600
    ) -> ScoutCandidate {
        ScoutCandidate(itemID: id, title: title, description: description, uploaderID: uploaderID, uploaderName: uploader, duration: minutes * 60, postedAt: start.addingTimeInterval(offset))
    }

    private func reason(_ title: String, name: String = "Night Tapes", by uploader: String = "Rinse FM", description: String? = nil, minutes: Double = 120) -> String? {
        ScoutSearchMatcher.match(candidate(title, by: uploader, minutes: minutes, description: description), artistName: name).map(ScoutCopy.reason(for:))
    }

    // MARK: - Patterns

    func testBackToBackPatternsNameThePartnerAndTheUploader() {
        XCTAssertEqual(reason("Night Tapes b2b Maya Sol at Fabric"), "b2b with Maya Sol, posted by Rinse FM")
        XCTAssertEqual(reason("Maya Sol B2B Night Tapes - Boiler Room London"), "b2b with Maya Sol, posted by Rinse FM")
        XCTAssertEqual(reason("Night Tapes back to back with Maya Sol & Theo Moss"), "b2b with Maya Sol and Theo Moss, posted by Rinse FM")
        XCTAssertEqual(reason("Night Tapes x Maya Sol (Live)"), "b2b with Maya Sol, posted by Rinse FM")
        XCTAssertEqual(reason("Maya Sol & Night Tapes | Dekmantel 2026"), "b2b with Maya Sol, posted by Rinse FM")
        XCTAssertEqual(reason("Nïght Tapes b2b Maya Sol"), "b2b with Maya Sol, posted by Rinse FM")
    }

    func testPartnerWhoPostedItIsNotNamedTwice() {
        XCTAssertEqual(reason("Night Tapes b2b Maya Sol", by: "Maya Sol"), "b2b with Maya Sol")
    }

    func testPromoterPostedSetsCountAsMentions() {
        XCTAssertEqual(reason("Boiler Room London: Night Tapes"), "Posted by Rinse FM")
        XCTAssertEqual(reason("Night Tapes & Friends"), "Posted by Rinse FM")
    }

    func testDescriptionOnlyCountsForAnExplicitBackToBack() {
        XCTAssertEqual(reason("Rinse FM 12.03.2026", description: "Maya Sol b2b Night Tapes\nTracklist:"), "b2b with Maya Sol, posted by Rinse FM")
        XCTAssertNil(reason("Rinse FM 12.03.2026", description: "Tracklist:\nNight Tapes - Wavelength"))
    }

    // MARK: - False positives

    func testFalsePositivesAreFiltered() {
        XCTAssertNil(reason("Night Tapes b2b Maya Sol", minutes: 5), "short tracks are remixes and edits, not sets")
        XCTAssertNil(reason("Tribute to Night Tapes"))
        XCTAssertNil(reason("Below Sunrise Mix", name: "Low Sun"), "names match whole words only")
        XCTAssertNil(reason("Night Tapesque Mix"))
        XCTAssertNil(reason("Kim", name: "Kim"), "short single-word names need a b2b")
        XCTAssertEqual(reason("Kim b2b Okari", name: "Kim"), "b2b with Okari, posted by Rinse FM")
        XCTAssertNil(reason("Night Tapes b2b Maya Sol", by: "Night Tapes"), "the artist's own uploads come from the feed")
        XCTAssertFalse(ScoutSearchMatcher.isSearchable("DJ"))
        XCTAssertFalse(ScoutSearchMatcher.isSearchable("A1"))
    }

    // MARK: - Planning and detection

    func testEachCheckSearchesTheLeastRecentlySearchedArtist() {
        var ledger = ScoutLedger()
        ledger.lastArtistSearch = ["a": start.addingTimeInterval(-13 * 3600), "b": start.addingTimeInterval(-20 * 3600)]
        let scouts = [scout("a", name: "Night Tapes"), scout("b", name: "Maya Sol"), scout("c", name: "DJ")]
        XCTAssertEqual(ScoutPlanner.plan(scouts: scouts, ledger: ledger, now: start), [.feed, .search("b")])
        ledger.lastArtistSearch["b"] = start.addingTimeInterval(-3600)
        ledger.lastArtistSearch["a"] = start.addingTimeInterval(-3600)
        XCTAssertEqual(ScoutPlanner.plan(scouts: scouts, ledger: ledger, now: start), [.feed])
    }

    func testSearchFindAlertsWithItsReason() async {
        let candidates = [
            candidate("Maya Sol b2b Night Tapes - Boiler Room London", id: "1"),
            candidate("Night Tapes - Wavelength (Maya Sol Remix)", id: "2", minutes: 6),
        ]
        let outcome = await ScoutRunner.run(scouts: [scout()], ledger: ScoutLedger(), now: start) { step in
            if case .search("nt") = step { return ScoutFetchResult(posts: [], candidates: candidates) }
            return ScoutFetchResult(posts: [])
        }
        XCTAssertEqual(outcome.alerts.count, 1)
        XCTAssertEqual(outcome.alerts.first?.itemID, "1")
        XCTAssertEqual(outcome.alerts.first?.title, "Night Tapes is on a 2-hour set")
        XCTAssertEqual(outcome.alerts.first?.body, "Maya Sol b2b Night Tapes - Boiler Room London")
        XCTAssertEqual(outcome.alerts.first?.reason, "b2b with Maya Sol, posted by Rinse FM")
    }

    func testSearchFindsAlreadySeenInTheFeedDoNotAlertTwice() {
        let scouts = [scout("nt", name: "Night Tapes"), scout("ms", name: "Maya Sol")]
        let set = candidate("Night Tapes b2b Maya Sol", id: "42", by: "Maya Sol", uploaderID: "ms")
        var ledger = ScoutLedger()
        let feedPost = ScoutPost(kind: .track, itemID: "42", artistID: "ms", artistName: "Maya Sol", title: set.title, duration: set.duration, postedAt: set.postedAt)
        XCTAssertEqual(ScoutDetector.detect([feedPost], scouts: scouts, ledger: &ledger, now: start).count, 1)
        let found = ScoutSearchMatcher.posts(from: [set, set], for: scouts[0])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(ScoutDetector.detect(found, scouts: scouts, ledger: &ledger, now: start.addingTimeInterval(7200)).isEmpty)
    }

    func testOldFindsNeverAlert() {
        var ledger = ScoutLedger()
        let posts = ScoutSearchMatcher.posts(from: [candidate("Night Tapes b2b Maya Sol", at: -5 * 86_400)], for: scout())
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(ScoutDetector.detect(posts, scouts: [scout()], ledger: &ledger, now: start).isEmpty)
    }

    func testLedgersSavedBeforeSearchStillDecode() throws {
        let legacy = Data(#"{"seenPostIDs":["track:1"],"lastAlertAt":{},"lastArtistLookup":{},"requests":[]}"#.utf8)
        let ledger = try JSONDecoder().decode(ScoutLedger.self, from: legacy)
        XCTAssertEqual(ledger.seenPostIDs, ["track:1"])
        XCTAssertTrue(ledger.lastArtistSearch.isEmpty)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ScoutFetch, Date)] = []

    func record(_ step: ScoutFetch, at date: Date) {
        lock.lock()
        entries.append((step, date))
        lock.unlock()
    }

    var times: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.1)
    }

    var feedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.0 == .feed }.count
    }
}
