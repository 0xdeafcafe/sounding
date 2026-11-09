import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

final class LibraryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

actor ScriptedLibraryRemote: LibraryRemote {
    var lists: [LibraryCollection: [LibraryRecord]] = [:]
    var manifests: [String: LibraryPlaylistManifest] = [:]
    var goneManifests: Set<String> = []
    var trackPool: [String: LibraryRecord] = [:]
    var counts: [LibraryCollection: Int] = [:]
    var pageSize = 3
    var failures: [Int: LibraryRemoteError] = [:]
    private(set) var pageRequests: [String] = []
    private(set) var manifestRequests: [String] = []
    private(set) var trackRequests: [[String]] = []
    private var requestIndex = 0

    func set(_ collection: LibraryCollection, _ records: [LibraryRecord]) { lists[collection] = records }
    func setManifest(_ id: String, _ manifest: LibraryPlaylistManifest) { manifests[id] = manifest }
    func setGone(_ id: String) { goneManifests.insert(id) }
    func setPool(_ records: [LibraryRecord]) { for record in records { trackPool[record.id] = record } }
    func setCount(_ collection: LibraryCollection, _ count: Int) { counts[collection] = count }
    func setPageSize(_ size: Int) { pageSize = size }
    func failAt(_ index: Int, _ error: LibraryRemoteError) { failures[index] = error }
    func failNext(_ errors: [LibraryRemoteError]) {
        for (offset, error) in errors.enumerated() { failures[requestIndex + offset] = error }
    }
    func resetLog() {
        pageRequests = []
        manifestRequests = []
        trackRequests = []
    }

    private func gate() throws {
        defer { requestIndex += 1 }
        if let error = failures.removeValue(forKey: requestIndex) { throw error }
    }

    func page(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage {
        let offset = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value }.flatMap(Int.init) ?? 0
        pageRequests.append("\(collection.key)@\(offset)")
        try gate()
        let all = lists[collection] ?? []
        let slice = Array(all.dropFirst(offset).prefix(pageSize))
        let end = offset + slice.count
        let next = end < all.count
            ? URL(string: "https://api-v2.soundcloud.com/users/1/\(collection.key)?offset=\(end)&limit=\(pageSize)&linked_partitioning=1")
            : nil
        return LibraryPage(records: slice, next: next)
    }

    func playlistManifest(id: String) async throws -> LibraryPlaylistManifest {
        manifestRequests.append(id)
        try gate()
        if goneManifests.contains(id) { throw LibraryRemoteError.gone }
        return manifests[id] ?? LibraryPlaylistManifest(trackIDs: [], hydrated: [], changeKey: nil)
    }

    func tracks(ids: [String]) async throws -> [LibraryRecord] {
        trackRequests.append(ids)
        try gate()
        return ids.compactMap { trackPool[$0] }
    }

    func expectedCounts() async -> [LibraryCollection: Int] { counts }
}

struct AllowAllLibraryPacer: LibraryPacer {
    func admit(_ collection: LibraryCollection) async -> Bool { true }
    func retryDelay(attempt: Int) async {}
}

actor LimitedLibraryPacer: LibraryPacer {
    private var remaining: Int
    init(_ limit: Int) { remaining = limit }
    func admit(_ collection: LibraryCollection) async -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
    func retryDelay(attempt: Int) async {}
}

enum LibraryFixtures {
    static func track(_ id: String, likedAt: Int64? = nil) -> LibraryRecord {
        LibraryRecord(
            kind: .track, id: id,
            payload: Data("{\"id\":\(id)}".utf8),
            title: "Track \(id)", artist: "Artist",
            timestampMillis: likedAt, changeKey: nil
        )
    }

    static func likes(_ ids: [String], newest: Int64 = 1_000_000) -> [LibraryRecord] {
        ids.enumerated().map { track($0.element, likedAt: newest - Int64($0.offset) * 1_000) }
    }

    static func user(_ id: String) -> LibraryRecord {
        LibraryRecord(kind: .user, id: id, payload: Data("{\"id\":\"\(id)\"}".utf8), title: "User \(id)", artist: id, timestampMillis: nil, changeKey: nil)
    }

    static func users(_ ids: [String]) -> [LibraryRecord] { ids.map(user) }

    static func playlist(_ id: String, changeKey: String) -> LibraryRecord {
        LibraryRecord(kind: .playlist, id: id, payload: Data("{\"id\":\"\(id)\"}".utf8), title: "Playlist \(id)", artist: "Me", timestampMillis: nil, changeKey: changeKey)
    }

    static func keys(_ records: [LibraryRecord]) -> [String] { records.map(\.key) }

    static let recordedLikesPage = #"""
    {"collection":[{"created_at":"2026-11-08T21:14:03Z","kind":"like","track":{"artwork_url":null,"created_at":"2024-05-01T10:00:00Z","duration":3912000,"full_duration":3912000,"id":1801234567,"kind":"track","permalink":"live-at-the-lot","permalink_url":"https://soundcloud.com/someone/live-at-the-lot","public":true,"streamable":true,"title":"Live at the Lot","track_format":"single-track","user":{"avatar_url":null,"id":123456,"kind":"user","permalink":"someone","permalink_url":"https://soundcloud.com/someone","username":"Someone","verified":false}}},{"created_at":"2026-11-07T08:00:00Z","kind":"like","track":{"artwork_url":null,"created_at":"2023-01-01T00:00:00Z","duration":240000,"full_duration":240000,"id":99,"kind":"track","permalink":"short","permalink_url":"https://soundcloud.com/other/short","public":true,"streamable":true,"title":"Short","track_format":"single-track","user":{"avatar_url":null,"id":7,"kind":"user","permalink":"other","permalink_url":"https://soundcloud.com/other","username":"Other","verified":false}}}],"next_href":"https://api-v2.soundcloud.com/users/1/track_likes?offset=2026-11-07T08%3A00%3A00.000Z%2C1234&limit=2&linked_partitioning=1","query_urn":null}
    """#

    static let recordedPlaylist = #"""
    {"artwork_url":null,"created_at":"2025-03-20T15:39:38Z","duration":10661326,"id":1988906940,"kind":"playlist","last_modified":"2026-07-31T12:55:31Z","permalink":"warm-up","permalink_url":"https://soundcloud.com/someone/sets/warm-up","public":true,"set_type":"","is_album":false,"title":"Warm Up","track_count":3,"user_id":123456,"user":{"avatar_url":null,"id":123456,"kind":"user","permalink":"someone","permalink_url":"https://soundcloud.com/someone","username":"Someone","verified":false},"tracks":[{"id":1},{"id":2},{"id":3}]}
    """#
}

final class LibrarySyncCoreTests: XCTestCase {
    private var directory: URL!
    private var clock: LibraryTestClock!
    private var store: LibrarySQLiteStore!
    private var remote: ScriptedLibraryRemote!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySyncCoreTests-\(UUID().uuidString)")
        clock = LibraryTestClock()
        let clock = clock!
        store = LibrarySQLiteStore(directory: directory, clock: { clock.now })
        remote = ScriptedLibraryRemote()
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCore(
        store: LibrarySQLiteStore? = nil,
        remote: ScriptedLibraryRemote? = nil,
        pacer: any LibraryPacer = AllowAllLibraryPacer(),
        policy: LibrarySyncPolicy = .standard
    ) -> LibrarySyncCore {
        let clock = clock!
        return LibrarySyncCore(store: store ?? self.store, remote: remote ?? self.remote, pacer: pacer, policy: policy, now: { clock.now })
    }

    private func makeStore() -> LibrarySQLiteStore {
        let clock = clock!
        return LibrarySQLiteStore(directory: directory.appendingPathComponent(UUID().uuidString), clock: { clock.now })
    }

    // MARK: - Backfill

    func testBackfillWalksEveryCollectionInOrder() async {
        let likes = LibraryFixtures.likes(["1", "2", "3", "4", "5", "6", "7"])
        await remote.set(.likes, likes)
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c", "d"]))
        let core = makeCore()

        let outcome = await core.run(account: "me")

        XCTAssertEqual(outcome, .finished)
        let likeKeys = await store.keys(.likes, limit: nil)
        XCTAssertEqual(likeKeys, LibraryFixtures.keys(likes))
        let followingKeys = await store.keys(.followings, limit: nil)
        XCTAssertEqual(followingKeys, ["user:a", "user:b", "user:c", "user:d"])
        for collection in LibraryCollection.backfillOrder {
            let cursor = await store.cursor(collection)
            XCTAssertTrue(cursor.hasCompletedOnce, collection.key)
            XCTAssertEqual(cursor.phase, .complete, collection.key)
        }
        let requests = await remote.pageRequests
        XCTAssertEqual(requests.prefix(3), ["likes@0", "likes@3", "likes@6"])
        XCTAssertEqual(requests.first(where: { !$0.hasPrefix("likes") }), "ownPlaylists@0")
    }

    func testBackfillResumesFromSavedCursorAfterParking() async {
        let stop = Date(timeIntervalSince1970: 1_800_000_600)
        await remote.set(.likes, LibraryFixtures.likes(["1", "2", "3", "4", "5", "6", "7"]))
        await remote.failAt(1, .stop(until: stop))
        let core = makeCore()

        let first = await core.run(account: "me")

        XCTAssertEqual(first, .parked(until: stop))
        let parked = await store.cursor(.likes)
        XCTAssertEqual(parked.phase, .walking)
        XCTAssertNotNil(parked.nextHref)
        let partial = await store.count(.likes)
        XCTAssertEqual(partial, 3)

        await remote.resetLog()
        let second = await core.run(account: "me")

        XCTAssertEqual(second, .finished)
        let resumed = await remote.pageRequests
        XCTAssertEqual(resumed.first, "likes@3")
        XCTAssertFalse(resumed.contains("likes@0"))
        let total = await store.count(.likes)
        XCTAssertEqual(total, 7)
    }

    func testFullWalkPrunesItemsGoneFromSoundCloud() async throws {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c", "d"]))
        let core = makeCore()
        _ = await core.run(account: "me")

        await remote.set(.followings, LibraryFixtures.users(["a", "c", "d"]))
        try await core.startWalk(.followings)
        try await core.walk(.followings)

        let keys = await store.keys(.followings, limit: nil)
        XCTAssertEqual(keys, ["user:a", "user:c", "user:d"])
    }

    // MARK: - Patch

    func testHeadPatchAddsMovesAndDeletes() async throws {
        let original = (1...30).map { "u\($0)" }
        await remote.setPageSize(10)
        await remote.set(.followings, LibraryFixtures.users(original))
        var policy = LibrarySyncPolicy.standard
        policy.knownRunToStop = 5
        let core = makeCore(policy: policy)
        _ = await core.run(account: "me")

        var updated = original.filter { $0 != "u3" && $0 != "u5" }
        updated.insert(contentsOf: ["n1", "n2", "u5"], at: 0)
        await remote.set(.followings, LibraryFixtures.users(updated))
        await remote.resetLog()

        try await core.patchHead(.followings)

        let keys = await store.keys(.followings, limit: nil)
        XCTAssertEqual(keys, updated.map { "user:\($0)" })
        let requests = await remote.pageRequests
        XCTAssertEqual(requests, ["followings@0"])
    }

    func testNewFollowsAreDatedWhenFirstSeenAndBackfilledOnesAreNot() async throws {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c"]))
        let core = makeCore()
        _ = await core.run(account: "me")

        let backfilled = await store.page(.followings, offset: 0, limit: 10)
        XCTAssertEqual(backfilled.count, 3)
        XCTAssertTrue(backfilled.allSatisfy { $0.record.timestampMillis == nil })

        await remote.set(.followings, LibraryFixtures.users(["n", "a", "b", "c"]))
        try await core.patchHead(.followings)

        let rows = await store.page(.followings, offset: 0, limit: 10)
        XCTAssertEqual(rows.map(\.record.id), ["n", "a", "b", "c"])
        XCTAssertNotNil(rows.first?.record.timestampMillis)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.record.timestampMillis == nil })
    }

    func testLikesHeadPatchUsesLikedAtAndDetectsUnlikes() async throws {
        let ids = (1...12).map(String.init)
        await remote.set(.likes, LibraryFixtures.likes(ids))
        var policy = LibrarySyncPolicy.standard
        policy.knownRunToStop = 4
        let core = makeCore(policy: policy)
        _ = await core.run(account: "me")

        let fresh = LibraryFixtures.likes(["new"], newest: 2_000_000)
        let kept = LibraryFixtures.likes(ids).filter { $0.id != "2" }
        await remote.set(.likes, fresh + kept)

        try await core.patchHead(.likes)

        let keys = await store.keys(.likes, limit: nil)
        XCTAssertEqual(keys, LibraryFixtures.keys(fresh + kept))
    }

    func testHeadPatchOverflowKeepsNewItemsAndSchedulesFullWalk() async {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c"]))
        var policy = LibrarySyncPolicy.standard
        policy.headPageCap = 2
        let core = makeCore(policy: policy)
        _ = await core.run(account: "me")

        let fresh = (1...10).map { "n\($0)" }
        await remote.set(.followings, LibraryFixtures.users(fresh + ["a", "b", "c"]))

        try? await core.patchHead(.followings)

        let afterPatch = await store.keys(.followings, limit: nil)
        XCTAssertEqual(Array(afterPatch.prefix(6)), (1...6).map { "user:n\($0)" })
        let flagged = await store.cursor(.followings)
        XCTAssertTrue(flagged.verifyRequested)

        _ = await core.run(account: "me")

        let afterWalk = await store.keys(.followings, limit: nil)
        XCTAssertEqual(afterWalk, (fresh + ["a", "b", "c"]).map { "user:\($0)" })
        let done = await store.cursor(.followings)
        XCTAssertFalse(done.verifyRequested)
    }

    func testCountMismatchSchedulesAtMostOneWalkPerWeek() async {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c", "d"]))
        let core = makeCore()
        _ = await core.run(account: "me")

        await remote.setCount(.followings, 99)
        clock.advance(16 * 60)
        _ = await core.run(account: "me")
        let flagged = await store.cursor(.followings)
        XCTAssertTrue(flagged.verifyRequested)
        XCTAssertNotNil(flagged.mismatchWalkAt)

        _ = await core.run(account: "me")
        let walked = await store.cursor(.followings)
        XCTAssertFalse(walked.verifyRequested)

        clock.advance(16 * 60)
        _ = await core.run(account: "me")
        let quiet = await store.cursor(.followings)
        XCTAssertFalse(quiet.verifyRequested)

        clock.advance(8 * 24 * 60 * 60)
        await core.requestPatch(.followings)
        _ = await core.run(account: "me")
        await core.requestPatch(.followings)
        _ = await core.run(account: "me")
        let weekLater = await store.cursor(.followings)
        XCTAssertNotNil(weekLater.mismatchWalkAt)
        XCTAssertGreaterThan(weekLater.mismatchWalkAt ?? .distantPast, flagged.mismatchWalkAt ?? .distantFuture)
    }

    // MARK: - Playlists

    func testPlaylistTracksFetchOnlyMissingTracksAndRefetchOnChangeKey() async {
        await remote.set(.likes, LibraryFixtures.likes(["t1"]))
        await remote.set(.ownPlaylists, [
            LibraryFixtures.playlist("p1", changeKey: "100|2"),
            LibraryFixtures.playlist("p2", changeKey: "100|1"),
        ])
        await remote.setManifest("p1", LibraryPlaylistManifest(trackIDs: ["t1", "t2"], hydrated: [], changeKey: "100|2"))
        await remote.setManifest("p2", LibraryPlaylistManifest(trackIDs: ["t3"], hydrated: [], changeKey: "100|1"))
        await remote.setPool(["t2", "t3", "t4"].map { LibraryFixtures.track($0) })
        let core = makeCore()

        _ = await core.run(account: "me")

        let p1 = await store.keys(.playlist("p1"), limit: nil)
        XCTAssertEqual(p1, ["track:t1", "track:t2"])
        let fetched = await remote.trackRequests
        XCTAssertEqual(Set(fetched), [["t2"], ["t3"]])

        await remote.set(.ownPlaylists, [LibraryFixtures.playlist("p1", changeKey: "200|3")])
        await remote.setManifest("p1", LibraryPlaylistManifest(trackIDs: ["t4", "t2", "t1"], hydrated: [], changeKey: "200|3"))
        await remote.resetLog()
        await core.requestPatch(.ownPlaylists)

        _ = await core.run(account: "me")

        let manifests = await remote.manifestRequests
        XCTAssertEqual(manifests, ["p1"])
        let reordered = await store.keys(.playlist("p1"), limit: nil)
        XCTAssertEqual(reordered, ["track:t4", "track:t2", "track:t1"])
        let dropped = await store.count(.playlist("p2"))
        XCTAssertEqual(dropped, 0)
        let refetched = await remote.trackRequests
        XCTAssertEqual(refetched, [["t4"]])
    }

    func testUnavailablePlaylistIsDroppedAndNotRetried() async {
        await remote.set(.likedPlaylists, [LibraryFixtures.playlist("gone", changeKey: "1|4")])
        await remote.setGone("gone")
        let core = makeCore()

        _ = await core.run(account: "me")
        await remote.resetLog()
        _ = await core.run(account: "me")

        let cursor = await store.cursor(.playlist("gone"))
        XCTAssertTrue(cursor.hasCompletedOnce)
        let requests = await remote.manifestRequests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Budgets

    func testBudgetExhaustionStopsWithCursorSaved() async {
        await remote.set(.likes, LibraryFixtures.likes((1...9).map(String.init)))
        let core = makeCore(pacer: LimitedLibraryPacer(2))

        let outcome = await core.run(account: "me")

        XCTAssertEqual(outcome, .outOfBudget)
        let cursor = await store.cursor(.likes)
        XCTAssertEqual(cursor.phase, .walking)
        XCTAssertNotNil(cursor.nextHref)
        let count = await store.count(.likes)
        XCTAssertEqual(count, 6)
    }

    func testRateLimitParksWithoutRetrying() async {
        let until = Date(timeIntervalSince1970: 1_800_003_600)
        await remote.set(.likes, LibraryFixtures.likes(["1"]))
        await remote.failNext([.stop(until: until)])
        let core = makeCore()

        let outcome = await core.run(account: "me")

        XCTAssertEqual(outcome, .parked(until: until))
        let requests = await remote.pageRequests
        XCTAssertEqual(requests, ["likes@0"])
    }

    func testTransientFailuresRetryTwiceThenSkip() async {
        await remote.set(.likes, LibraryFixtures.likes(["1"]))
        await remote.failNext([.transient, .transient])
        let core = makeCore()
        _ = await core.run(account: "me")
        let recovered = await store.count(.likes)
        XCTAssertEqual(recovered, 1)

        let other = ScriptedLibraryRemote()
        await other.set(.likes, LibraryFixtures.likes(["1"]))
        await other.failNext([.transient, .transient, .transient])
        let failingStore = makeStore()
        let failing = makeCore(store: failingStore, remote: other)
        _ = await failing.run(account: "me")
        let attempts = await other.pageRequests.filter { $0 == "likes@0" }.count
        XCTAssertEqual(attempts, 3)
        let cursor = await failingStore.cursor(.likes)
        XCTAssertTrue(cursor.isBackfilling)
    }

    // MARK: - Local actions

    func testOptimisticLikeAndUnlikeRevert() async {
        let likes = LibraryFixtures.likes(["1", "2", "3"])
        await remote.set(.likes, likes)
        let core = makeCore()
        _ = await core.run(account: "me")

        let liked = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        let afterLike = await store.keys(.likes, limit: nil)
        XCTAssertEqual(afterLike.first, "track:9")
        await core.revert(liked)
        let reverted = await store.keys(.likes, limit: nil)
        XCTAssertEqual(reverted, LibraryFixtures.keys(likes))

        let unliked = await core.apply(.unlike(trackID: "2"))
        let afterUnlike = await store.keys(.likes, limit: nil)
        XCTAssertEqual(afterUnlike, ["track:1", "track:3"])
        await core.revert(unliked)
        let restored = await store.keys(.likes, limit: nil)
        XCTAssertEqual(restored, LibraryFixtures.keys(likes))

        let followed = await core.apply(.follow(LibraryFixtures.user("x")))
        let following = await store.keys(.followings, limit: nil)
        XCTAssertEqual(following, ["user:x"])
        await core.revert(followed)
        let empty = await store.count(.followings)
        XCTAssertEqual(empty, 0)
    }

    // MARK: - Account scope

    func testSwitchingAccountWipesEverything() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2"]))
        let core = makeCore()
        _ = await core.run(account: "alice")
        let before = await store.count(.likes)
        XCTAssertEqual(before, 2)

        await remote.set(.likes, LibraryFixtures.likes(["7"]))
        _ = await core.run(account: "bob")

        let bound = await store.boundAccount()
        XCTAssertEqual(bound, "bob")
        let keys = await store.keys(.likes, limit: nil)
        XCTAssertEqual(keys, ["track:7"])
    }

    // MARK: - Chunks

    func testChunksRoundTripAndApplyIdempotently() async {
        await remote.set(.likes, LibraryFixtures.likes((1...25).map(String.init)))
        await remote.set(.followings, LibraryFixtures.users(["a", "b"]))
        let source = makeCore()
        _ = await source.run(account: "me")
        let chunks = await source.allChunks(account: "me", writerId: "phone")
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            let data = chunk.encoded()
            XCTAssertNotNil(data)
            XCTAssertEqual(data.flatMap(LibraryChunk.decode), chunk)
        }

        let targetStore = makeStore()
        _ = await targetStore.bind(account: "me")
        let target = makeCore(store: targetStore, remote: ScriptedLibraryRemote())
        let applied = await target.adopt(chunks, expectedAccount: "me")
        XCTAssertEqual(applied, chunks.count)
        let likes = await targetStore.keys(.likes, limit: nil)
        let sourceLikes = await store.keys(.likes, limit: nil)
        XCTAssertEqual(likes, sourceLikes)
        let followings = await targetStore.keys(.followings, limit: nil)
        XCTAssertEqual(followings, ["user:a", "user:b"])

        let again = await target.adopt(chunks, expectedAccount: "me")
        XCTAssertEqual(again, 0)
        let unchanged = await targetStore.keys(.likes, limit: nil)
        XCTAssertEqual(unchanged, sourceLikes)
    }

    func testNewerChunkCarriesDeletions() async {
        await remote.set(.followings, LibraryFixtures.users(["a", "b", "c"]))
        let source = makeCore()
        _ = await source.run(account: "me")
        let targetStore = makeStore()
        _ = await targetStore.bind(account: "me")
        let target = makeCore(store: targetStore, remote: ScriptedLibraryRemote())
        _ = await target.adopt(await source.allChunks(account: "me", writerId: "phone"), expectedAccount: "me")

        clock.advance(5)
        _ = await source.apply(.unfollow(userID: "b"))
        let changed = await source.chunks(account: "me", writerId: "phone", cloud: false, since: 0, limit: nil)
        _ = await target.adopt(changed, expectedAccount: "me")

        let keys = await targetStore.keys(.followings, limit: nil)
        XCTAssertEqual(keys, ["user:a", "user:c"])
    }

    func testAdoptedManifestSkipsBackfill() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2", "3", "4"]))
        await remote.set(.ownPlaylists, [LibraryFixtures.playlist("p1", changeKey: "5|1")])
        await remote.setManifest("p1", LibraryPlaylistManifest(trackIDs: ["1"], hydrated: [], changeKey: "5|1"))
        await remote.set(.followings, LibraryFixtures.users(["a"]))
        let source = makeCore()
        _ = await source.run(account: "me")
        let manifest = await source.manifestChunk(account: "me", writerId: "phone")
        let rows = await source.allChunks(account: "me", writerId: "phone")

        let targetStore = makeStore()
        _ = await targetStore.bind(account: "me")
        let targetRemote = ScriptedLibraryRemote()
        await targetRemote.set(.likes, LibraryFixtures.likes(["1", "2", "3", "4"]))
        await targetRemote.set(.ownPlaylists, [LibraryFixtures.playlist("p1", changeKey: "5|1")])
        await targetRemote.set(.followings, LibraryFixtures.users(["a"]))
        let target = makeCore(store: targetStore, remote: targetRemote)
        _ = await target.adopt([manifest] + rows, expectedAccount: "me")

        for collection in LibraryCollection.backfillOrder {
            let cursor = await targetStore.cursor(collection)
            XCTAssertTrue(cursor.hasCompletedOnce, collection.key)
        }
        _ = await target.run(account: "me")

        let pages = await targetRemote.pageRequests
        XCTAssertTrue(pages.isEmpty, pages.joined(separator: ","))
        let manifests = await targetRemote.manifestRequests
        XCTAssertTrue(manifests.isEmpty)
        let playlist = await targetStore.keys(.playlist("p1"), limit: nil)
        XCTAssertEqual(playlist, ["track:1"])
    }

    func testStaleManifestDoesNotSkipBackfill() async {
        await remote.set(.followings, LibraryFixtures.users(["a"]))
        let source = makeCore()
        _ = await source.run(account: "me")
        let manifest = await source.manifestChunk(account: "me", writerId: "phone")
        let rows = await source.allChunks(account: "me", writerId: "phone")

        clock.advance(8 * 24 * 60 * 60)
        let targetStore = makeStore()
        _ = await targetStore.bind(account: "me")
        let target = makeCore(store: targetStore, remote: ScriptedLibraryRemote())
        _ = await target.adopt([manifest] + rows, expectedAccount: "me")

        let cursor = await targetStore.cursor(.followings)
        XCTAssertFalse(cursor.hasCompletedOnce)
    }

    func testChunksFromAnotherAccountAreRefused() async {
        await remote.set(.likes, LibraryFixtures.likes(["1"]))
        let source = makeCore()
        _ = await source.run(account: "alice")
        let chunks = await source.allChunks(account: "alice", writerId: "phone")
        let manifest = await source.manifestChunk(account: "alice", writerId: "phone")

        let targetStore = makeStore()
        _ = await targetStore.bind(account: "bob")
        let target = makeCore(store: targetStore, remote: ScriptedLibraryRemote())

        let asBob = await target.adopt([manifest] + chunks, expectedAccount: "bob")
        XCTAssertEqual(asBob, 0)
        let asAlice = await target.adopt([manifest] + chunks, expectedAccount: "alice")
        XCTAssertEqual(asAlice, 0)
        let count = await targetStore.count(.likes)
        XCTAssertEqual(count, 0)
        let none = await source.allChunks(account: "bob", writerId: "phone")
        XCTAssertTrue(none.isEmpty)
    }

    func testCloudExportMarksBucketsClean() async {
        await remote.set(.followings, LibraryFixtures.users(["a", "b"]))
        let core = makeCore()
        _ = await core.run(account: "me")

        let dirty = await core.chunks(account: "me", writerId: "phone", cloud: true, since: 0, limit: 40)
        XCTAssertFalse(dirty.isEmpty)
        await core.markCloudExported(dirty)
        let clean = await core.chunks(account: "me", writerId: "phone", cloud: true, since: 0, limit: 40)
        XCTAssertTrue(clean.isEmpty)

        clock.advance(5)
        _ = await core.apply(.unfollow(userID: "a"))
        let changed = await core.chunks(account: "me", writerId: "phone", cloud: true, since: 0, limit: 40)
        XCTAssertEqual(changed.map(\.collection), ["followings"])
    }

    func testPeerBodyBatchesUnderLimitAndFiltersAccount() {
        let chunks = (0..<6).map { index in
            LibraryChunk(
                account: index == 5 ? "someone-else" : "me",
                collection: "followings", bucket: 0, bucketCount: 1,
                updatedAtMillis: Int64(index), writerId: "phone",
                rows: (0..<40).map { row in LibraryRow(record: LibraryFixtures.user("u\(index)-\(row)"), sortKey: Int64(row)) },
                manifest: nil
            )
        }
        let single = chunks[0].encoded()?.count ?? 0
        XCTAssertGreaterThan(single, 0)
        let batches = LibraryPeerBody.batches(chunks, maximumBytes: single * 2 + 1)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { batch in batch.reduce(0) { total, data in total + data.count } <= single * 2 + 1 })
        XCTAssertEqual(batches.flatMap { $0 }.count, chunks.count)

        let body = LibraryPeerBody(accountId: "me", chunks: batches.flatMap { $0 }, isComplete: true)
        let decoded = body.encoded().flatMap(LibraryPeerBody.decode)
        XCTAssertEqual(decoded, body)
        XCTAssertEqual(decoded?.decodedChunks().count, 5)
        XCTAssertNil(LibraryPeerBody.decode(Data(#"{"accountId":"me","snapshotId":"x","records":[],"isComplete":true}"#.utf8)))
    }

    // MARK: - Recorded shapes

    func testRecordedLikesPageMapsToRecords() throws {
        let page = try LikesSyncEngine.makeDecoder().decode(Page<Like<Track>>.self, from: Data(LibraryFixtures.recordedLikesPage.utf8))
        let records = page.collection.compactMap { LibraryRecords.track($0.item, at: $0.createdAt) }
        XCTAssertEqual(records.map(\.key), ["track:1801234567", "track:99"])
        XCTAssertEqual(records.first?.timestampMillis, 1_794_172_443_000)
        XCTAssertNotNil(page.nextHref)
        XCTAssertEqual(records.first?.title, "Live at the Lot")
    }

    func testRecordedPlaylistChangeKeyUsesLastModifiedAndTrackCount() throws {
        let playlist = try LikesSyncEngine.makeDecoder().decode(Playlist.self, from: Data(LibraryFixtures.recordedPlaylist.utf8))
        XCTAssertEqual(LibraryRecords.changeKey(playlist), "1785502531000|3")
        let record = LibraryRecords.playlist(playlist, at: nil)
        XCTAssertEqual(record?.changeKey, "1785502531000|3")
    }

    func testBucketsAreStableAndSized() {
        XCTAssertEqual(LibraryBuckets.bucket(for: "track:1", count: 8), LibraryBuckets.bucket(for: "track:1", count: 8))
        XCTAssertEqual(LibraryBuckets.count(forRows: 0), 1)
        XCTAssertEqual(LibraryBuckets.count(forRows: 5_400), 64)
        XCTAssertEqual(LibraryBuckets.count(forRows: 1_000_000), LibraryBuckets.maximumBuckets)
        for key in (0..<500).map({ "track:\($0)" }) {
            XCTAssertLessThan(LibraryBuckets.bucket(for: key, count: 16), 16)
        }
    }
}

#endif
