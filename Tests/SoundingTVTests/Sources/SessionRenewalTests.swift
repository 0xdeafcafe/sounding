import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class SessionRenewalTests: XCTestCase {
    @MainActor private final class FakeWorld {
        var stored: StoredSession?
        var refreshCalls: [String] = []
        var validateCalls: [String] = []
        var refreshOutcomes: [String: SoundCloudTokenRefresh.Outcome] = [:]
        var validations: [String: SoundCloudTokenValidation] = [:]
        var trafficStopped = false
        var fetches: [String] = []

        var environment: SoundCloudSessionRenewal.Environment {
            SoundCloudSessionRenewal.Environment(
                load: { self.stored },
                save: { self.stored = $0 },
                refresh: { session in
                    let token = session.refreshToken ?? ""
                    self.refreshCalls.append(token)
                    return self.refreshOutcomes[token] ?? .unrecoverable
                },
                validate: { token in
                    self.validateCalls.append(token)
                    return self.validations[token] ?? .rejected
                },
                isTrafficStopped: { self.trafficStopped }
            )
        }

        func source(
            _ kind: SoundCloudSessionRenewal.SourceKind,
            before: StoredSession? = nil,
            after: StoredSession? = nil,
            onCommit: (@MainActor () -> Void)? = nil
        ) -> SoundCloudSessionRenewal.Source {
            SoundCloudSessionRenewal.Source(kind: kind) { phase in
                self.fetches.append("\(kind.rawValue).\(phase == .beforeRefresh ? "before" : "after")")
                guard let session = phase == .beforeRefresh ? before : after else { return nil }
                return SoundCloudSessionRenewal.Candidate(session: session) { onCommit?() }
            }
        }
    }

    private static let past = Date(timeIntervalSinceNow: -3_600)
    private static let future = Date(timeIntervalSinceNow: 3_600)

    private static func session(_ access: String, refresh: String? = nil, expiresAt: Date? = future) -> StoredSession {
        StoredSession(oauthToken: access, refreshToken: refresh, clientId: refresh == nil ? nil : "client", expiresAt: expiresAt)
    }

    private static let invalidGrant = SoundCloudTokenRefresh.Outcome.unrecoverable

    func testStaleDeviceAdoptsRotatedSyncedSessionInsteadOfRejecting() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = Self.invalidGrant
        let rotated = Self.session("a2", refresh: "r2")
        world.validations["a2"] = .valid
        var committed = false
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced, after: rotated) { committed = true }]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertEqual(world.stored, rotated)
        XCTAssertEqual(world.refreshCalls, ["r1"])
        XCTAssertEqual(world.validateCalls, ["a2"])
        XCTAssertTrue(committed)
    }

    func testNewerSyncedSessionIsAdoptedBeforeRotatingTheSharedRefreshToken() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        let newer = Self.session("a2", refresh: "r2")
        world.validations["a2"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced, before: newer, after: newer)]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertEqual(world.stored, newer)
        XCTAssertTrue(world.refreshCalls.isEmpty)
    }

    func testExpiredSyncedSessionIsRefreshedFromTheNewestLineage() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = Self.invalidGrant
        world.refreshOutcomes["r2"] = .succeeded(.init(accessToken: "a3", refreshToken: "r3", expiresAt: Self.future))
        world.validations["a3"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced, after: Self.session("a2", refresh: "r2", expiresAt: Self.past))]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertEqual(world.refreshCalls, ["r1", "r2"])
        XCTAssertEqual(world.stored?.oauthToken, "a3")
        XCTAssertEqual(world.stored?.refreshToken, "r3")
    }

    func testLocalRefreshStillWinsWhenNoPeerHasANewerSession() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = .succeeded(.init(accessToken: "a2", refreshToken: "r2", expiresAt: Self.future))
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced), world.source(.silentWeb)]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(world.stored?.refreshToken, "r2")
        XCTAssertEqual(world.fetches, ["synced.before", "silentWeb.before"])
    }

    func testRateLimitedRefreshWaitsInsteadOfRejecting() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = SoundCloudTokenRefresh.failureOutcome(
            statusCode: 429,
            data: Data(#"{"error":"invalid_grant"}"#.utf8)
        )
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced), world.source(.silentWeb, after: Self.session("w1", refresh: "rw"))]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .temporarilyUnavailable)
        XCTAssertEqual(world.stored?.oauthToken, "a1")
        XCTAssertFalse(world.fetches.contains("silentWeb.after"))
    }

    func testTrafficStopNeverRunsRecoveryOrRejects() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.trafficStopped = true
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced, after: Self.session("a2", refresh: "r2"))]
        )

        let renewed = await renewal.renew()
        let recovered = await renewal.recover()

        XCTAssertEqual(renewed, .temporarilyUnavailable)
        XCTAssertEqual(recovered, .temporarilyUnavailable)
        XCTAssertTrue(world.refreshCalls.isEmpty)
        XCTAssertTrue(world.validateCalls.isEmpty)
        XCTAssertTrue(world.fetches.isEmpty)
    }

    func testRateLimitedAccountCheckKeepsTheCandidateAndWaits() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = Self.invalidGrant
        let candidate = Self.session("a2", refresh: "r2")
        world.validations["a2"] = .unavailable("HTTP 429")
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.synced, after: candidate), world.source(.silentWeb, after: Self.session("w1", refresh: "rw"))]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .temporarilyUnavailable)
        XCTAssertEqual(world.stored, candidate)
        XCTAssertFalse(world.fetches.contains("silentWeb.after"))
    }

    func testRateLimitResponsesNeverReadAsADeadSession() {
        let invalidGrant = Data(#"{"error":"invalid_grant"}"#.utf8)
        XCTAssertEqual(SoundCloudTokenRefresh.failureOutcome(statusCode: 429, data: invalidGrant), .transient)
        XCTAssertEqual(SoundCloudTokenRefresh.failureOutcome(statusCode: 403, data: invalidGrant), .transient)
        XCTAssertEqual(SoundCloudTokenRefresh.failureOutcome(statusCode: 503, data: invalidGrant), .transient)
        XCTAssertEqual(SoundCloudTokenRefresh.failureOutcome(statusCode: 401, data: Data("<html>datadome</html>".utf8)), .transient)
        XCTAssertEqual(SoundCloudTokenRefresh.failureOutcome(statusCode: 400, data: invalidGrant), .unrecoverable)
        XCTAssertFalse(SoundCloudSessionHealth.rejected(.refreshUnreachable).needsSignIn)
    }

    func testRecoveryRunsSyncedThenLinkedPeerThenSilentWeb() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = Self.invalidGrant
        world.validations["p1"] = .rejected
        world.validations["w1"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [
                world.source(.synced),
                world.source(.linkedPeer, after: Self.session("p1")),
                world.source(.silentWeb, after: Self.session("w1", refresh: "rw")),
            ]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.silentWeb))
        XCTAssertEqual(world.fetches, [
            "synced.before", "linkedPeer.before", "silentWeb.before",
            "synced.after", "linkedPeer.after", "silentWeb.after",
        ])
        XCTAssertEqual(world.validateCalls, ["p1", "w1"])
        XCTAssertEqual(world.stored?.oauthToken, "w1")
    }

    func testRecoveryStopsAtTheFirstWorkingSource() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.refreshOutcomes["r1"] = Self.invalidGrant
        world.validations["s1"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [
                world.source(.synced, after: Self.session("s1", refresh: "rs")),
                world.source(.linkedPeer, after: Self.session("p1", refresh: "rp")),
                world.source(.silentWeb, after: Self.session("w1", refresh: "rw")),
            ]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertFalse(world.fetches.contains("linkedPeer.after"))
        XCTAssertFalse(world.fetches.contains("silentWeb.after"))
    }

    func testExhaustedRecoveryRestoresTheOriginalSession() async {
        let world = FakeWorld()
        let original = Self.session("a1", refresh: "r1", expiresAt: Self.past)
        world.stored = original
        world.refreshOutcomes["r1"] = Self.invalidGrant
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [
                world.source(.synced, after: original),
                world.source(.linkedPeer, after: Self.session("p1", expiresAt: Self.past)),
            ]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .exhausted)
        XCTAssertEqual(world.stored, original)
        XCTAssertEqual(world.refreshCalls, ["r1"])
    }

    func testSessionWithoutRefreshCapabilityAsksALinkedPeerFirst() async {
        let world = FakeWorld()
        world.stored = Self.session("a1", expiresAt: Self.past)
        let peer = Self.session("p1", refresh: "rp")
        world.validations["p1"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.linkedPeer, after: peer)]
        )

        let outcome = await renewal.renew()

        XCTAssertEqual(outcome, .adopted(.linkedPeer))
        XCTAssertTrue(world.refreshCalls.isEmpty)
        XCTAssertEqual(world.stored, peer)
    }

    func testSessionWithoutRefreshCapabilityRecoversThroughThePeerOn401() async {
        let world = FakeWorld()
        world.stored = Self.session("a1")
        let peer = Self.session("p1", refresh: "rp")
        world.validations["p1"] = .valid
        let renewal = SoundCloudSessionRenewal(
            environment: world.environment,
            sources: [world.source(.linkedPeer, after: peer)]
        )

        let outcome = await renewal.recover()

        XCTAssertEqual(outcome, .adopted(.linkedPeer))
        XCTAssertEqual(world.fetches, ["linkedPeer.after"])
        XCTAssertTrue(world.refreshCalls.isEmpty)
    }

    func testTimeoutReturnsNilWhenASourceHangs() async {
        let value: Int? = await SoundCloudSessionRenewalTimeout.value(within: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(10))
            return 1
        }
        XCTAssertNil(value)
        let fast: Int? = await SoundCloudSessionRenewalTimeout.value(within: .seconds(5)) { 2 }
        XCTAssertEqual(fast, 2)
    }

    func testSilentWebNavigationIsLimitedToSoundCloudOAuthHosts() {
        let policy = SilentWebReauthorizationPolicy.self
        XCTAssertTrue(policy.allowsNavigation(to: URL(string: "https://m.soundcloud.com/signin"), isMainFrame: true))
        XCTAssertTrue(policy.allowsNavigation(to: URL(string: "https://secure.soundcloud.com/authorize?x=1"), isMainFrame: false))
        XCTAssertTrue(policy.allowsNavigation(to: URL(string: "https://m.soundcloud.com/signin/callback?code=x"), isMainFrame: true))
        XCTAssertTrue(policy.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: false))
        XCTAssertFalse(policy.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true))
        XCTAssertFalse(policy.allowsNavigation(to: URL(string: "http://m.soundcloud.com/signin"), isMainFrame: true))
        XCTAssertFalse(policy.allowsNavigation(to: URL(string: "https://accounts.google.com/o/oauth2"), isMainFrame: true))
        XCTAssertFalse(policy.allowsNavigation(to: URL(string: "https://geo.captcha-delivery.com/captcha"), isMainFrame: false))
        XCTAssertFalse(policy.allowsNavigation(to: URL(string: "https://soundcloud.com.evil.example/signin"), isMainFrame: true))
        XCTAssertFalse(policy.allowsNavigation(to: nil, isMainFrame: true))
        XCTAssertTrue(policy.isTrustedMessageOrigin(scheme: "https", host: "m.soundcloud.com"))
        XCTAssertFalse(policy.isTrustedMessageOrigin(scheme: "http", host: "m.soundcloud.com"))
        XCTAssertFalse(policy.isTrustedMessageOrigin(scheme: "https", host: "evilsoundcloud.com"))
        XCTAssertTrue(policy.isSigninCallback(URL(string: "https://m.soundcloud.com/signin/callback?code=x")!))
        XCTAssertNil(policy.session(accessToken: "a", refreshToken: nil, clientId: "c", expiresAt: nil))
        XCTAssertEqual(
            policy.session(accessToken: "a", refreshToken: "r", clientId: "c", expiresAt: nil),
            StoredSession(oauthToken: "a", refreshToken: "r", clientId: "c", expiresAt: nil)
        )
    }

    func testRefreshLineageIdentifiesARotationOfTheSameGrant() {
        XCTAssertEqual(
            SessionSyncBookkeeping.lineageDigest(refreshToken: "r1"),
            SessionSyncBookkeeping.lineageDigest(refreshToken: "r1")
        )
        XCTAssertNotEqual(
            SessionSyncBookkeeping.lineageDigest(refreshToken: "r1"),
            SessionSyncBookkeeping.lineageDigest(refreshToken: "r2")
        )
        XCTAssertNil(SessionSyncBookkeeping.lineageDigest(refreshToken: nil))
        XCTAssertNil(SessionSyncBookkeeping.lineageDigest(refreshToken: ""))
    }
}
