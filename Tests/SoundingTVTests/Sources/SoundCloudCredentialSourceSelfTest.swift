import Foundation
@testable import SoundingTV

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
        devSeedCases(&report)
        storedSessionCases(&report)
        return report
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
