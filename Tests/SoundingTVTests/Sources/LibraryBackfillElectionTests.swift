import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

final class LibraryBackfillElectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = LibraryBackfillPolicy.standard

    private func device(
        _ id: String,
        _ deviceClass: DeviceClass,
        power: Bool = true,
        seen: TimeInterval = 0
    ) -> LibraryBackfillCandidate {
        LibraryBackfillCandidate(id: id, deviceClass: deviceClass, isOnPower: power, lastSeen: now.addingTimeInterval(-seen))
    }

    private func lease(
        _ holder: LibraryBackfillCandidate,
        renewedAgo: TimeInterval = 0,
        pausedUntil: Date? = nil
    ) -> LibraryBackfillLease {
        LibraryBackfillElection.lease(for: holder, pausedUntil: pausedUntil, now: now.addingTimeInterval(-renewedAgo), policy: policy)
    }

    private func decide(
        _ me: LibraryBackfillCandidate,
        peers: [LibraryBackfillCandidate] = [],
        lease: LibraryBackfillLease? = nil,
        pausedUntil: Date? = nil,
        vacantFor: TimeInterval? = nil
    ) -> LibraryBackfillDecision {
        LibraryBackfillElection.decide(
            me: me,
            peers: peers,
            lease: lease,
            pausedUntil: pausedUntil,
            vacantSince: vacantFor.map { now.addingTimeInterval(-$0) },
            now: now,
            policy: policy
        )
    }

    // MARK: - Preference order

    func testRankPrefersMacOnPowerThenTabletsAndPhonesOnPowerThenEverythingElse() {
        let macOnPower = LibraryBackfillElection.rank(.mac, isOnPower: true)
        let padOnPower = LibraryBackfillElection.rank(.pad, isOnPower: true)
        let phoneOnPower = LibraryBackfillElection.rank(.phone, isOnPower: true)
        let macOnBattery = LibraryBackfillElection.rank(.mac, isOnPower: false)
        let phoneOnBattery = LibraryBackfillElection.rank(.phone, isOnPower: false)
        let tv = LibraryBackfillElection.rank(.tv, isOnPower: true)
        let watch = LibraryBackfillElection.rank(.watch, isOnPower: true)

        XCTAssertLessThan(macOnPower, padOnPower)
        XCTAssertEqual(padOnPower, phoneOnPower)
        XCTAssertLessThan(phoneOnPower, macOnBattery)
        XCTAssertEqual(macOnBattery, phoneOnBattery)
        XCTAssertLessThan(phoneOnBattery, tv)
        XCTAssertLessThan(tv, watch)
    }

    func testMacOnPowerClaimsAVacantLeaseAndThePhoneWaits() {
        let mac = device("mac", .mac)
        let phone = device("phone", .phone)
        let pad = device("pad", .pad)

        XCTAssertEqual(decide(mac, peers: [phone, pad]), .claim)
        XCTAssertEqual(decide(phone, peers: [mac, pad]), .follow)
        XCTAssertEqual(decide(pad, peers: [mac, phone]), .follow)
    }

    func testPhoneOnPowerBeatsMacOnBattery() {
        let mac = device("mac", .mac, power: false)
        let phone = device("phone", .phone, power: true)

        XCTAssertEqual(decide(phone, peers: [mac]), .claim)
        XCTAssertEqual(decide(mac, peers: [phone]), .follow)
    }

    func testEqualRanksBreakTiesByIdentifierOnEveryDevice() {
        let first = device("a-phone", .phone)
        let second = device("b-pad", .pad)

        XCTAssertEqual(decide(first, peers: [second]), .claim)
        XCTAssertEqual(decide(second, peers: [first]), .follow)
    }

    func testOnlyOneDeviceClaimsWhenEveryoneSeesTheSameRoster() {
        let roster = [
            device("mac", .mac, power: false),
            device("phone", .phone),
            device("pad", .pad, power: false),
            device("tv", .tv),
        ]
        let claims = roster.filter { me in
            decide(me, peers: roster.filter { $0.id != me.id }) == .claim
        }
        XCTAssertEqual(claims.map(\.id), ["phone"])
    }

    // MARK: - Lease lifetime

    func testHolderHoldsThenRenewsAfterTheRenewInterval() {
        let mac = device("mac", .mac)

        XCTAssertEqual(decide(mac, lease: lease(mac, renewedAgo: 60)), .hold)
        XCTAssertEqual(decide(mac, lease: lease(mac, renewedAgo: policy.renewInterval)), .renew)
    }

    func testOthersFollowAValidLeaseEvenWhenTheyOutrankTheHolder() {
        let mac = device("mac", .mac)
        let phone = device("phone", .phone, power: false)

        XCTAssertEqual(decide(mac, peers: [phone], lease: lease(phone, renewedAgo: 60)), .follow)
    }

    func testBestAliveDeviceTakesOverWhenTheLeaseExpires() {
        let mac = device("mac", .mac)
        let phone = device("phone", .phone)
        let expired = lease(phone, renewedAgo: policy.leaseDuration + 1)

        XCTAssertFalse(expired.isValid(at: now))
        XCTAssertEqual(decide(mac, peers: [phone], lease: expired), .claim)
        XCTAssertEqual(decide(phone, peers: [mac], lease: expired, vacantFor: 0), .follow)
    }

    func testLowerRankTakesOverAfterADelayWhenTheBetterDeviceStaysSilent() {
        let mac = device("mac", .mac)
        let phone = device("phone", .phone)

        XCTAssertEqual(decide(phone, peers: [mac], vacantFor: policy.takeoverStep - 1), .follow)
        XCTAssertEqual(decide(phone, peers: [mac], vacantFor: policy.takeoverStep), .claim)
    }

    func testDevicesThatAreNotOpenDoNotBlockTheElection() {
        let mac = device("mac", .mac, seen: policy.aliveWindow + 60)
        let phone = device("phone", .phone, power: false)

        XCTAssertEqual(decide(phone, peers: [mac]), .claim)
    }

    func testAPauseIsPublishedAndKeepsTheLeaseUntilItEnds() {
        let mac = device("mac", .mac)
        let pause = now.addingTimeInterval(45 * 60)
        let current = lease(mac, renewedAgo: 30)

        XCTAssertEqual(decide(mac, lease: current, pausedUntil: pause), .renew)

        let paused = LibraryBackfillElection.lease(for: mac, pausedUntil: pause, now: now, policy: policy)
        XCTAssertTrue(paused.isPaused(at: now))
        XCTAssertEqual(paused.expiresAt, pause.addingTimeInterval(policy.leaseDuration))
        XCTAssertEqual(decide(mac, lease: paused, pausedUntil: pause), .hold)
        XCTAssertEqual(decide(device("phone", .phone), peers: [mac], lease: paused), .follow)
    }

    func testAPastPauseIsNotPublished() {
        let mac = device("mac", .mac)
        let past = now.addingTimeInterval(-60)

        XCTAssertNil(LibraryBackfillElection.lease(for: mac, pausedUntil: past, now: now, policy: policy).pausedUntilMillis)
        XCTAssertEqual(decide(mac, lease: lease(mac, renewedAgo: 30), pausedUntil: past), .hold)
    }

    // MARK: - Apple TV and Apple Watch

    func testAppleTVNeverBackfillsWhenAnotherDeviceExists() {
        let tv = device("tv", .tv)
        let phone = device("phone", .phone, power: false, seen: 3 * 24 * 60 * 60)

        XCTAssertEqual(decide(tv, peers: [phone]), .follow)
        XCTAssertEqual(decide(tv, peers: [phone], vacantFor: 24 * 60 * 60), .follow)
        XCTAssertEqual(decide(tv), .claim)
    }

    func testAppleTVFollowsAPreviousHolderItHasNoRosterFor() {
        let tv = device("tv", .tv)
        let mac = device("mac", .mac)
        let expired = lease(mac, renewedAgo: 24 * 60 * 60)

        XCTAssertEqual(decide(tv, lease: expired), .follow)
    }

    func testAppleTVKnowsLinkedDevicesFromTheChunksTheySend() {
        let tv = device("tv", .tv)
        let writer = LibraryBackfillElection.writerCandidate(
            writerId: "phone.8C1F2A9E-0000-4000-8000-000000000000",
            seenAtMillis: LibraryBackfillElection.millis(now.addingTimeInterval(-3600))
        )

        XCTAssertEqual(writer?.deviceClass, .phone)
        XCTAssertEqual(writer?.contends, false)
        XCTAssertEqual(decide(tv, peers: writer.map { [$0] } ?? []), .follow)
        XCTAssertNil(LibraryBackfillElection.writerCandidate(writerId: "8C1F2A9E-0000-4000-8000-000000000000", seenAtMillis: 0))
    }

    func testWatchNeverBackfillsBesideAPhone() {
        let watch = device("watch", .watch)
        let phone = device("phone", .phone, power: false, seen: 24 * 60 * 60)

        XCTAssertEqual(decide(watch, peers: [phone]), .follow)
    }

    func testAppleTVDoesNotBlockAPhone() {
        let tv = device("a-tv", .tv)
        let phone = device("z-phone", .phone, power: false)

        XCTAssertEqual(decide(phone, peers: [tv]), .claim)
    }

    func testTwoAppleTVsAloneElectOne() {
        let first = device("living-room", .tv)
        let second = device("office", .tv)

        XCTAssertEqual(decide(first, peers: [second]), .claim)
        XCTAssertEqual(decide(second, peers: [first]), .follow)
    }

    func testChunkWritersNeverContend() {
        let phone = device("phone", .phone, power: false)
        guard var writer = LibraryBackfillElection.writerCandidate(
            writerId: "mac.0000",
            seenAtMillis: LibraryBackfillElection.millis(now)
        ) else { return XCTFail("writer") }
        writer.isOnPower = true

        XCTAssertEqual(decide(phone, peers: [writer]), .claim)
    }

    // MARK: - Compare and swap

    func testMayReplaceOnlyAVacantExpiredOrOwnLease() {
        let mac = device("mac", .mac)
        let phone = device("phone", .phone)
        let proposal = LibraryBackfillElection.lease(for: mac, pausedUntil: nil, now: now, policy: policy)

        XCTAssertTrue(LibraryBackfillElection.mayReplace(nil, with: proposal, now: now))
        XCTAssertTrue(LibraryBackfillElection.mayReplace(lease(mac, renewedAgo: 60), with: proposal, now: now))
        XCTAssertFalse(LibraryBackfillElection.mayReplace(lease(phone, renewedAgo: 60), with: proposal, now: now))
        XCTAssertTrue(LibraryBackfillElection.mayReplace(lease(phone, renewedAgo: policy.leaseDuration + 1), with: proposal, now: now))
    }

    func testNewerKeepsTheLatestRenewal() {
        let old = lease(device("phone", .phone), renewedAgo: 120)
        let fresh = lease(device("mac", .mac), renewedAgo: 10)

        XCTAssertEqual(LibraryBackfillElection.newer(old, fresh), fresh)
        XCTAssertEqual(LibraryBackfillElection.newer(fresh, old), fresh)
        XCTAssertEqual(LibraryBackfillElection.newer(nil, old), old)
        XCTAssertEqual(LibraryBackfillElection.newer(old, nil), old)
    }

    // MARK: - Wire format

    func testLeaseTravelsInALibraryChunk() throws {
        let held = lease(device("mac", .mac), pausedUntil: now.addingTimeInterval(600))
        let chunk = LibraryChunk.leaseChunk(account: "me", lease: held)

        XCTAssertTrue(chunk.isLease)
        XCTAssertFalse(chunk.isManifest)
        XCTAssertFalse(chunk.carriesRows)
        XCTAssertEqual(chunk.recordName, "me.lease.0")
        let decoded = try XCTUnwrap(chunk.encoded().flatMap(LibraryChunk.decode))
        XCTAssertEqual(decoded.lease, held)
    }

    func testChunksWithoutALeaseStillDecode() throws {
        let json = Data(#"{"account":"me","collection":"likes","bucket":0,"bucketCount":1,"updatedAtMillis":5,"writerId":"phone.x","rows":[]}"#.utf8)
        let chunk = try JSONDecoder().decode(LibraryChunk.self, from: json)

        XCTAssertNil(chunk.lease)
        XCTAssertTrue(chunk.carriesRows)
        let entry = try JSONDecoder().decode(LibraryManifestEntry.self, from: Data(#"{"count":3,"bucketCount":1}"#.utf8))
        XCTAssertNil(entry.patchedAtMillis)
    }
}

final class LibraryFollowerSyncTests: XCTestCase {
    private var directory: URL!
    private var clock: LibraryTestClock!
    private var store: LibrarySQLiteStore!
    private var remote: ScriptedLibraryRemote!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryFollowerSyncTests-\(UUID().uuidString)")
        clock = LibraryTestClock()
        let clock = clock!
        store = LibrarySQLiteStore(directory: directory, clock: { clock.now })
        remote = ScriptedLibraryRemote()
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibrarySQLiteStore {
        let clock = clock!
        return LibrarySQLiteStore(directory: directory.appendingPathComponent(UUID().uuidString), clock: { clock.now })
    }

    private func makeCore(store: LibrarySQLiteStore? = nil, remote: ScriptedLibraryRemote? = nil) -> LibrarySyncCore {
        let clock = clock!
        return LibrarySyncCore(store: store ?? self.store, remote: remote ?? self.remote, pacer: AllowAllLibraryPacer(), now: { clock.now })
    }

    func testFollowerWithAnEmptyDatabaseMakesNoRequests() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2", "3", "4"]))
        await remote.set(.followings, LibraryFixtures.users(["a"]))
        await remote.set(.ownPlaylists, [LibraryFixtures.playlist("p1", changeKey: "5|1")])
        let core = makeCore()

        let outcome = await core.run(account: "me", mode: .follow)

        XCTAssertEqual(outcome, .finished)
        let pages = await remote.pageRequests
        XCTAssertTrue(pages.isEmpty, pages.joined(separator: ","))
        let manifests = await remote.manifestRequests
        XCTAssertTrue(manifests.isEmpty)
        let cursor = await store.cursor(.likes)
        XCTAssertFalse(cursor.hasCompletedOnce)
    }

    func testFollowerReadsAdoptedChunksAndOnlyRefreshesTheLikesHeadPage() async {
        let ids = (1...7).map(String.init)
        await remote.set(.likes, LibraryFixtures.likes(ids))
        await remote.set(.followings, LibraryFixtures.users(["a", "b"]))
        await remote.set(.ownPlaylists, [LibraryFixtures.playlist("p1", changeKey: "5|1")])
        await remote.setManifest("p1", LibraryPlaylistManifest(trackIDs: ["1"], hydrated: [], changeKey: "5|1"))
        let backfiller = makeCore()
        _ = await backfiller.run(account: "me")
        let manifest = await backfiller.manifestChunk(account: "me", writerId: "mac.a")
        let rows = await backfiller.allChunks(account: "me", writerId: "mac.a")

        let followerStore = makeStore()
        _ = await followerStore.bind(account: "me")
        let followerRemote = ScriptedLibraryRemote()
        let fresh = LibraryFixtures.likes(["new"], newest: 2_000_000)
        await followerRemote.set(.likes, fresh + LibraryFixtures.likes(ids))
        await followerRemote.set(.followings, LibraryFixtures.users(["a", "b", "c"]))
        let follower = makeCore(store: followerStore, remote: followerRemote)
        _ = await follower.adopt([manifest] + rows, expectedAccount: "me")

        clock.advance(LibrarySyncPolicy.standard.patchInterval + 1)
        let outcome = await follower.run(account: "me", mode: .follow)

        XCTAssertEqual(outcome, .finished)
        let pages = await followerRemote.pageRequests
        XCTAssertEqual(pages, ["likes@0"])
        let manifests = await followerRemote.manifestRequests
        XCTAssertTrue(manifests.isEmpty)
        let head = await followerStore.keys(.likes, limit: 1)
        XCTAssertEqual(head, ["track:new"])
        let playlist = await followerStore.keys(.playlist("p1"), limit: nil)
        XCTAssertEqual(playlist, ["track:1"])
    }

    func testFollowerHonoursAUserRequestedPatchWithOnePage() async {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c", "d", "e", "f", "g"]))
        let core = makeCore()
        _ = await core.run(account: "me")
        await remote.set(.followings, LibraryFixtures.users(["z", "a", "b", "c", "d", "e", "f", "g"]))
        await remote.resetLog()

        await core.requestPatch(.followings)
        _ = await core.run(account: "me", mode: .follow)

        let pages = await remote.pageRequests
        XCTAssertEqual(pages, ["followings@0"])
        let head = await store.keys(.followings, limit: 1)
        XCTAssertEqual(head, ["user:z"])
    }

    func testRecentPatchKeepsAnOldBackfillAdoptable() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2"]))
        let source = makeCore()
        _ = await source.run(account: "me")

        clock.advance(8 * 24 * 60 * 60)
        _ = await source.run(account: "me", mode: .follow)
        let manifest = await source.manifestChunk(account: "me", writerId: "mac.a")
        let rows = await source.allChunks(account: "me", writerId: "mac.a")
        XCTAssertNotNil(manifest.manifest?[LibraryCollection.likes.key]?.patchedAtMillis)

        let targetStore = makeStore()
        _ = await targetStore.bind(account: "me")
        let target = makeCore(store: targetStore, remote: ScriptedLibraryRemote())
        _ = await target.adopt([manifest] + rows, expectedAccount: "me")

        let likes = await targetStore.cursor(.likes)
        XCTAssertTrue(likes.hasCompletedOnce)
    }

    func testLeaseChunksAreIgnoredByTheDatabase() async {
        _ = await store.bind(account: "me")
        let core = makeCore()
        let lease = LibraryBackfillElection.lease(
            for: LibraryBackfillCandidate(id: "mac", deviceClass: .mac, isOnPower: true, lastSeen: clock.now),
            pausedUntil: nil,
            now: clock.now
        )

        let applied = await core.adopt([.leaseChunk(account: "me", lease: lease)], expectedAccount: "me")

        XCTAssertEqual(applied, 0)
        let known = await store.knownCollections()
        XCTAssertTrue(known.isEmpty)
    }
}

#endif
