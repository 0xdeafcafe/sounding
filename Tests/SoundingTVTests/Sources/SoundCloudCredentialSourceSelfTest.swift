import Foundation
import XCTest
@testable import SoundingTV

final class SoundCloudCredentialSourceTests: XCTestCase {
    @MainActor
    func testCredentialSourceSelfTest() {
        let report = SoundCloudCredentialSourceSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }
}

@MainActor
enum SoundCloudCredentialSourceSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[SoundCloudCredentialSourceTest] \(status)"] + lines.map { "[SoundCloudCredentialSourceTest]   \($0)" }
                + failures.map { "[SoundCloudCredentialSourceTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        healthCases(&report)
        refreshResponseCases(&report)
        refreshPresentationCases(&report)
        devSeedCases(&report)
        storedSessionCases(&report)
        launchPresentationCases(&report)
        return report
    }

    private static func launchPresentationCases(_ report: inout Report) {
        func needs(
            establishing: Bool, signedOut: Bool, healthNeedsSignIn: Bool, explicitSignOut: Bool
        ) -> Bool {
            SoundCloudCredentialSourcePolicy.needsSignIn(
                isEstablishingSessionAtLaunch: establishing,
                isSignedOut: signedOut,
                healthNeedsSignIn: healthNeedsSignIn,
                hasExplicitLocalSignOut: explicitSignOut
            )
        }
        expect(&report, "establishing + transiently unusable store keeps the shell",
               !needs(establishing: true, signedOut: true, healthNeedsSignIn: true, explicitSignOut: false))
        expect(&report, "establishing + recorded sign-out goes straight to sign-in",
               needs(establishing: true, signedOut: true, healthNeedsSignIn: true, explicitSignOut: true))
        expect(&report, "establishing + usable session keeps the shell",
               !needs(establishing: true, signedOut: false, healthNeedsSignIn: true, explicitSignOut: false))
        expect(&report, "settled + signed out requires sign-in",
               needs(establishing: false, signedOut: true, healthNeedsSignIn: false, explicitSignOut: false))
        expect(&report, "settled + rejected health requires sign-in",
               needs(establishing: false, signedOut: false, healthNeedsSignIn: true, explicitSignOut: false))
        expect(&report, "settled + healthy needs nothing",
               !needs(establishing: false, signedOut: false, healthNeedsSignIn: false, explicitSignOut: false))
    }

    private static func refreshResponseCases(_ report: inout Report) {
        func body(_ error: String) -> Data { Data(#"{"error":"\#(error)"}"#.utf8) }

        expect(&report, "invalid_grant rejects the refresh attempt",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 400, data: body("invalid_grant")) == .unrecoverable)
        expect(&report, "invalid_client is not retried as a user token",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 401, data: body("invalid_client")) == .unrecoverable)
        expect(&report, "generic 401 remains retryable",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 401, data: Data()) == .transient)
        expect(&report, "generic 403 remains retryable",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 403, data: Data()) == .transient)
        expect(&report, "403 body cannot masquerade as OAuth rejection",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 403, data: body("invalid_grant")) == .transient)
        expect(&report, "rate-limited refresh remains retryable",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 429, data: body("rate_limited")) == .transient)
        expect(&report, "malformed refresh request does not erase auth",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 400, data: body("invalid_request")) == .transient)
        expect(&report, "server refresh failure remains retryable",
               SoundCloudTokenRefresh.failureOutcome(statusCode: 503, data: Data()) == .transient)
    }

    private static func refreshPresentationCases(_ report: inout Report) {
        expect(&report, "rejected refresh + valid token preserves signed-in UI",
               !SoundCloudCredentialSourcePolicy.launchRefreshRequiresReconnect(
                    refreshOutcome: .unrecoverable,
                    tokenValidation: .valid
               ))
        expect(&report, "rejected refresh + inconclusive probe preserves signed-in UI",
               !SoundCloudCredentialSourcePolicy.launchRefreshRequiresReconnect(
                    refreshOutcome: .unrecoverable,
                    tokenValidation: .unavailable("offline")
               ))
        expect(&report, "only rejected refresh + rejected token requests reconnect",
               SoundCloudCredentialSourcePolicy.launchRefreshRequiresReconnect(
                    refreshOutcome: .unrecoverable,
                    tokenValidation: .rejected
               ))
        expect(&report, "transient refresh never requests reconnect",
               !SoundCloudCredentialSourcePolicy.launchRefreshRequiresReconnect(
                    refreshOutcome: .transient,
                    tokenValidation: .rejected
               ))
    }

    private static func expect(_ report: inout Report, _ label: String, _ condition: Bool) {
        if condition { report.lines.append("\(label): ok") } else { report.failures.append(label) }
    }

    private static func healthCases(_ report: inout Report) {
        typealias Health = SoundCloudCredentialSource.SessionHealth

        expect(&report, "no session → signedOut",
               SoundCloudCredentialSourcePolicy.health(hasUsableSession: false, rejection: nil, hasSucceeded: false) == Health.signedOut)

        expect(&report, "no session outranks past success",
               SoundCloudCredentialSourcePolicy.health(hasUsableSession: false, rejection: nil, hasSucceeded: true) == Health.signedOut)

        expect(&report, "stored, untried → unverified",
               SoundCloudCredentialSourcePolicy.health(hasUsableSession: true, rejection: nil, hasSucceeded: false) == Health.unverified)

        expect(&report, "stored, succeeded → healthy",
               SoundCloudCredentialSourcePolicy.health(hasUsableSession: true, rejection: nil, hasSucceeded: true) == Health.healthy)

        expect(&report, "unverified session keeps app shell",
               !Health.unverified.needsSignIn && Health.unverified.canMakeAuthenticatedRequests)
        expect(&report, "transient refresh failure keeps app shell",
               !Health.rejected(.refreshUnreachable).needsSignIn
               && Health.rejected(.refreshUnreachable).canMakeAuthenticatedRequests)
        expect(&report, "unrecoverable rejection requires sign-in",
               Health.rejected(.accountRejected).needsSignIn
               && !Health.rejected(.accountRejected).canMakeAuthenticatedRequests)

        for kind in [SoundCloudCredentialSource.RejectionKind.accountRejected,
                     .noRefreshCapability,
                     .refreshUnreachable] {
            expect(&report, "stored + \(kind) → rejected",
                   SoundCloudCredentialSourcePolicy.health(hasUsableSession: true, rejection: kind, hasSucceeded: false) == Health.rejected(kind))
            expect(&report, "\(kind) outranks past success",
                   SoundCloudCredentialSourcePolicy.health(hasUsableSession: true, rejection: kind, hasSucceeded: true) == Health.rejected(kind))
        }
    }

    private static func devSeedCases(_ report: inout Report) {
        typealias Action = SoundCloudCredentialSourcePolicy.DevSeedAction

        expect(&report, "sign-out suppresses the cache",
               SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: true, hasLocalSignOut: true,
                                             hasEnvironmentToken: false, hasCachedCredential: true)
               == Action.skipSuppressedBySignOut)

        expect(&report, "no sign-out → cache seeds",
               SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: true, hasLocalSignOut: false,
                                             hasEnvironmentToken: false, hasCachedCredential: true)
               == Action.seedFromCache)

        expect(&report, "env token lifts sign-out, flagged",
               SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: true, hasLocalSignOut: true,
                                             hasEnvironmentToken: true, hasCachedCredential: false)
               == Action.seedFromEnvironment(liftsSignOut: true))

        expect(&report, "env token without sign-out isn't flagged",
               SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: true, hasLocalSignOut: false,
                                             hasEnvironmentToken: true, hasCachedCredential: false)
               == Action.seedFromEnvironment(liftsSignOut: false))

        for signOut in [true, false] {
            for env in [true, false] {
                expect(&report, "occupied store is never overwritten (signOut=\(signOut), env=\(env))",
                       SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: false, hasLocalSignOut: signOut,
                                                     hasEnvironmentToken: env, hasCachedCredential: true)
                       == Action.skipStoreOccupied)
            }
        }

        expect(&report, "nothing to seed from",
               SoundCloudCredentialSourcePolicy.devSeedAction(storeIsEmpty: true, hasLocalSignOut: false,
                                             hasEnvironmentToken: false, hasCachedCredential: false)
               == Action.skipNoCredential)
    }

    private static func storedSessionCases(_ report: inout Report) {
        let cookieShaped = StoredSession(oauthToken: "t", refreshToken: nil, clientId: nil, expiresAt: nil)
        expect(&report, "cookie-shaped session reads usable", cookieShaped.isUsable)
        expect(&report, "cookie-shaped session cannot self-refresh", !cookieShaped.canSelfRefresh)

        let empty = StoredSession(oauthToken: "", refreshToken: nil, clientId: nil, expiresAt: nil)
        expect(&report, "empty token is unusable", !empty.isUsable)

        let expiredNoRefresh = StoredSession(oauthToken: "t", refreshToken: nil, clientId: nil,
                                             expiresAt: Date(timeIntervalSinceNow: -3600))
        expect(&report, "expired without refresh is unusable", !expiredNoRefresh.isUsable)

        let expiredRefreshable = StoredSession(oauthToken: "t", refreshToken: "r", clientId: "c",
                                               expiresAt: Date(timeIntervalSinceNow: -3600))
        expect(&report, "expired but refreshable stays usable", expiredRefreshable.isUsable)
        expect(&report, "expired but refreshable wants a pre-handoff refresh",
               expiredRefreshable.shouldRefreshBeforeHandoff)
    }
}
