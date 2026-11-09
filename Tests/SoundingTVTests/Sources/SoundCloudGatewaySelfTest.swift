import Foundation
import XCTest
@testable import SoundingTV

final class SoundCloudHostPolicyTests: XCTestCase {
    @MainActor
    func testConcurrentUnauthorizedRequestsShareOneRefresh() async {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }

        let counter = Counter()
        let barrier = SoundCloudCredentialRefreshBarrier()
        async let first = barrier.refresh {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(80))
            return true
        }
        async let second = barrier.refresh {
            await counter.increment()
            return true
        }

        let results = await (first, second)
        let refreshCount = await counter.value
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertFalse(barrier.isRefreshing)
    }

    func testUserDecodesSoundCloudProfileCoverVisual() throws {
        let payload = Data("""
        {
            "id": 42,
            "username": "artist",
            "permalink": "artist",
            "permalink_url": "https://soundcloud.com/artist",
            "visuals": {
                "visuals": [
                    { "visual_url": "https://i1.sndcdn.com/visuals-artist-t2480x520.jpg" }
                ]
            }
        }
        """.utf8)

        let user = try JSONDecoder().decode(User.self, from: payload)
        XCTAssertEqual(
            user.profileCoverURL?.absoluteString,
            "https://i1.sndcdn.com/visuals-artist-t2480x520.jpg"
        )
    }

    func testModernAACMediaHostIsAdmittedWithoutTrustingLookalikes() {
        XCTAssertTrue(SoundCloudHostPolicy.allowsMedia(
            URL(string: "https://playback.media-streaming.soundcloud.cloud/track/aac_160k/playlist.m3u8")!
        ))
        XCTAssertFalse(SoundCloudHostPolicy.allowsMedia(
            URL(string: "https://playback.media-streaming.soundcloud.cloud.attacker.invalid/track.m3u8")!
        ))
    }

    func testModernMediaRedirectMayUseSoundCloudLegacyCDN() {
        XCTAssertTrue(SoundCloudHostPolicy.allowsRedirect(
            from: URL(string: "https://playback.media-streaming.soundcloud.cloud/track/playlist.m3u8")!,
            to: URL(string: "https://cf-aac-media.sndcdn.com/segment.aac")!
        ))
    }
}

@MainActor
enum SoundCloudGatewaySelfTest {
    struct Report {
        var failures = [String]()
        var summary: String {
            failures.isEmpty
                ? "[SoundCloudGatewayTest] PASS"
                : "[SoundCloudGatewayTest] FAIL: \(failures.joined(separator: "; "))"
        }

        mutating func expect(_ label: String, _ condition: Bool) {
            if !condition { failures.append(label) }
        }
    }

    private actor WireCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    static func run() async -> Report {
        var report = Report()
        report.expect("exact API hosts may receive OAuth", SoundCloudHostPolicy.mayReceiveOAuth(
            URL(string: "https://api.soundcloud.com/me")!
        ))
        report.expect("lookalike hosts may not receive OAuth", !SoundCloudHostPolicy.mayReceiveOAuth(
            URL(string: "https://api.soundcloud.com.attacker.invalid/me")!
        ))
        report.expect("API redirects cannot leave trusted API hosts", !SoundCloudHostPolicy.allowsRedirect(
            from: URL(string: "https://api.soundcloud.com/me")!,
            to: URL(string: "https://api.soundcloud.com.attacker.invalid/steal")!
        ))
        report.expect("SoundCloud media CDN is admitted", SoundCloudHostPolicy.allowsMedia(
            URL(string: "https://cf-hls-media.sndcdn.com/track.m3u8")!
        ))
        report.expect("SoundCloud modern AAC/HLS host is admitted", SoundCloudHostPolicy.allowsMedia(
            URL(string: "https://playback.media-streaming.soundcloud.cloud/track/aac_160k/playlist.m3u8")!
        ))
        report.expect("SoundCloud modern media lookalikes are rejected", !SoundCloudHostPolicy.allowsMedia(
            URL(string: "https://playback.media-streaming.soundcloud.cloud.attacker.invalid/track.m3u8")!
        ))
        report.expect("media redirects remain within the SoundCloud CDN", SoundCloudHostPolicy.allowsRedirect(
            from: URL(string: "https://cf-hls-media.sndcdn.com/track.m3u8")!,
            to: URL(string: "https://cf-media.sndcdn.com/segment.aac")!
        ))
        report.expect("modern media redirects may use a SoundCloud legacy CDN segment", SoundCloudHostPolicy.allowsRedirect(
            from: URL(string: "https://playback.media-streaming.soundcloud.cloud/track/playlist.m3u8")!,
            to: URL(string: "https://cf-aac-media.sndcdn.com/segment.aac")!
        ))

        let counter = WireCounter()
        let defaultsName = "SoundCloudGatewaySelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let transport = SoundCloudHTTPTransport { request in
            await counter.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), response)
        }
        let gateway = SoundCloudGateway(transport: transport, defaults: defaults)
        let request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/me")!)

        gateway.setApplicationActivity(.background)
        do {
            _ = try await gateway.data(
                for: request,
                context: .init(intent: .autonomous, lane: .metadata)
            )
            report.failures.append("background autonomous request was admitted")
        } catch SoundCloudGatewayError.autonomousWorkSuspended {
        } catch {
            report.failures.append("unexpected background error: \(error)")
        }
        report.expect("background rejection never reaches the wire", await counter.value == 0)

        gateway.setApplicationActivity(.foreground)
        _ = try? await gateway.data(for: request, context: .init(lane: .metadata))
        report.expect("the first endpoint 403 reaches the caller", await counter.value == 1)
        report.expect("an ordinary 403 does not become a global block", gateway.trafficSafetyState() == .ready)
        _ = try? await gateway.data(for: request, context: .init(lane: .metadata))
        report.expect("an interactive failure does not block the next user request", await counter.value == 2)

        let autonomousCounter = WireCounter()
        let autonomousTransport = SoundCloudHTTPTransport { request in
            await autonomousCounter.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), response)
        }
        let autonomousGateway = SoundCloudGateway(transport: autonomousTransport, defaults: defaults)
        autonomousGateway.setApplicationActivity(.foreground)
        _ = try? await autonomousGateway.data(
            for: request,
            context: .init(intent: .autonomous, lane: .metadata)
        )
        do {
            _ = try await autonomousGateway.data(
                for: request,
                context: .init(intent: .autonomous, lane: .metadata)
            )
            report.failures.append("autonomous endpoint cooldown did not engage")
        } catch SoundCloudGatewayError.endpointCoolingDown {
        } catch {
            report.failures.append("unexpected autonomous cooldown error: \(error)")
        }
        report.expect("autonomous cooldown prevents a refresh loop", await autonomousCounter.value == 1)

        let successCounter = WireCounter()
        let successTransport = SoundCloudHTTPTransport { request in
            await successCounter.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(#"{"ok":true}"#.utf8), response)
        }
        let successGateway = SoundCloudGateway(transport: successTransport, defaults: defaults)
        successGateway.setApplicationActivity(.foreground)
        _ = try? await successGateway.data(for: request, context: .init(lane: .metadata))
        _ = try? await successGateway.data(for: request, context: .init(lane: .metadata))
        report.expect("near-duplicate successful GETs use one wire request", await successCounter.value == 1)
        report.expect("the replay is observable in gateway metrics", successGateway.snapshot().replayedResponses == 1)

        let blockResponse = HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let blockUntil = Date().addingTimeInterval(30)
        _ = successGateway.recordGlobalBlock(
            statusCode: 429,
            response: blockResponse,
            preferredUntil: blockUntil,
            reason: "self-test"
        )
        report.expect(
            "traffic safety publishes typed waiting state",
            successGateway.trafficSafety == .waiting(statusCode: 429, until: blockUntil)
        )
        _ = try? successGateway.enforceTrafficSafety(now: blockUntil.addingTimeInterval(1))
        report.expect("traffic safety publishes typed recovery state", successGateway.trafficSafety == .ready)
        return report
    }
}

@MainActor
final class SoundCloudGatewaySelfTestCase: XCTestCase {
    func testSelfTestPasses() async {
        let report = await SoundCloudGatewaySelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}

@MainActor
final class SoundCloudTrafficPolicyTests: XCTestCase {
    private actor Recorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
        var count: Int { requests.count }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SoundCloudTrafficPolicyTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeGateway(
        recorder: Recorder,
        defaults: UserDefaults? = nil,
        delay: Duration = .milliseconds(80),
        clock: TestClock? = nil,
        respond: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data) = { _ in (200, [:], Data(#"{"ok":true}"#.utf8)) }
    ) -> SoundCloudGateway {
        let transport = SoundCloudHTTPTransport { request in
            await recorder.record(request)
            try await Task.sleep(for: delay)
            let (status, headers, body) = respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
        let gateway: SoundCloudGateway
        if let clock {
            gateway = SoundCloudGateway(transport: transport, defaults: defaults ?? makeDefaults(), random: { 0.5 }, now: { clock.now })
        } else {
            gateway = SoundCloudGateway(transport: transport, defaults: defaults ?? makeDefaults(), random: { 0.5 })
        }
        gateway.setApplicationActivity(.foreground)
        return gateway
    }

    private func get(_ path: String, token: String? = "token") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/\(path)")!)
        if let token { request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: - Coalescing

    func testConcurrentIdenticalGETsShareOneWireRequest() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(150))
        let request = get("tracks/42")
        async let a = gateway.data(for: request, context: .init(lane: .metadata))
        async let b = gateway.data(for: request, context: .init(lane: .metadata))
        async let c = gateway.data(for: request, context: .init(lane: .metadata))
        let results = try await [a, b, c]
        XCTAssertEqual(results.map(\.1.statusCode), [200, 200, 200])
        let wire = await recorder.count
        XCTAssertEqual(wire, 1)
        XCTAssertEqual(gateway.snapshot().coalescedRequests, 2)
    }

    func testDifferentCredentialsAndMutationsAreNeverCoalesced() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(100))
        let one = get("me", token: "one")
        let two = get("me", token: "two")
        async let first = gateway.data(for: one, context: .init(lane: .metadata))
        async let second = gateway.data(for: two, context: .init(lane: .metadata))
        _ = try await (first, second)
        var mutation = get("likes/tracks/1")
        mutation.httpMethod = "POST"
        let post = mutation
        async let third = gateway.data(for: post, context: .init(lane: .social, coalesces: false))
        async let fourth = gateway.data(for: post, context: .init(lane: .social, coalesces: false))
        _ = try await (third, fourth)
        let wire = await recorder.count
        XCTAssertEqual(wire, 4)
    }

    func testFreshResponsesAreReplayedAndMutationsInvalidatePersonalData() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5))
        _ = try await gateway.data(for: get("tracks/7"), context: .init(lane: .metadata))
        _ = try await gateway.data(for: get("users/9/track_likes"), context: .init(lane: .metadata))
        _ = try await gateway.data(for: get("tracks/7"), context: .init(lane: .metadata))
        _ = try await gateway.data(for: get("users/9/track_likes"), context: .init(lane: .metadata))
        var wire = await recorder.count
        XCTAssertEqual(wire, 2)

        var like = get("users/9/track_likes/7")
        like.httpMethod = "PUT"
        _ = try await gateway.data(for: like, context: .init(lane: .social, coalesces: false))
        _ = try await gateway.data(for: get("users/9/track_likes"), context: .init(lane: .metadata))
        _ = try await gateway.data(for: get("tracks/7"), context: .init(lane: .metadata))
        wire = await recorder.count
        XCTAssertEqual(wire, 4)
    }

    func testCachePolicyKeepsStableResourcesLongerThanPersonalFeeds() {
        let track = URL(string: "https://api-v2.soundcloud.com/tracks/1")!
        let likes = URL(string: "https://api-v2.soundcloud.com/users/5/track_likes")!
        let charts = URL(string: "https://api-v2.soundcloud.com/mixed-selections")!
        XCTAssertEqual(SoundCloudCachePolicy.lifetime(for: track, lane: .metadata, intent: .userInitiated, currentUserID: "5"), 600)
        XCTAssertEqual(SoundCloudCachePolicy.lifetime(for: likes, lane: .metadata, intent: .userInitiated, currentUserID: "5"), 60)
        XCTAssertEqual(SoundCloudCachePolicy.lifetime(for: likes, lane: .metadata, intent: .autonomous, currentUserID: "5"), 300)
        XCTAssertEqual(SoundCloudCachePolicy.lifetime(for: charts, lane: .metadata, intent: .userInitiated, currentUserID: nil), 1800)
        XCTAssertEqual(SoundCloudCachePolicy.lifetime(for: track, lane: .social, intent: .userInitiated, currentUserID: nil), 0)
    }

    func testEntityTagRevalidationServesTheCachedBody() {
        var cache = SoundCloudResponseCache<String>()
        let start = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://api-v2.soundcloud.com/tracks/1")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""])!
        cache.store(Data("body".utf8), response: response, for: "k", lifetime: 60, now: start)
        XCTAssertNotNil(cache.fresh("k", now: start.addingTimeInterval(30)))
        XCTAssertNil(cache.fresh("k", now: start.addingTimeInterval(61)))
        let stale = cache.revalidatable("k", now: start.addingTimeInterval(61))
        XCTAssertEqual(stale?.entityTag, "\"v1\"")
        cache.extend("k", lifetime: 60, now: start.addingTimeInterval(61))
        XCTAssertEqual(cache.fresh("k", now: start.addingTimeInterval(100)).map { String(decoding: $0.data, as: UTF8.self) }, "body")
    }

    // MARK: - Budget

    func testBudgetAllowsAShortBurstThenPacesInteractiveWork() {
        let start = Date(timeIntervalSince1970: 0)
        var budget = SoundCloudRequestBudget(configuration: .standard, now: start)
        for _ in 0..<6 { XCTAssertEqual(budget.reserve(.userInitiated, now: start), 0) }
        let wait = budget.reserve(.userInitiated, now: start)
        XCTAssertEqual(wait, 2, accuracy: 0.001)
        XCTAssertEqual(budget.reserve(.userInitiated, now: start.addingTimeInterval(2)), 0)
    }

    func testBudgetDefersAutonomousWorkWhileInteractiveHeadroomIsLow() {
        let start = Date(timeIntervalSince1970: 0)
        var budget = SoundCloudRequestBudget(configuration: .standard, now: start)
        XCTAssertEqual(budget.reserve(.autonomous, now: start), 0)
        XCTAssertEqual(budget.reserve(.autonomous, now: start), 0)
        XCTAssertGreaterThan(budget.reserve(.autonomous, now: start), 0)
        for _ in 0..<4 { _ = budget.reserve(.userInitiated, now: start) }
        let later = start.addingTimeInterval(6)
        XCTAssertGreaterThan(budget.reserve(.autonomous, now: later), 0)
        XCTAssertEqual(budget.reserve(.userInitiated, now: later), 0)
    }

    func testSustainedAutonomousRateStaysLow() {
        var budget = SoundCloudRequestBudget(configuration: .standard, now: Date(timeIntervalSince1970: 0))
        var admitted = 0
        for second in 0..<600 {
            if budget.reserve(.autonomous, now: Date(timeIntervalSince1970: Double(second))) == 0 { admitted += 1 }
        }
        XCTAssertLessThanOrEqual(admitted, 102)
        XCTAssertGreaterThanOrEqual(admitted, 95)
    }

    func testCarefulBudgetSlowsInteractiveRequests() {
        let start = Date(timeIntervalSince1970: 0)
        var budget = SoundCloudRequestBudget(configuration: .standard, now: start)
        budget.reconfigure(.careful, now: start)
        XCTAssertEqual(budget.reserve(.userInitiated, now: start), 0)
        XCTAssertEqual(budget.reserve(.userInitiated, now: start), 0)
        XCTAssertEqual(budget.reserve(.userInitiated, now: start), 5, accuracy: 0.001)
        XCTAssertEqual(budget.reserve(.autonomous, now: start.addingTimeInterval(100)), 60)
    }

    // MARK: - Backoff

    func testBackoffGrowsExponentiallyWithBoundedJitterAndCap() {
        let backoff = SoundCloudBackoff(base: 2, cap: 60, jitter: 0.5)
        XCTAssertEqual(backoff.delay(attempt: 0, unit: 1), 2)
        XCTAssertEqual(backoff.delay(attempt: 0, unit: 0), 1)
        XCTAssertEqual(backoff.delay(attempt: 3, unit: 1), 16)
        XCTAssertEqual(backoff.delay(attempt: 3, unit: 0), 8)
        XCTAssertEqual(backoff.delay(attempt: 20, unit: 1), 60)
        XCTAssertEqual(backoff.delay(attempt: 20, unit: 0), 30)
        for attempt in 0..<10 {
            let value = backoff.delay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(value, min(60, 2 * pow(2, Double(attempt))) / 2)
            XCTAssertLessThanOrEqual(value, min(60, 2 * pow(2, Double(attempt))))
        }
    }

    // MARK: - Rate limits

    nonisolated private static let resetPayload = Data(#"{"errors":[{"meta":{"rate_limit":{"bucket":"by-client","max_nr_of_requests":15000,"time_window":"PT24H","name":"plays"},"remaining_requests":0,"reset_time":"2099/01/01 17:00:00 +0000"}}]}"#.utf8)
    nonisolated private static let genericResetPayload = Data(#"{"errors":[{"meta":{"reset_time":"2099/01/01 17:00:00 +0000"}}]}"#.utf8)

    func testBackgroundRateLimitPausesOnlyBackgroundWork() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5), clock: clock) { request in
            request.url!.path.contains("track_likes") ? (429, [:], Data()) : (200, [:], Data("{}".utf8))
        }
        _ = try await gateway.data(for: get("users/1/track_likes"), context: .init(intent: .autonomous, lane: .metadata))
        XCTAssertEqual(gateway.trafficSafetyState(), .ready, "a background 429 must not stop interactive traffic")
        let paused = try XCTUnwrap(gateway.backgroundWorkPausedUntil)
        XCTAssertLessThanOrEqual(paused.timeIntervalSince(clock.now), 2 * 60 + 1)
        do {
            _ = try await gateway.data(for: get("me/library/all"), context: .init(intent: .autonomous, lane: .metadata))
            XCTFail("background work was admitted during a background pause")
        } catch SoundCloudGatewayError.backgroundPaused {
        }
        let (_, interactive) = try await gateway.data(for: get("tracks/3"), context: .init(lane: .metadata))
        XCTAssertEqual(interactive.statusCode, 200)
        let wire = await recorder.count
        XCTAssertEqual(wire, 2)
    }

    func testInteractiveRateLimitStopsTrafficBrieflyNotUntilTheWindowReset() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5)) { _ in (429, [:], Self.genericResetPayload) }
        _ = try await gateway.data(for: get("stream"), context: .init(lane: .feed))
        guard case .waiting(let status, let until) = gateway.trafficSafetyState() else {
            return XCTFail("an interactive 429 must stop SoundCloud traffic")
        }
        XCTAssertEqual(status, 429)
        XCTAssertLessThanOrEqual(until.timeIntervalSinceNow, 2 * 60 + 1)
        do {
            _ = try await gateway.data(for: get("tracks/1"), context: .init(lane: .metadata))
            XCTFail("traffic stop did not hold")
        } catch APIError.temporarilyBlocked {
        }
        let wire = await recorder.count
        XCTAssertEqual(wire, 1)
    }

    func testRetryAfterIsHonoured() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5)) { _ in (429, ["Retry-After": "900"], Data()) }
        _ = try await gateway.data(for: get("stream"), context: .init(lane: .feed))
        guard case .waiting(_, let until) = gateway.trafficSafetyState() else { return XCTFail("no stop") }
        XCTAssertEqual(until.timeIntervalSinceNow, 900, accuracy: 5)
    }

    func testPlaysBucketLimitStopsBrieflyThenPausesOnlyStreamResolution() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5), clock: clock) { request in
            request.url!.path.hasPrefix("/media") ? (429, [:], Self.resetPayload) : (200, [:], Data("{}".utf8))
        }
        _ = try await gateway.data(for: get("media/soundcloud:tracks:1/x/stream/hls"), context: .init(intent: .playback, lane: .streamResolution))
        guard case .waiting = gateway.trafficSafetyState() else {
            return XCTFail("a single 429 must trigger the global traffic stop")
        }
        clock.advance(61)
        XCTAssertEqual(gateway.trafficSafetyState(), .ready)
        XCTAssertNil(gateway.backgroundWorkPausedUntil)
        XCTAssertNotNil(gateway.playbackResolutionPausedUntil)
        do {
            _ = try await gateway.data(for: get("media/soundcloud:tracks:2/x/stream/hls"), context: .init(intent: .playback, lane: .streamResolution))
            XCTFail("stream resolution continued during a plays-bucket pause")
        } catch APIError.rateLimited {
        }
        let (_, browse) = try await gateway.data(for: get("tracks/2"), context: .init(lane: .metadata))
        XCTAssertEqual(browse.statusCode, 200)
    }

    func testLoneForbiddenFailsOnlyThatRequest() async throws {
        let recorder = Recorder()
        let gateway = makeGateway(recorder: recorder, delay: .milliseconds(5)) { request in
            request.url!.path == "/tracks/403" ? (403, [:], Data()) : (200, [:], Data("{}".utf8))
        }
        let (_, forbidden) = try await gateway.data(for: get("tracks/403"), context: .init(lane: .metadata))
        XCTAssertEqual(forbidden.statusCode, 403)
        XCTAssertEqual(gateway.trafficSafetyState(), .ready)
        XCTAssertNil(gateway.backgroundWorkPausedUntil)
        let (_, next) = try await gateway.data(for: get("tracks/4"), context: .init(lane: .metadata))
        XCTAssertEqual(next.statusCode, 200)
    }

    func testBotChallengeDetectionIgnoresSuccessfulResponses() {
        let url = URL(string: "https://api-v2.soundcloud.com/me")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-DataDome": "protected"])!
        XCTAssertFalse(SoundCloudGateway.isBotChallenge(response: ok, data: Data("{}".utf8)))
        let json = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        XCTAssertTrue(SoundCloudGateway.isBotChallenge(response: json, data: Data(#"{"url":"https://geo.captcha-delivery.com/captcha/?initialCid=x"}"#.utf8)))
        XCTAssertFalse(SoundCloudGateway.isBotChallenge(response: json, data: Data(#"{"error":"forbidden"}"#.utf8)))
    }

    func testPersistedRateLimitStopIsClampedOnLaunch() {
        let defaults = makeDefaults()
        let far = Date().addingTimeInterval(8 * 60 * 60)
        defaults.set(far.timeIntervalSince1970, forKey: "red.forbes.sounding.soundcloud.trafficBlockedUntil")
        defaults.set(429, forKey: "red.forbes.sounding.soundcloud.trafficBlockedStatus")
        defaults.set("rate-limit", forKey: "red.forbes.sounding.soundcloud.trafficBlockedReason")
        let gateway = makeGateway(recorder: Recorder(), defaults: defaults)
        guard case .waiting(_, let until) = gateway.trafficSafetyState() else { return XCTFail("stop was dropped") }
        XCTAssertLessThanOrEqual(until.timeIntervalSinceNow, 60 * 60 + 1)
    }

    func testRateLimitPayloadParsesBucketAndReset() {
        let signal = SoundCloudRateLimitSignal.parse(Self.resetPayload)
        XCTAssertTrue(signal.isPlaysBucket)
        XCTAssertEqual(signal.resetAt, ISO8601DateFormatter().date(from: "2099-01-01T17:00:00Z"))
    }

    func testSignedURLExpiryIsReadFromTheURL() {
        let expires = URL(string: "https://cf-media.sndcdn.com/a.mp3?Expires=1900000000&Signature=x")!
        XCTAssertEqual(SoundCloudSignedURLExpiry.expiry(of: expires), Date(timeIntervalSince1970: 1_900_000_000))
        let policy = Data(#"{"Statement":[{"Resource":"*","Condition":{"DateLessThan":{"AWS:EpochTime":1900000123}}}]}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "/", with: "~")
        let cloudFront = URL(string: "https://cf-hls-media.sndcdn.com/playlist/a.m3u8?Policy=\(policy)&Signature=y&Key-Pair-Id=z")!
        XCTAssertEqual(SoundCloudSignedURLExpiry.expiry(of: cloudFront), Date(timeIntervalSince1970: 1_900_000_123))
        XCTAssertNil(SoundCloudSignedURLExpiry.expiry(of: URL(string: "https://cf-media.sndcdn.com/a.mp3")!))
    }
}
