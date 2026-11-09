import Foundation
import XCTest
@testable import SoundingTV

final class TrafficVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var start: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func advance(to target: Date) {
        lock.lock()
        if target > current { current = target }
        lock.unlock()
    }

    func sleep(_ seconds: TimeInterval) async {
        let target = now.addingTimeInterval(max(0, seconds))
        await Task.yield()
        advance(to: target)
    }
}

final class FakeSoundCloud: @unchecked Sendable {
    struct Wire {
        let at: Date
        let host: String
        let path: String
        let intent: String
        let status: Int
    }

    static let intentHeader = "X-Traffic-Intent"

    private let lock = NSLock()
    private let clock: TrafficVirtualClock
    private var wires: [Wire] = []
    var latency: TimeInterval = 0.12
    var serverLimitPerMinute: Int?
    var rateLimits: @Sendable (URLRequest) -> Bool = { _ in false }
    var notFound: @Sendable (URLRequest) -> Bool = { _ in false }

    init(clock: TrafficVirtualClock) {
        self.clock = clock
    }

    var transport: SoundCloudHTTPTransport {
        SoundCloudHTTPTransport { [self] request in
            let started = clock.now
            let status = record(request, at: started)
            await clock.sleep(latency)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = status == 200 ? Data(#"{"collection":[],"next_href":null}"#.utf8) : Data("{}".utf8)
            return (body, response)
        }
    }

    private func record(_ request: URLRequest, at date: Date) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let host = request.url?.host ?? ""
        var status = rateLimits(request) ? 429 : (notFound(request) ? 404 : 200)
        if status == 200, let limit = serverLimitPerMinute, SoundCloudEndpoint.isAPIHost(host) {
            let recent = wires.filter { SoundCloudEndpoint.isAPIHost($0.host) && date.timeIntervalSince($0.at) < 60 }.count
            if recent >= limit { status = 429 }
        }
        wires.append(Wire(
            at: date,
            host: host,
            path: request.url?.path ?? "",
            intent: request.value(forHTTPHeaderField: Self.intentHeader) ?? "userInitiated",
            status: status
        ))
        return status
    }

    var all: [Wire] {
        lock.lock()
        defer { lock.unlock() }
        return wires
    }

    var api: [Wire] { all.filter { SoundCloudEndpoint.isAPIHost($0.host) } }

    func maxPerWindow(_ window: TimeInterval, where include: (Wire) -> Bool = { _ in true }) -> Int {
        let times = api.filter(include).map(\.at).sorted()
        var best = 0
        var lower = 0
        for upper in times.indices {
            while times[upper].timeIntervalSince(times[lower]) >= window { lower += 1 }
            best = max(best, upper - lower + 1)
        }
        return best
    }

    func perMinute(where include: (Wire) -> Bool = { _ in true }) -> [Int] {
        guard let first = api.first?.at else { return [] }
        var buckets: [Int: Int] = [:]
        for wire in api where include(wire) {
            buckets[Int(wire.at.timeIntervalSince(first) / 60), default: 0] += 1
        }
        let last = buckets.keys.max() ?? 0
        return (0...last).map { buckets[$0] ?? 0 }
    }
}

@MainActor
final class TrafficTaskBatch {
    private var tasks: [Task<Void, Never>] = []

    func addTask(_ job: @escaping @MainActor () async -> Void) {
        tasks.append(Task { @MainActor in await job() })
    }

    func wait() async {
        for task in tasks { await task.value }
    }
}

@MainActor
func concurrently(_ build: (TrafficTaskBatch) -> Void) async {
    let batch = TrafficTaskBatch()
    build(batch)
    await batch.wait()
}

@MainActor
final class SoundCloudTrafficScenarioTests: XCTestCase {
    static let interactivePerMinute = 36
    static let perHour = 900
    static let backgroundPerMinute = 12
    static let backgroundPerHour = 180

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    fileprivate struct Rig {
        let clock: TrafficVirtualClock
        let fake: FakeSoundCloud
        let gateway: SoundCloudGateway
    }

    private func makeRig(configure: (FakeSoundCloud) -> Void = { _ in }) -> Rig {
        let clock = TrafficVirtualClock()
        let fake = FakeSoundCloud(clock: clock)
        configure(fake)
        let name = "SoundCloudTrafficScenarioTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let gateway = SoundCloudGateway(
            transport: fake.transport,
            defaults: UserDefaults(suiteName: name)!,
            random: { 0.5 },
            now: { clock.now },
            sleep: { await clock.sleep($0) }
        )
        gateway.setApplicationActivity(.foreground)
        return Rig(clock: clock, fake: fake, gateway: gateway)
    }

    @discardableResult
    private func get(
        _ rig: Rig,
        _ path: String,
        host: String = "api-v2.soundcloud.com",
        intent: SoundCloudRequestIntent = .userInitiated,
        lane: SoundCloudRequestLane = .metadata
    ) async -> Int? {
        await Self.send(rig, path, host: host, intent: intent, lane: lane)
    }

    fileprivate static func send(
        _ rig: Rig,
        _ path: String,
        host: String = "api-v2.soundcloud.com",
        intent: SoundCloudRequestIntent = .userInitiated,
        lane: SoundCloudRequestLane = .metadata
    ) async -> Int? {
        var request = URLRequest(url: URL(string: "https://\(host)/\(path)")!)
        request.setValue("OAuth scenario", forHTTPHeaderField: "Authorization")
        request.setValue(intent.rawValue, forHTTPHeaderField: FakeSoundCloud.intentHeader)
        return try? await rig.gateway.data(for: request, context: .init(intent: intent, lane: lane)).1.statusCode
    }

    private func report(_ name: String, _ rig: Rig) {
        let fake = rig.fake
        let minutes = fake.perMinute()
        print("[TrafficScenario] \(name): api=\(fake.api.count) maxPerMinute=\(fake.maxPerWindow(60)) maxPerHour=\(fake.maxPerWindow(3600)) background maxPerMinute=\(fake.maxPerWindow(60) { $0.intent == "autonomous" }) perMinute=\(minutes) 429s=\(fake.all.filter { $0.status == 429 }.count)")
    }

    private func assertCeilings(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let fake = rig.fake
        XCTAssertLessThanOrEqual(fake.maxPerWindow(60), Self.interactivePerMinute, "per-minute ceiling", file: file, line: line)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(3600), Self.perHour, "per-hour ceiling", file: file, line: line)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(60) { $0.intent == "autonomous" }, Self.backgroundPerMinute, "background per-minute ceiling", file: file, line: line)
        XCTAssertLessThanOrEqual(fake.maxPerWindow(3600) { $0.intent == "autonomous" }, Self.backgroundPerHour, "background per-hour ceiling", file: file, line: line)
    }

    // MARK: - Scenarios

    func testFirstLaunchWithTwoThousandLikes() async {
        let rig = makeRig { $0.serverLimitPerMinute = 60 }
        let launch = [
            "me", "me/library/all", "stream", "mixed-selections", "charts/selections",
            "me/play-history/tracks", "users/900/playlists", "users/900/track_likes",
            "me/followings", "system-playlists/soundcloud:system-playlists:weekly",
        ]
        await concurrently { group in
            for path in launch {
                group.addTask { @MainActor in await Self.send(rig, path, lane: path == "stream" ? .feed : .metadata) }
            }
        }

        let browse = Task { @MainActor in
            await rig.clock.sleep(30)
            for page in 1...12 {
                await Self.send(rig, "users/900/track_likes?offset=\(page * 50)")
                await rig.clock.sleep(3)
            }
        }

        var likesPages = 0
        for segment in 0..<4 {
            let segmentStart = rig.clock.start.addingTimeInterval(4 + Double(segment) * 15 * 60)
            rig.clock.advance(to: segmentStart)
            for _ in 0..<5 where likesPages < 20 {
                if await get(rig, "users/900/track_likes?limit=100&offset=\(likesPages * 100)", intent: .autonomous) == 200 {
                    likesPages += 1
                }
                await rig.clock.sleep(0.5)
            }
        }
        await browse.value
        rig.clock.advance(to: rig.clock.start.addingTimeInterval(3600))

        report("first launch, 2,000 likes, 1 hour", rig)
        assertCeilings(rig)
        XCTAssertEqual(likesPages, 20, "the likes index finishes within the hour")
        XCTAssertEqual(rig.fake.all.filter { $0.status == 429 }.count, 0)
        XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready)
    }

    func testSpotlightIndexingHydratesFromTheLibraryNotTheNetwork() async {
        let rig = makeRig()
        let likes = (0..<2_000).map { Self.track(String(100_000 + $0)) }
        let remote = GatewayRemoteCatalog(rig: rig)
        let catalog = LiveSoundingEntityCatalog(remote: remote, local: LikesOnlyLocal(likes: likes))

        let indexed = try? await catalog.tracks(ids: likes.map(\.id))
        XCTAssertEqual(indexed?.count, 2_000)
        XCTAssertEqual(rig.fake.api.count, 0, "indexed likes resolve from the library")

        _ = try? await catalog.tracks(ids: (0..<400).map { String(900_000 + $0) })
        _ = try? await catalog.artists(ids: (0..<60).map { String(800_000 + $0) })
        _ = try? await catalog.playlists(ids: (0..<60).map { String(700_000 + $0) })

        report("Spotlight hydration of 2,000 likes, 400 unknown tracks, 60 artists, 60 playlists", rig)
        XCTAssertLessThanOrEqual(rig.fake.api.count, 1 + 5 + 5, "unknown entities never fan out per item")
        assertCeilings(rig)
    }

    func testSiriRequestsSpendAtMostOneSearchEach() async {
        let rig = makeRig()
        let likes = (0..<500).map { Self.track(String(100_000 + $0), title: "Liked \($0)") }
        let remote = GatewayRemoteCatalog(rig: rig)
        let resolver = MediaRequestResolver(
            local: LikesOnlyLocal(likes: likes),
            remote: remote,
            remoteBudget: 1,
            remoteAllowed: { true }
        )
        let phrases = [
            "my likes", "Liked 3", "Liked 42", "something new by Maren", "a set by Okari",
            "Frontier", "the playlist Late Night", "Liked 7 by Maren", "an album by Someone",
            "music like this", "Driving playlist", "Liked 499", "Ambient Works", "Deep house",
            "Okari", "Liked 120", "my last liked set", "Midnight", "Liked 250", "Run",
        ]
        for phrase in phrases {
            let before = rig.fake.api.count
            _ = try? await resolver.resolve(MediaRequest.parse(phrase))
            XCTAssertLessThanOrEqual(rig.fake.api.count - before, 1, phrase)
            await rig.clock.sleep(20)
        }
        report("20 Siri requests", rig)
        assertCeilings(rig)
    }

    func testTenMinutesOfNowPlayingWithLiveActivityAndHomeLighting() async {
        let rig = makeRig()
        let tracks = ["1001", "1002", "1003"]
        for (index, id) in tracks.enumerated() {
            rig.clock.advance(to: rig.clock.start.addingTimeInterval(Double(index) * 200))
            await get(rig, "media/soundcloud:tracks:\(id)/x/stream/hls", intent: .playback, lane: .streamResolution)
            await concurrently { group in
                for _ in 0..<3 {
                    group.addTask { @MainActor in
                        await Self.send(rig, "\(id)_m.json", host: "wave.sndcdn.com", intent: .playback, lane: .waveform)
                    }
                }
                group.addTask { @MainActor in
                    for page in 0..<6 {
                        await Self.send(rig, "tracks/\(id)/comments?offset=\(page * 100)")
                    }
                }
            }
            if index + 1 < tracks.count {
                await get(rig, "media/soundcloud:tracks:\(tracks[index + 1])/x/stream/hls", intent: .playback, lane: .streamResolution)
            } else {
                await get(rig, "tracks/\(id)/related", intent: .playback)
            }
        }
        rig.clock.advance(to: rig.clock.start.addingTimeInterval(600))

        report("10 minutes of Now Playing, Live Activity and Home Lighting", rig)
        assertCeilings(rig)
        XCTAssertEqual(rig.fake.all.filter { $0.host == "wave.sndcdn.com" }.count, tracks.count, "Now Playing, Home Lighting and analysis share one waveform fetch")
        XCTAssertLessThanOrEqual(rig.fake.api.count, 30)
    }

    func testRemoteWithTwoTVsOnlyFetchesWhenPlaybackMovesHere() async {
        let rig = makeRig()
        for minute in 0..<10 {
            rig.clock.advance(to: rig.clock.start.addingTimeInterval(Double(minute) * 60))
        }
        let queue = (0..<140).map { String(300_000 + $0) }
        for offset in stride(from: 0, to: queue.count, by: 50) {
            let batch = queue[offset..<min(offset + 50, queue.count)].joined(separator: ",")
            await get(rig, "tracks?ids=\(batch)")
        }
        report("Remote with two Apple TVs, then Play Here", rig)
        XCTAssertEqual(rig.fake.api.count, 3, "two TVs' status is local; moving playback here is one batch per 50 tracks")
        assertCeilings(rig)
    }

    func testFanOutBugIsHeldUnderTheCeilings() async {
        let rig = makeRig()
        await concurrently { group in
            for id in 0..<150 {
                group.addTask { @MainActor in await Self.send(rig, "tracks/\(500_000 + id)") }
            }
            for id in 0..<60 {
                group.addTask { @MainActor in await Self.send(rig, "users/\(600_000 + id)", intent: .autonomous) }
            }
        }
        report("fan-out of 150 interactive and 60 background requests", rig)
        assertCeilings(rig)
    }

    func testRevisitingAnArtistDoesNotRecheckFollowState() async {
        let rig = makeRig { $0.notFound = { $0.url?.path.contains("/followings/") == true } }
        for visit in 0..<8 {
            rig.clock.advance(to: rig.clock.start.addingTimeInterval(Double(visit) * 45))
            await get(rig, "users/900/followings/101")
            await get(rig, "users/101")
        }
        report("8 visits to one artist in 6 minutes", rig)
        XCTAssertEqual(rig.fake.api.filter { $0.path.contains("/followings/") }.count, 1, "not following is remembered")
        XCTAssertEqual(rig.fake.api.count, 2)
    }

    func testSystemEntityHydrationIsBackgroundWork() async {
        let rig = makeRig { $0.rateLimits = { _ in true } }
        let intent = await SoundCloudRequestEnvironment.systemInitiated { SoundCloudRequestContext.current().intent }
        let allowsBackground = await SoundCloudRequestEnvironment.systemInitiated { SoundCloudRequestContext.current().allowsBackground }
        XCTAssertEqual(intent, .autonomous)
        XCTAssertTrue(allowsBackground)
        await get(rig, "users/101", intent: intent)
        XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready, "a rate-limited Siri or Spotlight lookup never stops the app")
    }

    // MARK: - Rate limit behaviour

    func testBackgroundRateLimitsNeverStopTheUser() async {
        let rig = makeRig { fake in
            fake.rateLimits = { $0.value(forHTTPHeaderField: FakeSoundCloud.intentHeader) == "autonomous" }
        }
        for minute in 0..<30 {
            rig.clock.advance(to: rig.clock.start.addingTimeInterval(Double(minute) * 60))
            await get(rig, "users/900/track_likes?limit=100", intent: .autonomous)
            let status = await get(rig, "tracks/\(minute)")
            XCTAssertEqual(status, 200, "minute \(minute)")
            XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready)
        }
        report("30 minutes with SoundCloud refusing background work", rig)
        XCTAssertLessThanOrEqual(rig.fake.all.filter { $0.status == 429 }.count, 10, "background backs off between strikes")
    }

    func testABurstOfInteractiveRateLimitsStopsBriefly() async {
        let rig = makeRig { $0.rateLimits = { _ in true } }
        await concurrently { group in
            for path in ["me", "stream", "users/900/tracks", "users/900/playlists", "users/900/reposts", "users/900/likes"] {
                group.addTask { @MainActor in await Self.send(rig, path) }
            }
        }
        guard case .waiting(_, let until) = rig.gateway.trafficSafetyState() else {
            return XCTFail("an interactive 429 stops traffic")
        }
        XCTAssertLessThanOrEqual(until.timeIntervalSince(rig.clock.now), 2 * 60 + 1, "concurrent 429s from one burst count as one strike")
    }

    func testBackgroundStrikesDoNotLengthenTheInteractiveStop() async {
        let rig = makeRig { $0.rateLimits = { _ in true } }
        for episode in 0..<4 {
            await get(rig, "users/900/track_likes", intent: .autonomous)
            let paused = rig.gateway.backgroundWorkPausedUntil ?? rig.clock.now
            rig.clock.advance(to: paused.addingTimeInterval(1))
            XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready, "episode \(episode)")
        }
        await get(rig, "stream", lane: .feed)
        guard case .waiting(_, let until) = rig.gateway.trafficSafetyState() else {
            return XCTFail("an interactive 429 stops traffic")
        }
        XCTAssertLessThanOrEqual(until.timeIntervalSince(rig.clock.now), 2 * 60 + 1)
    }

    func testWaveformRateLimitPausesOnlyWaveforms() async {
        let rig = makeRig { $0.rateLimits = { $0.url?.host == "wave.sndcdn.com" } }
        await get(rig, "1_m.json", host: "wave.sndcdn.com", intent: .playback, lane: .waveform)
        XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready)
        XCTAssertNil(rig.gateway.backgroundWorkPausedUntil)
        let held = await get(rig, "2_m.json", host: "wave.sndcdn.com", intent: .playback, lane: .waveform)
        XCTAssertNil(held, "waveforms wait out their own pause")
        let browse = await get(rig, "tracks/1")
        XCTAssertEqual(browse, 200)
    }

    func testTokenEndpointRateLimitDoesNotStopTraffic() async {
        let rig = makeRig { $0.rateLimits = { $0.url?.host == "secure.soundcloud.com" } }
        var request = URLRequest(url: URL(string: "https://secure.soundcloud.com/oauth/token")!)
        request.httpMethod = "POST"
        _ = try? await rig.gateway.data(for: request, context: .init(lane: .authentication, coalesces: false))
        XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready)
        do {
            _ = try await rig.gateway.data(for: request, context: .init(lane: .authentication, coalesces: false))
            XCTFail("token refresh retried during its own pause")
        } catch SoundCloudGatewayError.endpointCoolingDown {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(rig.fake.all.count, 1)
    }

    func testPlaysBucketFromBackgroundDoesNotStopTheUser() async {
        let rig = makeRig { $0.rateLimits = { $0.url?.path.hasPrefix("/media") == true } }
        await get(rig, "media/soundcloud:tracks:1/x/stream/hls", intent: .autonomous, lane: .streamResolution)
        XCTAssertEqual(rig.gateway.trafficSafetyState(), .ready)
        XCTAssertNotNil(rig.gateway.playbackResolutionPausedUntil)
    }

    // MARK: - Budget ceilings

    func testBudgetHourlyCeilingsUnderSaturatingDemand() {
        let start = Date(timeIntervalSince1970: 0)
        var budget = SoundCloudRequestBudget(configuration: .standard, now: start)
        var admitted: [Date] = []
        var admittedBackground: [Date] = []
        for tick in 0..<(2 * 3600 * 4) {
            let now = start.addingTimeInterval(Double(tick) * 0.25)
            if tick % 4 == 0, budget.reserve(.autonomous, now: now) == 0 {
                admitted.append(now)
                admittedBackground.append(now)
            }
            if budget.reserve(.userInitiated, now: now) == 0 { admitted.append(now) }
        }
        func maxInWindow(_ times: [Date], _ window: TimeInterval) -> Int {
            var best = 0
            var lower = 0
            for upper in times.indices {
                while times[upper].timeIntervalSince(times[lower]) >= window { lower += 1 }
                best = max(best, upper - lower + 1)
            }
            return best
        }
        print("[TrafficScenario] saturating demand for 2 hours: admitted=\(admitted.count) maxPerMinute=\(maxInWindow(admitted, 60)) maxPerHour=\(maxInWindow(admitted, 3600)) background maxPerHour=\(maxInWindow(admittedBackground, 3600))")
        XCTAssertLessThanOrEqual(maxInWindow(admitted, 60), Self.interactivePerMinute)
        XCTAssertLessThanOrEqual(maxInWindow(admitted, 3600), Self.perHour)
        XCTAssertLessThanOrEqual(maxInWindow(admittedBackground, 60), Self.backgroundPerMinute)
        XCTAssertLessThanOrEqual(maxInWindow(admittedBackground, 3600), Self.backgroundPerHour)
    }

    // MARK: - Fixtures

    fileprivate static func fetch(_ rig: Rig, _ path: String) async throws {
        guard await send(rig, path) == 200 else { throw APIError.rateLimited(resetAt: nil) }
    }

    fileprivate struct GatewayRemoteCatalog: SoundingRemoteCatalog {
        let rig: Rig

        @MainActor
        func tracks(ids: [String]) async throws -> [TrackEntity] {
            for offset in stride(from: 0, to: ids.count, by: 50) {
                try await SoundCloudTrafficScenarioTests.fetch(rig, "tracks?ids=\(ids[offset..<min(offset + 50, ids.count)].joined(separator: ","))")
            }
            return []
        }

        @MainActor
        func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity] {
            try await SoundCloudTrafficScenarioTests.fetch(rig, "search/tracks?q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
            return []
        }

        @MainActor
        func artists(ids: [String]) async throws -> [ArtistEntity] {
            for id in ids { try await SoundCloudTrafficScenarioTests.fetch(rig, "users/\(id)") }
            return []
        }

        @MainActor
        func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity] {
            try await SoundCloudTrafficScenarioTests.fetch(rig, "search/users?q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
            return []
        }

        @MainActor
        func playlists(ids: [String]) async throws -> [PlaylistEntity] {
            for id in ids { try await SoundCloudTrafficScenarioTests.fetch(rig, "playlists/\(id)") }
            return []
        }

        @MainActor
        func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity] {
            try await SoundCloudTrafficScenarioTests.fetch(rig, "search/playlists?q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
            return []
        }

        @MainActor
        func myPlaylists(limit: Int) async throws -> [PlaylistEntity] {
            try await SoundCloudTrafficScenarioTests.fetch(rig, "users/900/playlists")
            return []
        }
    }

    fileprivate struct LikesOnlyLocal: SoundingLocalCatalog {
        let likes: [Track]

        func snapshot() async -> SoundingSnapshot? { nil }
        func likedTracks(ids: [String]) async -> [Track] {
            let wanted = Set(ids)
            return likes.filter { wanted.contains($0.id) }
        }
        func searchLikedTracks(_ query: String, limit: Int) async -> [Track] {
            let needle = MediaText.normalized(query)
            return Array(likes.filter { MediaText.normalized($0.title).contains(needle) }.prefix(limit))
        }
        func recentLikedTracks(limit: Int) async -> [Track] { Array(likes.prefix(limit)) }
        func savedSetlists() async -> [GeneratedSetlist] { [] }
        func likesCount() async -> Int { likes.count }
        func cachedPlaylists() async -> [Playlist] { [] }
        func followedArtists() async -> [User] { [] }
    }

    static func track(_ id: String, title: String? = nil) -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title ?? "Track \(id)")",
            "duration": 240000,
            "permalink_url": "https://soundcloud.com/maren/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "maren",
                "permalink": "maren",
                "permalink_url": "https://soundcloud.com/maren"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/\(id)/stream",
                        "duration": 240000,
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }
}
