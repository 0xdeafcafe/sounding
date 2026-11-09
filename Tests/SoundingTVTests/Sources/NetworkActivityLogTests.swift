import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class NetworkActivityLogTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaultsName = "NetworkActivityLogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsName)
    }

    private func stub(_ statuses: [Int], headers: [String: String] = [:]) -> SoundCloudHTTPTransport {
        let queue = StatusQueue(statuses)
        return SoundCloudHTTPTransport { request in
            let status = await queue.next()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(#"{"collection":[]}"#.utf8), response)
        }
    }

    private actor StatusQueue {
        var statuses: [Int]
        init(_ statuses: [Int]) { self.statuses = statuses }
        func next() -> Int { statuses.count > 1 ? statuses.removeFirst() : statuses.first ?? 200 }
    }

    private func gateway(_ transport: SoundCloudHTTPTransport, log: NetworkActivityLog) -> SoundCloudGateway {
        let gateway = SoundCloudGateway(transport: transport, defaults: defaults, random: { 0.5 }, sleep: { _ in }, networkLog: log)
        gateway.setApplicationActivity(.foreground)
        return gateway
    }

    func testTokensNeverAppearInTheLogOrExport() async throws {
        let log = NetworkActivityLog()
        let gateway = gateway(stub([200]), log: log)
        let secrets = ["tok-SECRET-1", "cid-SECRET-2", "sig-SECRET-3", "pol-SECRET-4", "body-SECRET-5", "eyJhbGciOiJIUzI1NiJ9.e30.SECRETjwt", "auth-SECRET-6"]
        var request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/tracks/42/streams?client_id=\(secrets[1])&oauth_token=\(secrets[0])&Signature=\(secrets[2])&Policy=\(secrets[3])&track_authorization=\(secrets[6])&limit=20&cursor=\(secrets[5])")!)
        request.setValue("OAuth \(secrets[0])", forHTTPHeaderField: "Authorization")
        request.setValue("session=\(secrets[0])", forHTTPHeaderField: "Cookie")
        request.httpMethod = "POST"
        request.httpBody = Data(secrets[4].utf8)
        _ = try await gateway.data(for: request, context: .init(lane: .streamResolution, coalesces: false))

        let entry = try XCTUnwrap(log.snapshot().last)
        XCTAssertEqual(entry.feature, .streamResolve)
        XCTAssertEqual(entry.host, "api-v2.soundcloud.com")
        XCTAssertEqual(entry.path, "/tracks/42/streams")
        XCTAssertTrue(entry.query.contains("client_id=REDACTED"))
        XCTAssertTrue(entry.query.contains("oauth_token=REDACTED"))
        XCTAssertTrue(entry.query.contains("limit=20"))
        XCTAssertEqual(entry.status, 200)
        XCTAssertNotNil(entry.duration)
        XCTAssertEqual(entry.bytes, 17)

        let haystacks = [log.exportText(), String(describing: log.snapshot()), NetworkActivityLog.exportLine(entry)]
        for haystack in haystacks {
            for secret in secrets {
                XCTAssertFalse(haystack.contains(secret), "leaked \(secret)")
            }
            XCTAssertFalse(haystack.contains("OAuth "))
        }
    }

    func testRedactionKeepsKeysAndPlainValues() {
        let (host, path, query) = NetworkRedaction.redact(URL(string: "https://user:pw@cf-hls-media.sndcdn.com/media/0/30000/abc.m3u8?Key-Pair-Id=K1&X-Amz-Security-Token=T&expires=99&q=house#frag")!)
        XCTAssertEqual(host, "cf-hls-media.sndcdn.com")
        XCTAssertEqual(path, "/media/0/30000/abc.m3u8")
        XCTAssertEqual(query, "Key-Pair-Id=REDACTED&X-Amz-Security-Token=REDACTED&expires=99&q=house")
    }

    func testDuplicateWithinWindowIsFlaggedAndCacheReplayIsNot() async throws {
        let log = NetworkActivityLog()
        let gateway = gateway(stub([200]), log: log)
        let request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/me/activities?limit=10")!)
        _ = try await gateway.data(for: request, context: .init(lane: .feed, coalesces: false))
        _ = try await gateway.data(for: request, context: .init(lane: .feed, coalesces: false))
        let entries = log.snapshot()
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].issues.contains(.duplicate))
        XCTAssertTrue(entries[1].issues.contains(.duplicate))

        let cachedLog = NetworkActivityLog()
        let cachingGateway = self.gateway(stub([200]), log: cachedLog)
        _ = try await cachingGateway.data(for: request, context: .init(lane: .feed))
        _ = try await cachingGateway.data(for: request, context: .init(lane: .feed))
        let cached = cachedLog.snapshot()
        XCTAssertEqual(cached.map(\.source), [.network, .cache])
        XCTAssertTrue(cached.allSatisfy { !$0.issues.contains(.duplicate) })
    }

    func testDuplicatesOutsideTheWindowAreNotFlagged() {
        let log = NetworkActivityLog()
        let url = URL(string: "https://api-v2.soundcloud.com/search/tracks?q=a")!
        let start = Date()
        log.record(NetworkRequestRecord(feature: .search, url: url, status: 200), now: start)
        let later = log.record(NetworkRequestRecord(feature: .search, url: url, status: 200), now: start.addingTimeInterval(NetworkActivityLog.duplicateWindow + 1))
        XCTAssertEqual(later?.issues, [])
    }

    func testRetryAfterFailureIsMarkedRetriedNotDuplicate() {
        let log = NetworkActivityLog()
        let url = URL(string: "https://api-v2.soundcloud.com/me")!
        let now = Date()
        let first = log.record(NetworkRequestRecord(feature: .profile, url: url, status: 401), now: now)
        let second = log.record(NetworkRequestRecord(feature: .profile, url: url, status: 200), now: now.addingTimeInterval(1))
        XCTAssertEqual(first?.issues, .failed)
        XCTAssertEqual(second?.retried, true)
        XCTAssertEqual(second?.issues, [])
    }

    func testRateLimitIsFlaggedWithItsBackoff() async throws {
        let log = NetworkActivityLog()
        let gateway = gateway(stub([429], headers: ["Retry-After": "120"]), log: log)
        let request = URLRequest(url: URL(string: "https://api-v2.soundcloud.com/me/library/all")!)
        _ = try? await gateway.data(for: request, context: .init(lane: .metadata))
        _ = try? await gateway.data(for: URLRequest(url: URL(string: "https://api-v2.soundcloud.com/me")!), context: .init(lane: .metadata))

        let entries = log.snapshot()
        let limited = try XCTUnwrap(entries.first { $0.status == 429 && $0.kind == .request })
        XCTAssertTrue(limited.issues.contains(.rateLimited))
        XCTAssertFalse(limited.issues.contains(.failed))
        XCTAssertTrue(entries.contains { $0.kind == .trafficStop && $0.issues.contains(.backoff) && $0.until != nil })
        XCTAssertTrue(entries.contains { $0.source == .held && $0.issues.contains(.backoff) })
        let summary = NetworkIssueSummary(entries)
        XCTAssertEqual(summary.counts.first?.issue, .rateLimited)
        XCTAssertTrue(log.exportText().contains("rate-limited 1"))
    }

    func testNonSuccessStatusAndUnexpectedHostAreFlagged() {
        let log = NetworkActivityLog()
        let failed = log.record(NetworkRequestRecord(feature: .artwork, url: URL(string: "https://i1.sndcdn.com/a-t500x500.jpg")!, status: 404))
        let stranger = log.record(NetworkRequestRecord(feature: .artwork, url: URL(string: "https://tracker.example.com/pixel")!, status: 200))
        let sonos = log.record(NetworkRequestRecord(feature: .sonos, url: URL(string: "http://192.168.1.20:1400/xml/device_description.xml")!, status: 200))
        XCTAssertEqual(failed?.issues, .failed)
        XCTAssertEqual(stranger?.issues, .unexpectedHost)
        XCTAssertEqual(sonos?.issues, [])
    }

    func testPromotedPingFiringTwiceIsFlagged() {
        let log = NetworkActivityLog()
        let url = URL(string: "https://promoted.soundcloud.com/impression?urn=1")!
        let now = Date()
        let first = log.record(NetworkRequestRecord(feature: .promotedImpression, url: url, status: 200), now: now)
        let second = log.record(NetworkRequestRecord(feature: .promotedImpression, url: url, status: 200), now: now.addingTimeInterval(60))
        XCTAssertEqual(first?.issues, [])
        XCTAssertEqual(second?.issues, .repeatedPing)
    }

    func testBackgroundRequestsAreFlaggedUnlessAllowed() {
        let log = NetworkActivityLog()
        log.setApplicationForeground(false)
        let feed = log.record(NetworkRequestRecord(feature: .feed, url: URL(string: "https://api-v2.soundcloud.com/stream")!, status: 200))
        let stream = log.record(NetworkRequestRecord(feature: .streamResolve, url: URL(string: "https://api-v2.soundcloud.com/tracks/1/streams")!, status: 200))
        #if os(macOS)
        XCTAssertEqual(feed?.issues, [])
        #else
        XCTAssertEqual(feed?.issues, .background)
        #endif
        XCTAssertEqual(stream?.issues, [])
    }

    func testRingBufferKeepsTheNewestAndPauseStopsRecording() {
        let log = NetworkActivityLog(capacity: 3)
        for index in 0..<5 {
            log.record(NetworkRequestRecord(feature: .tracks, url: URL(string: "https://api-v2.soundcloud.com/tracks/\(index)")!, status: 200))
        }
        XCTAssertEqual(log.snapshot().map(\.path), ["/tracks/2", "/tracks/3", "/tracks/4"])
        log.setPaused(true)
        XCTAssertNil(log.record(NetworkRequestRecord(feature: .tracks, url: URL(string: "https://api-v2.soundcloud.com/tracks/9")!, status: 200)))
        XCTAssertEqual(log.snapshot().count, 3)
        log.clear()
        XCTAssertTrue(log.snapshot().isEmpty)
    }

    func testFeatureTagging() {
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/search/tracks", lane: "metadata"), .search)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/stream", lane: "metadata"), .feed)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/users/1/track_likes", lane: "metadata"), .likes)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/tracks/1/streams", lane: "streamResolution"), .streamResolve)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/me/play-history/tracks", lane: "metadata"), .history)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/me/play-history/contexts", lane: "metadata"), .history)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/me/recently-played/tracks", lane: "metadata"), .history)
    }
}
