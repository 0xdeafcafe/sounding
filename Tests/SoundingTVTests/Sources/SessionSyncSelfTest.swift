import Foundation
@testable import SoundingTV

#if DEBUG

enum SessionSyncSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[SessionSyncTest] \(status)"] + lines.map { "[SessionSyncTest]   \($0)" }
                + failures.map { "[SessionSyncTest]   ✗ \($0)" }).joined(separator: "\n")
        }

        mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                lines.append(name)
            } else {
                let suffix = detail()
                failures.append(suffix.isEmpty ? name : "\(name): \(suffix)")
            }
        }
    }

    private static func session(token: String = "tok", updatedAtMillis: Int64, writerId: String = "device-a") -> SyncedSoundCloudSession {
        SyncedSoundCloudSession(
            oauthToken: token, refreshToken: "refresh-\(token)", clientId: "client",
            expiresAtMillis: 9_999_999_999, updatedAtMillis: updatedAtMillis, writerId: writerId
        )
    }

    static func run() async -> Report {
        var report = Report()
        testRemoteWinsPolicy(&report)
        testLocalSignOutSuppressesAdoption(&report)
        testBookkeepingWriterIdIsStable(&report)
        testBookkeepingOnlyAdvancesOnContentChange(&report)
        testBookkeepingPreservesForeignProvenance(&report)
        testBookkeepingSignOutRoundTrip(&report)
        testObservedDigestDefaultsRoundTrips(&report)
        await testRelayAdoptsAWinningRemote(&report)
        await testRelayDoesNotRepushAnIdenticalSession(&report)
        await testRelayPushesWhenLocalIsNewer(&report)
        await testRelayNeverPushesASignedOutDevice(&report)
        await testRelayHonoursAUserSignOut(&report)
        await testRelayResumesAfterSignOutCleared(&report)
        await testNotReadyTransportIsAnInertSkip(&report)
        return report
    }

    private static func testRemoteWinsPolicy(_ report: inout Report) {
        report.expect("no local session → remote always wins", SessionSyncPolicy.remoteWins(local: nil, remote: session(updatedAtMillis: 100)))

        let older = session(token: "a", updatedAtMillis: 100)
        let newer = session(token: "b", updatedAtMillis: 200)
        report.expect("a genuinely newer remote wins", SessionSyncPolicy.remoteWins(local: older, remote: newer))
        report.expect("an older remote does not win", !SessionSyncPolicy.remoteWins(local: newer, remote: older))

        let tieA = session(token: "a", updatedAtMillis: 500, writerId: "aaa")
        let tieB = session(token: "b", updatedAtMillis: 500, writerId: "zzz")
        report.expect(
            "an exact timestamp tie breaks deterministically on writerId, both directions agree",
            SessionSyncPolicy.remoteWins(local: tieA, remote: tieB) && !SessionSyncPolicy.remoteWins(local: tieB, remote: tieA)
        )

        let same = session(token: "same", updatedAtMillis: 300)
        report.expect("an identical record is a no-op, not a win", !SessionSyncPolicy.remoteWins(local: same, remote: same))
    }

    private static func testLocalSignOutSuppressesAdoption(_ report: inout Report) {
        let signOutAt: Int64 = 1_000

        let older = session(token: "before", updatedAtMillis: 500)
        report.expect(
            "a signed-out device does not adopt a remote from before the sign-out",
            !SessionSyncPolicy.remoteWins(local: nil, remote: older, localSignOutMillis: signOutAt)
        )

        let newer = session(token: "after", updatedAtMillis: 2_000)
        report.expect(
            "a remote NEWER than the sign-out still does not win — suppression is absolute until cleared locally",
            !SessionSyncPolicy.remoteWins(local: nil, remote: newer, localSignOutMillis: signOutAt)
        )

        let local = session(token: "mine", updatedAtMillis: 100)
        report.expect(
            "a stale sign-out flag never interferes once a local session exists again",
            SessionSyncPolicy.remoteWins(local: local, remote: newer, localSignOutMillis: signOutAt)
        )

        report.expect(
            "with no sign-out recorded, absence still adopts (previous behaviour preserved)",
            SessionSyncPolicy.remoteWins(local: nil, remote: newer, localSignOutMillis: nil)
        )
    }

    private static func testBookkeepingWriterIdIsStable(_ report: inout Report) {
        let (defaults, _) = scratchDefaults()
        let first = SessionSyncBookkeeping.writerId(defaults: defaults)
        let second = SessionSyncBookkeeping.writerId(defaults: defaults)
        report.expect("writerId is generated once and then stable", first == second && !first.isEmpty)
    }

    private static func testBookkeepingOnlyAdvancesOnContentChange(_ report: inout Report) {
        let (defaults, digestStore) = scratchDefaults()
        let digestA = SessionSyncBookkeeping.digest(oauthToken: "tok1", refreshToken: "r1", clientId: "c", expiresAtMillis: 1_000)
        let first = SessionSyncBookkeeping.recordIfChanged(digest: digestA, defaults: defaults, now: 100, store: digestStore)
        let repeated = SessionSyncBookkeeping.recordIfChanged(digest: digestA, defaults: defaults, now: 999, store: digestStore)
        report.expect(
            "reading the same content again does not advance the clock",
            first == 100 && repeated == 100,
            "first=\(first), repeated=\(repeated)"
        )

        let digestB = SessionSyncBookkeeping.digest(oauthToken: "tok2", refreshToken: "r1", clientId: "c", expiresAtMillis: 1_000)
        let afterRefresh = SessionSyncBookkeeping.recordIfChanged(digest: digestB, defaults: defaults, now: 999, store: digestStore)
        report.expect("a genuinely different token advances the clock", afterRefresh == 999)
    }

    private static func testBookkeepingPreservesForeignProvenance(_ report: inout Report) {
        let (defaults, digestStore) = scratchDefaults()
        let digest = SessionSyncBookkeeping.digest(oauthToken: "peer-tok", refreshToken: nil, clientId: nil, expiresAtMillis: nil)
        SessionSyncBookkeeping.adoptForeignProvenance(updatedAtMillis: 42, digest: digest, defaults: defaults, store: digestStore)
        report.expect(
            "adopting a foreign session stamps its own timestamp, not \"now\"",
            SessionSyncBookkeeping.lastUpdatedAtMillis(defaults: defaults) == 42
        )
        let reread = SessionSyncBookkeeping.recordIfChanged(digest: digest, defaults: defaults, now: 9_999, store: digestStore)
        report.expect(
            "re-observing the just-adopted content afterwards does not overwrite the preserved provenance",
            reread == 42, "got \(reread)"
        )
    }

    private static func testObservedDigestDefaultsRoundTrips(_ report: inout Report) {
        let suite = "SessionSyncDigestSelfTest.\(UUID().uuidString)"
        guard UserDefaults(suiteName: suite) != nil else {
            report.expect("the preference-backed digest store can be created", false)
            return
        }
        let key = "digest"
        let store = ObservedDigestStore(
            // These closures are @Sendable. Capture only the suite/key values
            // and resolve UserDefaults inside each operation instead of
            // retaining the non-Sendable UserDefaults instance.
            read: { UserDefaults(suiteName: suite)?.string(forKey: key) },
            write: { UserDefaults(suiteName: suite)?.set($0, forKey: key) },
            delete: { UserDefaults(suiteName: suite)?.removeObject(forKey: key) }
        )
        store.delete()
        let written = "defaults-roundtrip-\(UUID().uuidString)"
        store.write(written)
        let readBack = store.read()
        report.expect(
            "the preference-backed digest store round-trips a written digest",
            readBack == written,
            "wrote \(written) read \(readBack ?? "nil")"
        )
        store.delete()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private static func testBookkeepingSignOutRoundTrip(_ report: inout Report) {
        let (defaults, _) = scratchDefaults()
        report.expect(
            "no sign-out is recorded until the user makes one",
            SessionSyncBookkeeping.localSignOutMillis(defaults: defaults) == nil
        )
        SessionSyncBookkeeping.recordLocalSignOut(now: 777, defaults: defaults)
        report.expect(
            "a recorded sign-out reads back with its own timestamp",
            SessionSyncBookkeeping.localSignOutMillis(defaults: defaults) == 777
        )
        SessionSyncBookkeeping.clearLocalSignOut(defaults: defaults)
        report.expect(
            "clearing the sign-out returns the device to normal adoption",
            SessionSyncBookkeeping.localSignOutMillis(defaults: defaults) == nil
        )
    }

    @MainActor
    private final class FakeSource: SoundCloudSessionSyncSource {
        var current: SyncedSoundCloudSession?
        var adopted: SyncedSoundCloudSession?
        func currentSessionForSync() -> SyncedSoundCloudSession? { current }
        func adoptSyncedSession(_ session: SyncedSoundCloudSession) async { adopted = session }
    }

    private struct FakeTransport: SessionSyncTransport {
        let transportId = "memory"
        let ready: Bool
        let remote: SyncedSoundCloudSession?
        let sink: Sink

        actor Sink {
            private(set) var pushed: [SyncedSoundCloudSession] = []
            func record(_ session: SyncedSoundCloudSession) { pushed.append(session) }
        }

        init(ready: Bool = true, remote: SyncedSoundCloudSession? = nil, sink: Sink = Sink()) {
            self.ready = ready
            self.remote = remote
            self.sink = sink
        }

        func isReady() async -> Bool { ready }
        func push(_ session: SyncedSoundCloudSession) async throws { await sink.record(session) }
        func pull() async throws -> SyncedSoundCloudSession? { remote }
    }

    @MainActor
    private static func testRelayAdoptsAWinningRemote(_ report: inout Report) async {
        let source = FakeSource()
        source.current = session(token: "old", updatedAtMillis: 100)
        let remote = session(token: "new", updatedAtMillis: 200, writerId: "device-b")
        let transport = FakeTransport(remote: remote)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { nil })

        do {
            let result = try await relay.runOnce()
            report.expect(
                "a newer remote session is adopted, not re-pushed",
                result.adoptedRemote && !result.pushedLocal && source.adopted == remote
            )
        } catch {
            report.failures.append("relay adopt test threw: \(error)")
        }
    }

    @MainActor
    private static func testRelayPushesWhenLocalIsNewer(_ report: inout Report) async {
        let source = FakeSource()
        let local = session(token: "mine", updatedAtMillis: 500)
        source.current = local
        let remote = session(token: "stale", updatedAtMillis: 100, writerId: "device-b")
        let sink = FakeTransport.Sink()
        let transport = FakeTransport(remote: remote, sink: sink)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { nil })

        do {
            let result = try await relay.runOnce()
            let pushed = await sink.pushed
            report.expect(
                "a newer local session is pushed up rather than adopting the stale remote",
                result.pushedLocal && !result.adoptedRemote && pushed == [local]
            )
        } catch {
            report.failures.append("relay push test threw: \(error)")
        }
    }

    @MainActor
    private static func testRelayDoesNotRepushAnIdenticalSession(_ report: inout Report) async {
        let source = FakeSource()
        let same = session(token: "same", updatedAtMillis: 500)
        source.current = same
        let sink = FakeTransport.Sink()
        let transport = FakeTransport(remote: same, sink: sink)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { nil })

        do {
            let result = try await relay.runOnce()
            let pushed = await sink.pushed
            report.expect(
                "an identical cloud session is an inert match, not an endless re-save",
                result.pulledRemote && !result.adoptedRemote && !result.pushedLocal && pushed.isEmpty
            )
        } catch {
            report.failures.append("identical-session relay test threw: \(error)")
        }
    }

    @MainActor
    private static func testRelayNeverPushesASignedOutDevice(_ report: inout Report) async {
        let source = FakeSource()
        source.current = nil
        let sink = FakeTransport.Sink()
        let transport = FakeTransport(remote: nil, sink: sink)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { nil })

        do {
            let result = try await relay.runOnce()
            let pushed = await sink.pushed
            report.expect("a signed-out device offers nothing", !result.pushedLocal && pushed.isEmpty)
        } catch {
            report.failures.append("signed-out relay test threw: \(error)")
        }
    }

    @MainActor
    private static func testRelayHonoursAUserSignOut(_ report: inout Report) async {
        let source = FakeSource()
        source.current = nil
        let remote = session(token: "still-pushed-by-the-phone", updatedAtMillis: 9_999, writerId: "device-b")
        let sink = FakeTransport.Sink()
        let transport = FakeTransport(remote: remote, sink: sink)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { 1_000 })

        do {
            let result = try await relay.runOnce()
            let pushed = await sink.pushed
            report.expect(
                "a device the user signed out neither adopts the remote nor pushes anything, and says why",
                result.declinedBySignOut && !result.adoptedRemote && !result.pushedLocal
                    && source.adopted == nil && pushed.isEmpty,
                String(describing: result)
            )
        } catch {
            report.failures.append("sign-out relay test threw: \(error)")
        }
    }

    @MainActor
    private static func testRelayResumesAfterSignOutCleared(_ report: inout Report) async {
        let source = FakeSource()
        source.current = nil
        let remote = session(token: "back-again", updatedAtMillis: 9_999, writerId: "device-b")
        let transport = FakeTransport(remote: remote)
        let relay = SessionSyncRelay(source: source, transport: transport, localSignOutMillis: { nil })

        do {
            let result = try await relay.runOnce()
            report.expect(
                "clearing the sign-out restores normal adoption on the next round",
                result.adoptedRemote && !result.declinedBySignOut && source.adopted == remote
            )
        } catch {
            report.failures.append("resume relay test threw: \(error)")
        }
    }

    @MainActor
    private static func testNotReadyTransportIsAnInertSkip(_ report: inout Report) async {
        let relay = SessionSyncRelay(source: FakeSource(), transport: FakeTransport(ready: false), localSignOutMillis: { nil })
        do {
            let result = try await relay.runOnce()
            report.expect("a transport with no peer/account is an inert skip", result.skippedNotReady)
        } catch {
            report.failures.append("not-ready relay threw: \(error)")
        }
    }

    private static func scratchDefaults() -> (UserDefaults, ObservedDigestStore) {
        let name = "SessionSyncSelfTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let digestStore = ObservedDigestStore.memory()
        SessionSyncBookkeeping.clearObservedDigest(store: digestStore)
        return (defaults, digestStore)
    }
}
#endif
