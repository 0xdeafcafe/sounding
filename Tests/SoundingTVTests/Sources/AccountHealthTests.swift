import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class AccountHealthTests: XCTestCase {
    private typealias Policy = SoundCloudUnauthorizedPolicy

    func testTransientFailuresStayHealthy() {
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: .transient, canSelfRefresh: true, validation: nil), .wait)
        XCTAssertEqual(Policy.verdict(trafficStopped: true, refresh: .unrecoverable, canSelfRefresh: true, validation: .rejected), .wait)
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: nil, canSelfRefresh: true, validation: .rejected), .wait)
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: .unrecoverable, canSelfRefresh: true, validation: .unavailable("HTTP 429")), .wait)
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: .unrecoverable, canSelfRefresh: true, validation: .unavailable("timed out")), .wait)
        for status in [429, 500, 502, 503, 504, 403] {
            XCTAssertEqual(
                SoundCloudTokenRefresh.failureOutcome(statusCode: status, data: Data(#"{"error":"invalid_grant"}"#.utf8)),
                .transient
            )
        }
        XCTAssertEqual(SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: false, isSignedOut: false, health: .unverified), .signedIn)
        XCTAssertEqual(SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: false, isSignedOut: false, health: .rejected(.refreshUnreachable)), .signedIn)
    }

    func testInvalidGrantShowsReconnect() {
        let outcome = SoundCloudTokenRefresh.failureOutcome(statusCode: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
        XCTAssertEqual(outcome, .unrecoverable)
        XCTAssertTrue(Policy.needsValidation(refresh: outcome, canSelfRefresh: true))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: outcome, canSelfRefresh: true, validation: .rejected), .reconnect(.accountRejected))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: outcome, canSelfRefresh: true, validation: .valid), .keep)
        XCTAssertEqual(
            SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: false, isSignedOut: false, health: .rejected(.accountRejected)),
            .needsReconnect
        )
        XCTAssertEqual(
            SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: true, isSignedOut: false, health: .rejected(.accountRejected)),
            .signedIn
        )
    }

    func testRepeated401AfterSuccessfulRefreshShowsReconnect() {
        let refreshed = SoundCloudTokenRefresh.Outcome.succeeded(.init(accessToken: "a2", refreshToken: "r2", expiresAt: nil))
        XCTAssertTrue(Policy.needsValidation(refresh: refreshed, canSelfRefresh: true))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: refreshed, canSelfRefresh: true, validation: .rejected), .reconnect(.accountRejected))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: refreshed, canSelfRefresh: true, validation: .valid), .keep)
    }

    func testSessionWithoutRefreshMaterialNeedsSignInOnlyWhenMeRejects() {
        XCTAssertTrue(Policy.needsValidation(refresh: nil, canSelfRefresh: false))
        XCTAssertFalse(Policy.needsValidation(refresh: nil, canSelfRefresh: true))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: nil, canSelfRefresh: false, validation: .rejected), .reconnect(.noRefreshCapability))
        XCTAssertEqual(Policy.verdict(trafficStopped: false, refresh: nil, canSelfRefresh: false, validation: .unavailable("offline")), .wait)
    }

    func testRenewalRetriesBackOffAndStop() {
        let delays = SoundCloudCredentialSource.renewalRetryDelays
        XCTAssertEqual(delays.count, 4)
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(Policy.retryDelay(attempt: 0, delays: delays), delays[0])
        XCTAssertEqual(Policy.retryDelay(attempt: 3, delays: delays), delays[3])
        XCTAssertNil(Policy.retryDelay(attempt: 4, delays: delays))
    }

    func testReconnectClearsTheBannerAndReloadsHome() {
        var state = SoundCloudCredentialSource.PublishedAuthState(
            currentUser: VisualFixtures.currentUser,
            isSignedOut: false,
            isAuthenticated: false,
            lastSignOutReason: .accountRejected,
            sessionHealth: .rejected(.accountRejected)
        )
        XCTAssertEqual(SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: false, isSignedOut: false, health: state.sessionHealth), .needsReconnect)
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .needsReconnect, canAuthenticate: false), .keepCached)
        XCTAssertNil(DiscoveryHomeSource.confirmedAccountKey(state))

        state.signInGeneration &+= 1
        state.sessionHealth = .unverified
        state.lastSignOutReason = nil
        XCTAssertEqual(SoundCloudAccountStatus.resolve(isEstablishingSessionAtLaunch: false, isSignedOut: false, health: state.sessionHealth), .signedIn)
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .signedIn, canAuthenticate: true), .load)

        state.sessionHealth = .healthy
        state.isAuthenticated = true
        let after = DiscoveryHomeSource.confirmedAccountKey(state)
        XCTAssertNotNil(after)

        var beforeTheRejection = state
        beforeTheRejection.signInGeneration = 0
        XCTAssertNotEqual(DiscoveryHomeSource.confirmedAccountKey(beforeTheRejection), after)
    }

    func testHomeNeverLoadsGuestShelvesWhileAnAccountExists() {
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .signedOut, canAuthenticate: false), .load)
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .needsReconnect, canAuthenticate: false), .keepCached)
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .signedIn, canAuthenticate: false), .keepCached)
        XCTAssertEqual(DiscoveryHomeSource.feedAction(accountStatus: .signedIn, canAuthenticate: true), .load)
    }

    func testHomeRefreshKeepsShelvesWhoseSourceFailed() {
        func shelf(_ id: String, _ kind: DiscoveryShelf.Kind) -> DiscoveryShelf {
            DiscoveryShelf(id: id, title: id, subtitle: nil, kind: kind, content: .stations([]))
        }
        let current = [shelf("e1", .editorial), shelf("e2", .editorial), shelf("r", .related), shelf("t", .trending)]
        let merged = DiscoveryHomeSource.applying([(kind: .trending, shelves: [shelf("t2", .trending)])], to: current)
        XCTAssertEqual(merged.map(\.id), ["e1", "e2", "r", "t2"])
        XCTAssertEqual(DiscoveryHomeSource.applying([], to: current).map(\.id), current.map(\.id))
        let replaced = DiscoveryHomeSource.applying([(kind: .editorial, shelves: [shelf("e3", .editorial)])], to: current)
        XCTAssertEqual(replaced.map(\.id), ["e3", "r", "t"])
    }

    private static let past = Date(timeIntervalSinceNow: -3_600)
    private static let future = Date(timeIntervalSinceNow: 3_600)

    @MainActor private final class World {
        var stored: StoredSession?
        var refreshes: [String] = []
        var outcomes: [String: SoundCloudTokenRefresh.Outcome] = [:]
        var onRefresh: ((String) -> Void)?
    }

    private func renewal(_ world: World) -> SoundCloudSessionRenewal {
        SoundCloudSessionRenewal(
            environment: .init(
                load: { world.stored },
                save: { world.stored = $0 },
                refresh: { session in
                    let token = session.refreshToken ?? ""
                    world.refreshes.append(token)
                    world.onRefresh?(token)
                    return world.outcomes[token] ?? .unrecoverable
                },
                validate: { _ in .rejected },
                isTrafficStopped: { false }
            ),
            sources: []
        )
    }

    func testLaunchWithAnExpiredAccessTokenRenewsSilently() async {
        let world = World()
        world.stored = StoredSession(oauthToken: "a1", refreshToken: "r1", clientId: "c", expiresAt: Self.past)
        world.outcomes["r1"] = .succeeded(.init(accessToken: "a2", refreshToken: "r2", expiresAt: Self.future))

        let outcome = await renewal(world).renew()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(world.stored?.oauthToken, "a2")
        XCTAssertEqual(world.stored?.refreshToken, "r2")
        XCTAssertEqual(world.stored?.isExpired, false)
    }

    func testRefreshTokenRotatedByAnotherRefresherIsNotARejection() async {
        let world = World()
        world.stored = StoredSession(oauthToken: "a1", refreshToken: "r1", clientId: "c", expiresAt: Self.past)
        world.onRefresh = { token in
            guard token == "r1" else { return }
            world.stored = StoredSession(oauthToken: "a2", refreshToken: "r2", clientId: "c", expiresAt: Self.future)
        }

        let outcome = await renewal(world).renew()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(world.stored?.refreshToken, "r2")
    }

    func testSharedTokenIsNotRevokedOnLocalSignOut() {
        XCTAssertEqual(SessionRevocation.decide(scope: .thisDevice, tokenIsShared: true), .none)
        XCTAssertEqual(SessionRevocation.decide(scope: .thisDevice, tokenIsShared: false), .signOut)
    }

    func testSignOutEverywhereRevokesTheGrant() {
        for shared in [true, false] {
            XCTAssertEqual(SessionRevocation.decide(scope: .everywhere, tokenIsShared: shared), .signOutAndDisconnect)
        }
        XCTAssertEqual(SessionRevocation.signOutAndDisconnect.paths, ["sign-out"])
        XCTAssertEqual(SessionRevocation.signOut.paths, ["sign-out"])
        XCTAssertTrue(SessionRevocation.none.paths.isEmpty)
    }

    func testRevocationRequestCarriesTheTokenOnlyInTheHeader() throws {
        let request = try XCTUnwrap(SoundCloudSessionRevoker.request(path: "sign-out", token: "abc"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.soundcloud.com/sign-out")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth abc")
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertTrue(SoundCloudHostPolicy.allows(try XCTUnwrap(request.url), lane: .authentication))
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/sign-out", lane: "authentication"), .signOut)
        XCTAssertEqual(NetworkFeature.soundCloud(path: "/disconnect", lane: "authentication"), .signOut)
    }
}
