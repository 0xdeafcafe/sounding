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

@MainActor
final class SessionRecoveryTests: XCTestCase {
    @MainActor private final class Harness {
        var now = ContinuousClock.now
        var outcomes: [SoundCloudSessionRenewal.Outcome] = []
        var attempts = 0
        var validation: SoundCloudTokenValidation?
        var validations = 0
        var resolvedAfterAttempts: Int?

        var environment: SoundCloudSessionRecovery.Environment {
            SoundCloudSessionRecovery.Environment(
                validateCurrent: {
                    self.validations += 1
                    return self.validation
                },
                isResolved: {
                    guard let after = self.resolvedAfterAttempts else { return false }
                    return self.attempts >= after
                },
                attempt: { _ in
                    self.attempts += 1
                    return self.outcomes.isEmpty ? .exhausted : self.outcomes.removeFirst()
                },
                sleep: { duration in self.now = self.now.advanced(by: duration) },
                now: { self.now }
            )
        }

        func run(validateFirst: Bool = false, polls: Bool = true) async -> SoundCloudSessionRecovery.Result {
            await SoundCloudSessionRecovery.run(
                validateFirst: validateFirst,
                polls: polls,
                window: .seconds(20),
                pollInterval: .seconds(4),
                environment: environment
            )
        }
    }

    @MainActor private final class World {
        var stored: StoredSession?
        var fetched: [SoundCloudSessionRenewal.SourceKind] = []
        var validated: [String] = []
    }

    func testKeepsLookingUntilAnotherDevicePublishesASession() async {
        let harness = Harness()
        harness.outcomes = [.exhausted, .exhausted, .adopted(.synced)]
        let result = await harness.run()
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(harness.attempts, 3)
    }

    func testGivesUpOnlyAfterTheWholeWindowFindsNothing() async {
        let harness = Harness()
        let result = await harness.run()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(harness.attempts, 6)
    }

    func testASessionAdoptedBySyncEndsRecoveryWithoutAnotherAttempt() async {
        let harness = Harness()
        harness.resolvedAfterAttempts = 2
        let result = await harness.run()
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(harness.attempts, 2)
    }

    func testAStillValidTokenNeedsNoRecovery() async {
        let harness = Harness()
        harness.validation = .valid
        let result = await harness.run(validateFirst: true)
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(harness.attempts, 0)
    }

    func testAnInconclusiveCheckNeverAsksForReconnect() async {
        let harness = Harness()
        harness.validation = .unavailable("offline")
        let result = await harness.run(validateFirst: true)
        XCTAssertEqual(result, .unresolved)
        XCTAssertEqual(harness.attempts, 0)
    }

    func testARejectedTokenStillLooksForAReplacement() async {
        let harness = Harness()
        harness.validation = .rejected
        harness.outcomes = [.adopted(.linkedPeer)]
        let result = await harness.run(validateFirst: true)
        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(harness.validations, 1)
        XCTAssertEqual(harness.attempts, 1)
    }

    func testTransientFailuresAtTheDeadlineStayUnresolved() async {
        let harness = Harness()
        harness.outcomes = Array(repeating: .temporarilyUnavailable, count: 10)
        let result = await harness.run()
        XCTAssertEqual(result, .unresolved)
    }

    func testWithNoPeerOrSyncSourceOnePassIsDefinitive() async {
        let harness = Harness()
        let result = await harness.run(polls: false)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(harness.attempts, 1)
    }

    func testRecoveryPassesSkipSilentWebAndCandidatesAlreadyTried() async {
        let world = World()
        world.stored = StoredSession(oauthToken: "a1", refreshToken: "r1", clientId: "c", expiresAt: nil)
        let stale = StoredSession(oauthToken: "a0", refreshToken: "r0", clientId: "c", expiresAt: nil)
        let renewal = SoundCloudSessionRenewal(
            environment: SoundCloudSessionRenewal.Environment(
                load: { world.stored },
                save: { world.stored = $0 },
                refresh: { _ in .unrecoverable },
                validate: { token in
                    world.validated.append(token)
                    return .rejected
                },
                isTrafficStopped: { false }
            ),
            sources: [
                SoundCloudSessionRenewal.Source(kind: .synced) { _ in
                    world.fetched.append(.synced)
                    return SoundCloudSessionRenewal.Candidate(session: stale)
                },
                SoundCloudSessionRenewal.Source(kind: .silentWeb) { _ in
                    world.fetched.append(.silentWeb)
                    return nil
                },
            ]
        )

        let first = await renewal.recover(kinds: [.synced, .linkedPeer], skipping: [])
        let second = await renewal.recover(kinds: [.synced, .linkedPeer], skipping: first.tried)

        XCTAssertEqual(first.outcome, .exhausted)
        XCTAssertEqual(second.outcome, .exhausted)
        XCTAssertEqual(world.fetched, [.synced, .synced])
        XCTAssertEqual(world.validated, ["a0"])
        XCTAssertEqual(world.stored?.oauthToken, "a1")
    }

    func testAdoptingASyncedSessionKeepsAHealthyAccountHealthy() {
        XCTAssertTrue(SoundCloudCredentialSourcePolicy.adoptionKeepsHealth(current: .healthy, adoptedIsExpired: false))
        XCTAssertFalse(SoundCloudCredentialSourcePolicy.adoptionKeepsHealth(current: .healthy, adoptedIsExpired: true))
        XCTAssertFalse(SoundCloudCredentialSourcePolicy.adoptionKeepsHealth(current: .unverified, adoptedIsExpired: false))
    }
}

final class SessionSyncChurnTests: XCTestCase {
    private func synced(_ token: String, writer: String, updated: Int64, issued: Int64?, tag: String? = "acct") -> SyncedSoundCloudSession {
        SyncedSoundCloudSession(
            oauthToken: token, refreshToken: "r-\(token)", clientId: "c", expiresAtMillis: 9_000_000,
            updatedAtMillis: updated, writerId: writer, issuedAtMillis: issued, generation: 0
        ).describingAccount(tag: tag, name: "Alex", writerName: nil, writerKind: nil)
    }

    func testTheSameTokensFromAnotherWriterNeverWin() {
        let mine = synced("a", writer: "aaa", updated: 500, issued: 500)
        let theirs = synced("a", writer: "zzz", updated: 900, issued: nil)
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: mine, remote: theirs, rejectedLineages: .memory()))
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: theirs, remote: mine, rejectedLineages: .memory()))
    }

    func testARotatedPairStillWins() {
        let mine = synced("a", writer: "aaa", updated: 500, issued: 500)
        let rotated = synced("b", writer: "zzz", updated: 900, issued: 900)
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: mine, remote: rotated, rejectedLineages: .memory()))
    }

    func testTheSameTokensAreNotPushedBackUnlessTheCloudCopyLacksTheAccount() {
        let mine = synced("a", writer: "aaa", updated: 500, issued: 500)
        XCTAssertTrue(SessionSyncPolicy.sameSessionNeedsNoPush(local: mine, remote: synced("a", writer: "zzz", updated: 900, issued: 900)))
        XCTAssertFalse(SessionSyncPolicy.sameSessionNeedsNoPush(local: mine, remote: synced("a", writer: "zzz", updated: 900, issued: 900, tag: nil)))
        XCTAssertFalse(SessionSyncPolicy.sameSessionNeedsNoPush(local: mine, remote: synced("b", writer: "zzz", updated: 900, issued: 900)))
    }
}
