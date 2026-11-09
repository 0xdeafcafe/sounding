import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class SessionRotationRaceTests: XCTestCase {
    @MainActor private final class FakeSoundCloud {
        var liveRefresh: Set<String> = []
        var liveAccess: Set<String> = []
        var refreshCalls: [String] = []
        var validateCalls: [String] = []
        private var minted = 0

        init(pair: StoredSession) {
            liveRefresh.insert(pair.refreshToken ?? "")
            liveAccess.insert(pair.oauthToken)
        }

        func refresh(_ token: String?) -> SoundCloudTokenRefresh.Outcome {
            let token = token ?? ""
            refreshCalls.append(token)
            guard liveRefresh.remove(token) != nil else { return .unrecoverable }
            liveAccess.removeAll()
            minted += 1
            let access = "access-\(minted)"
            let refresh = "refresh-\(minted)"
            liveRefresh.insert(refresh)
            liveAccess.insert(access)
            return .succeeded(.init(accessToken: access, refreshToken: refresh, expiresAt: Date(timeIntervalSinceNow: 3_600)))
        }

        func validate(_ access: String) -> SoundCloudTokenValidation {
            validateCalls.append(access)
            return liveAccess.contains(access) ? .valid : .rejected
        }
    }

    @MainActor private final class FakeCloud {
        var record: SyncedSoundCloudSession?
    }

    @MainActor private final class Device {
        let name: String
        let server: FakeSoundCloud
        let cloud: FakeCloud
        let ledger = RejectedLineageLedger.memory()
        var stored: StoredSession?
        var publishesRotations = true
        private(set) lazy var refresher: DeviceSessionRefresher = makeRefresher()

        init(_ name: String, server: FakeSoundCloud, cloud: FakeCloud, stored: StoredSession) {
            self.name = name
            self.server = server
            self.cloud = cloud
            self.stored = stored
        }

        private func makeRefresher() -> DeviceSessionRefresher {
            let refresher = DeviceSessionRefresher(environment: .init(
                perform: { [unowned self] token, _ in self.server.refresh(token) },
                reloadStored: { [unowned self] in self.stored },
                save: { [unowned self] in self.stored = $0 },
                ledger: ledger,
                ownsRefresh: true
            ))
            refresher.onRotation = { [unowned self] _, renewed in
                if self.publishesRotations { self.cloud.record = self.synced(renewed) }
            }
            return refresher
        }

        func synced(_ session: StoredSession) -> SyncedSoundCloudSession {
            let issued = session.issuedAt.map(SessionIssuance.millis(_:))
            return SyncedSoundCloudSession(
                oauthToken: session.oauthToken, refreshToken: session.refreshToken, clientId: session.clientId,
                expiresAtMillis: session.expiresAt.map(SessionIssuance.millis(_:)),
                updatedAtMillis: issued ?? 0, writerId: name,
                issuedAtMillis: issued, generation: session.generation.map(Int64.init)
            )
        }

        var renewal: SoundCloudSessionRenewal {
            let syncedSource = SoundCloudSessionRenewal.Source(kind: .synced) { [unowned self] phase in
                guard let remote = self.cloud.record else { return nil }
                if phase == .beforeRefresh {
                    let local = self.stored.map(self.synced(_:))
                    guard SessionSyncPolicy.remoteWins(local: local, remote: remote, rejectedLineages: self.ledger) else { return nil }
                }
                return SoundCloudSessionRenewal.Candidate(session: remote.storedSession)
            }
            return SoundCloudSessionRenewal(
                environment: .init(
                    load: { [unowned self] in self.stored },
                    save: { [unowned self] in self.stored = $0 },
                    refresh: { [unowned self] in await self.refresher.renew($0, trigger: "test on \(self.name)") },
                    validate: { [unowned self] in self.server.validate($0) },
                    isTrafficStopped: { false },
                    isRejectedLineage: { [unowned self] in self.ledger.rejects($0) }
                ),
                sources: [syncedSource]
            )
        }
    }

    private static let shared = StoredSession(
        oauthToken: "access-0", refreshToken: "refresh-0", clientId: "client",
        expiresAt: Date(timeIntervalSinceNow: -60), issuedAt: Date(timeIntervalSinceNow: -3_660), generation: 0
    )

    func testTwoDeviceRotationRaceAdoptsThePeersPairInsteadOfRefreshingTheDeadToken() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let cloud = FakeCloud()
        let phone = Device("phone", server: server, cloud: cloud, stored: Self.shared)
        let tv = Device("tv", server: server, cloud: cloud, stored: Self.shared)
        cloud.record = phone.synced(Self.shared)

        let tvOutcome = await tv.renewal.renew()
        let phoneOutcome = await phone.renewal.renew()

        XCTAssertEqual(tvOutcome, .refreshed)
        XCTAssertEqual(phoneOutcome, .adopted(.synced))
        XCTAssertEqual(server.refreshCalls, ["refresh-0"])
        XCTAssertEqual(phone.stored?.refreshToken, "refresh-1")
        XCTAssertEqual(phone.stored?.generation, 1)
        XCTAssertEqual(tv.stored?.refreshToken, "refresh-1")
    }

    func testInvalidGrantAdoptsTheSyncedPairAndNeverResendsTheDeadToken() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let cloud = FakeCloud()
        let phone = Device("phone", server: server, cloud: cloud, stored: Self.shared)
        let tv = Device("tv", server: server, cloud: cloud, stored: Self.shared)
        tv.publishesRotations = false
        cloud.record = phone.synced(Self.shared)

        _ = await tv.renewal.renew()
        let beforeSync = await phone.renewal.renew()
        let retried = await phone.renewal.renew()

        XCTAssertEqual(beforeSync, .exhausted)
        XCTAssertEqual(retried, .exhausted)
        XCTAssertEqual(server.refreshCalls, ["refresh-0", "refresh-0"])
        XCTAssertTrue(phone.ledger.rejects(Self.shared))

        cloud.record = tv.synced(tv.stored!)
        let afterSync = await phone.renewal.renew()

        XCTAssertEqual(afterSync, .adopted(.synced))
        XCTAssertEqual(phone.stored?.refreshToken, "refresh-1")
        XCTAssertEqual(server.refreshCalls, ["refresh-0", "refresh-0"])
    }

    func testExpiredNewerSyncedPairIsRefreshedInsteadOfTheOlderLocalToken() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let cloud = FakeCloud()
        let tv = Device("tv", server: server, cloud: cloud, stored: Self.shared)
        _ = await tv.renewal.renew()
        var published = tv.stored!
        published.expiresAt = Date(timeIntervalSinceNow: -60)
        cloud.record = tv.synced(published)
        let phone = Device("phone", server: server, cloud: cloud, stored: Self.shared)

        let outcome = await phone.renewal.renew()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertEqual(server.refreshCalls, ["refresh-0", "refresh-1"])
        XCTAssertEqual(phone.stored?.refreshToken, "refresh-2")
        XCTAssertEqual(cloud.record?.refreshToken, "refresh-2")
    }

    func testConcurrentRefreshesInOneAppSendOneRequest() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let phone = Device("phone", server: server, cloud: FakeCloud(), stored: Self.shared)
        let refresher = phone.refresher

        async let first = refresher.renew(Self.shared, trigger: "a")
        async let second = refresher.renew(Self.shared, trigger: "b")
        async let third = refresher.renew(Self.shared, trigger: "c")
        let outcomes = await [first, second, third]

        XCTAssertEqual(server.refreshCalls, ["refresh-0"])
        XCTAssertEqual(refresher.networkRefreshes, 1)
        for outcome in outcomes {
            guard case .succeeded(let credentials) = outcome else { return XCTFail("expected success, got \(outcome)") }
            XCTAssertEqual(credentials.refreshToken, "refresh-1")
        }
    }

    func testRefusedRefreshTokenIsNeverSentAgain() async {
        let server = FakeSoundCloud(pair: Self.shared)
        server.liveRefresh.removeAll()
        let phone = Device("phone", server: server, cloud: FakeCloud(), stored: Self.shared)

        let first = await phone.refresher.renew(Self.shared, trigger: "first")
        let second = await phone.refresher.renew(Self.shared, trigger: "second")

        XCTAssertEqual(first, .unrecoverable)
        XCTAssertEqual(second, .unrecoverable)
        XCTAssertEqual(server.refreshCalls, ["refresh-0"])
    }

    func testExtensionsNeverRefresh() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let refresher = DeviceSessionRefresher(environment: .init(
            perform: { token, _ in server.refresh(token) },
            reloadStored: { Self.shared },
            save: { _ in },
            ledger: .memory(),
            ownsRefresh: false
        ))

        let outcome = await refresher.renew(Self.shared, trigger: "share extension")

        XCTAssertEqual(outcome, .transient)
        XCTAssertTrue(server.refreshCalls.isEmpty)
    }

    func testExtensionPicksUpThePairTheAppRefreshed() async {
        var rotated = Self.shared
        rotated.oauthToken = "access-9"
        rotated.refreshToken = "refresh-9"
        rotated.issuedAt = Date()
        rotated.generation = 1
        let latest = rotated
        let refresher = DeviceSessionRefresher(environment: .init(
            perform: { _, _ in
                XCTFail("must not refresh")
                return .transient
            },
            reloadStored: { latest },
            save: { _ in },
            ledger: .memory(),
            ownsRefresh: false
        ))

        let outcome = await refresher.renew(Self.shared, trigger: "share extension")

        XCTAssertEqual(outcome, .succeeded(latest.asCredentials))
    }

    func test401RightAfterA200AdoptsTheNewerPairWithoutRefreshing() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let cloud = FakeCloud()
        var current = Self.shared
        current.expiresAt = Date(timeIntervalSinceNow: 3_000)
        let tv = Device("tv", server: server, cloud: cloud, stored: current)
        let phone = Device("phone", server: server, cloud: cloud, stored: current)
        _ = await tv.refresher.renew(current, trigger: "tv")
        XCTAssertEqual(server.validate("access-0"), .rejected)

        let outcome = await phone.renewal.adoptNewer()

        XCTAssertEqual(outcome, .adopted(.synced))
        XCTAssertEqual(server.refreshCalls, ["refresh-0"])
        XCTAssertEqual(phone.stored?.oauthToken, "access-1")
    }

    func test401RightAfterA200WithNoNewerPairWaitsInsteadOfRefreshing() async {
        let server = FakeSoundCloud(pair: Self.shared)
        let phone = Device("phone", server: server, cloud: FakeCloud(), stored: Self.shared)

        let outcome = await phone.renewal.adoptNewer()

        XCTAssertEqual(outcome, .temporarilyUnavailable)
        XCTAssertTrue(server.refreshCalls.isEmpty)
    }
}

@MainActor
final class SessionSyncSelfTestCase: XCTestCase {
    func testSessionSyncSelfTest() async {
        let report = await SessionSyncSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }
}

@MainActor
final class SessionIssuancePolicyTests: XCTestCase {
    private func synced(_ refresh: String, updated: Int64, issued: Int64?, generation: Int64? = nil, writer: String = "w") -> SyncedSoundCloudSession {
        SyncedSoundCloudSession(
            oauthToken: "a-\(refresh)", refreshToken: refresh, clientId: "c", expiresAtMillis: nil,
            updatedAtMillis: updated, writerId: writer, issuedAtMillis: issued, generation: generation
        )
    }

    func testIssueTimeBeatsObservationTime() {
        let olderPairObservedLater = synced("r1", updated: 9_000, issued: 1_000)
        let newerPair = synced("r2", updated: 5_000, issued: 5_000)
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: olderPairObservedLater, remote: newerPair, rejectedLineages: .memory()))
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: newerPair, remote: olderPairObservedLater, rejectedLineages: .memory()))
    }

    func testGenerationBreaksAnIssueTimeTie() {
        let first = synced("r1", updated: 1_000, issued: 1_000, generation: 3)
        let second = synced("r2", updated: 1_000, issued: 1_000, generation: 4)
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: first, remote: second, rejectedLineages: .memory()))
    }

    func testRefusedLineageNeverWinsAndAlwaysLoses() {
        let ledger = RejectedLineageLedger.memory()
        let dead = synced("dead", updated: 9_000, issued: 9_000)
        let alive = synced("alive", updated: 1_000, issued: 1_000)
        ledger.insert(dead.lineage!)
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: alive, remote: dead, rejectedLineages: ledger))
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: dead, remote: alive, rejectedLineages: ledger))
    }

    func testLegacyRecordsStillCompareByUpdatedAt() {
        let older = synced("r1", updated: 1_000, issued: nil)
        let newer = synced("r2", updated: 2_000, issued: nil)
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: older, remote: newer, rejectedLineages: .memory()))
    }

    func testCloudRecordCarriesIssuanceWithoutNewFields() {
        let session = synced("r1", updated: 1_234, issued: 1_234, generation: 7, writer: "device-a")
        let record = CloudSyncMapping.record(for: session)
        XCTAssertEqual(Set(record.allKeys().filter { record[$0] != nil }), ["updatedAtMillis", "writerId"])
        let decoded = CloudSyncMapping.session(from: record)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded?.writerId, "device-a")
    }

    func testRefreshAppliesIssuanceAndGeneration() {
        let base = StoredSession(oauthToken: "a", refreshToken: "r", clientId: "c", expiresAt: nil, issuedAt: Date(timeIntervalSince1970: 1), generation: 2)
        let renewed = base.applying(.init(accessToken: "b", refreshToken: "s", expiresAt: nil, issuedAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(renewed.generation, 3)
        XCTAssertTrue(renewed.isNewer(than: base))
        XCTAssertEqual(renewed.applying(renewed.asCredentials).generation, 3)
    }
}

@MainActor
final class AuthenticatedRequestHoldTests: XCTestCase {
    private final class StubSource: SoundCloudCredentialSourcing {
        var accessToken: String?
        var holdsAuthenticatedRequests: Bool
        var refreshes = 0
        var currentUser: User? { nil }

        init(token: String?, holds: Bool) {
            accessToken = token
            holdsAuthenticatedRequests = holds
        }

        func waitForCurrentUser() async -> User? { nil }
        func refreshAccessToken() async -> Bool {
            refreshes += 1
            return false
        }
        func handleUnauthorized() async -> SoundCloudUnauthorizedDisposition { .credentialRejected }
        func waitForRenewal() async {}
    }

    private static func isUnauthorized(_ error: any Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        return false
    }

    func testHoldPolicy() {
        XCTAssertTrue(SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(isSignedOut: false, hasStoredSession: true, health: .rejected(.accountRejected)))
        XCTAssertTrue(SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(isSignedOut: false, hasStoredSession: true, health: .rejected(.noRefreshCapability)))
        XCTAssertFalse(SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(isSignedOut: false, hasStoredSession: true, health: .rejected(.refreshUnreachable)))
        XCTAssertFalse(SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(isSignedOut: false, hasStoredSession: true, health: .healthy))
        XCTAssertFalse(SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(isSignedOut: true, hasStoredSession: false, health: .signedOut))
    }

    func testHeldRequestsNeverReachTheNetwork() async {
        let installed = SoundCloudAPI.credentials
        defer { SoundCloudAPI.credentials = installed }
        SoundCloudAPI.credentials = StubSource(token: nil, holds: true)

        for path in ["charts/selections", "mixed-selections", "me/library/all"] {
            do {
                try await SoundCloudAPI.shared.admitAuthenticatedRequest(URL(string: "https://api-v2.soundcloud.com/\(path)")!)
                XCTFail("\(path) should be held")
            } catch {
                XCTAssertTrue(Self.isUnauthorized(error))
            }
        }
    }

    func testMeIsNeverSentWithoutAToken() async {
        let installed = SoundCloudAPI.credentials
        defer { SoundCloudAPI.credentials = installed }
        SoundCloudAPI.credentials = StubSource(token: nil, holds: false)

        do {
            _ = try await SoundCloudAPI.shared.getCurrentUser()
            XCTFail("an anonymous /me must not be sent")
        } catch {
            XCTAssertTrue(Self.isUnauthorized(error))
        }
    }

    func testA401IsNotRetriedUnlessThePairChanged() async {
        let installed = SoundCloudAPI.credentials
        defer { SoundCloudAPI.credentials = installed }
        let stub = StubSource(token: "same", holds: false)
        SoundCloudAPI.credentials = stub

        let retry = await SoundCloudAPI.shared.refreshCredentialsAfterUnauthorized(sentWith: "same")
        XCTAssertFalse(retry)
        XCTAssertEqual(stub.refreshes, 1)

        let replaced = await SoundCloudAPI.shared.refreshCredentialsAfterUnauthorized(sentWith: "older")
        XCTAssertTrue(replaced)
        XCTAssertEqual(stub.refreshes, 1)

        XCTAssertFalse(SoundCloudUnauthorizedRetryPolicy.shouldRetryAfterRecovery(recovered: true, sentToken: "same", currentToken: "same"))
        XCTAssertFalse(SoundCloudUnauthorizedRetryPolicy.shouldRetryAfterRecovery(recovered: false, sentToken: "same", currentToken: "new"))
        XCTAssertTrue(SoundCloudUnauthorizedRetryPolicy.shouldRetryAfterRecovery(recovered: true, sentToken: "same", currentToken: "new"))
    }
}

@MainActor
final class RefreshLogDetailTests: XCTestCase {
    func testTokenEndpointFailureRecordsTheOAuthCodeAndTrigger() async throws {
        let defaultsName = "RefreshLogDetailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let transport = SoundCloudHTTPTransport { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
        }
        let log = NetworkActivityLog()
        let gateway = SoundCloudGateway(transport: transport, defaults: defaults, random: { 0.5 }, sleep: { _ in }, networkLog: log)
        gateway.setApplicationActivity(.foreground)
        var request = URLRequest(url: URL(string: "https://secure.soundcloud.com/oauth/token")!)
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=refresh_token&refresh_token=SECRET-REFRESH".utf8)

        _ = try await NetworkActivityLog.$detail.withValue("refresh on phone, 401 handler") {
            try await gateway.data(for: request, context: .init(lane: .authentication, coalesces: false))
        }

        let entry = try XCTUnwrap(log.snapshot().last)
        XCTAssertEqual(entry.detail, "refresh on phone, 401 handler; oauth error invalid_grant")
        let exported = log.exportText()
        XCTAssertTrue(exported.contains("oauth error invalid_grant"))
        XCTAssertFalse(exported.contains("SECRET-REFRESH"))
        XCTAssertTrue(NetworkActivityLog.exportHeader.hasSuffix("\tdetail"))
    }

    func testDetailNeverCarriesOpaqueValues() {
        XCTAssertNil(NetworkActivityLog.sanitizedDetail("refresh abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"))
        XCTAssertNil(NetworkActivityLog.sanitizedDetail("eyJhbGciOi"))
        XCTAssertEqual(NetworkActivityLog.sanitizedDetail("refresh on tv, launch"), "refresh on tv, launch")
    }

    func testOAuthCodeOnlyForTheAuthenticationLane() {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        XCTAssertEqual(SoundCloudGateway.oauthErrorDetail(context: .init(lane: .authentication), status: 400, body: body), "oauth error invalid_grant")
        XCTAssertNil(SoundCloudGateway.oauthErrorDetail(context: .init(lane: .authentication), status: 200, body: body))
        XCTAssertNil(SoundCloudGateway.oauthErrorDetail(context: .init(lane: .metadata), status: 400, body: body))
        XCTAssertEqual(SoundCloudGateway.oauthErrorDetail(context: .init(lane: .authentication), status: 400, body: Data("nope".utf8)), "oauth error unreadable")
    }
}
