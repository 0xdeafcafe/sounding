import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

actor GatedLibraryRemote: LibraryRemote {
    private let inner: ScriptedLibraryRemote
    private var holdNext = false
    private var didArrive = false
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(_ inner: ScriptedLibraryRemote) {
        self.inner = inner
    }

    func holdNextPage() {
        holdNext = true
        didArrive = false
    }

    func waitUntilHeld() async {
        if didArrive { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func page(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage {
        let result = try await inner.page(collection, from: url)
        if holdNext {
            holdNext = false
            didArrive = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { held = $0 }
        }
        return result
    }

    func playlistManifest(id: String) async throws -> LibraryPlaylistManifest {
        try await inner.playlistManifest(id: id)
    }

    func tracks(ids: [String]) async throws -> [LibraryRecord] {
        try await inner.tracks(ids: ids)
    }

    func expectedCounts() async -> [LibraryCollection: Int] {
        await inner.expectedCounts()
    }
}

final class LikeMutationRaceTests: XCTestCase {
    private var directory: URL!
    private var clock: LibraryTestClock!
    private var store: LibrarySQLiteStore!
    private var remote: ScriptedLibraryRemote!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LikeMutationRaceTests-\(UUID().uuidString)")
        clock = LibraryTestClock()
        let clock = clock!
        store = LibrarySQLiteStore(directory: directory, clock: { clock.now })
        remote = ScriptedLibraryRemote()
        await remote.setPageSize(50)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCore(remote: any LibraryRemote, store: LibrarySQLiteStore? = nil) -> LibrarySyncCore {
        let clock = clock!
        return LibrarySyncCore(store: store ?? self.store, remote: remote, pacer: AllowAllLibraryPacer(), now: { clock.now })
    }

    private func seeded(_ ids: [String]) async -> (LibrarySyncCore, GatedLibraryRemote) {
        await remote.set(.likes, LibraryFixtures.likes(ids))
        let gated = GatedLibraryRemote(remote)
        let core = makeCore(remote: gated)
        _ = await core.run(account: "me")
        return (core, gated)
    }

    private func likeKeys() async -> [String] {
        await store.keys(.likes, limit: nil)
    }

    func testOverlayHoldsPendingAndRecentMutationsOnly() {
        var overlay = LibraryMutationOverlay()
        let start = Date(timeIntervalSince1970: 1_000)
        let like = LibraryPendingMutation(id: UUID(), collection: .likes, key: "track:9", present: true)
        overlay.begin(like, record: LibraryFixtures.track("9"), at: start.addingTimeInterval(5))

        XCTAssertEqual(overlay.wanted(.likes, key: "track:9", fetchedFrom: start, now: start.addingTimeInterval(6)), true)
        XCTAssertEqual(overlay.removable(.likes, ["track:9", "track:1"], fetchedFrom: start, now: start), ["track:1"])

        overlay.settle(like, succeeded: true, at: start.addingTimeInterval(10))
        let later = start.addingTimeInterval(10 + LibraryMutationOverlay.standardGrace + 1)
        XCTAssertEqual(overlay.wanted(.likes, key: "track:9", fetchedFrom: start, now: later), true)
        XCTAssertNil(overlay.wanted(.likes, key: "track:9", fetchedFrom: later, now: later))

        overlay.expire(now: start.addingTimeInterval(10 + LibraryMutationOverlay.standardRetention + 1))
        XCTAssertTrue(overlay.isEmpty)
    }

    func testOverlayFailureForgetsTheMutation() {
        var overlay = LibraryMutationOverlay()
        let date = Date(timeIntervalSince1970: 1_000)
        let unlike = LibraryPendingMutation(id: UUID(), collection: .likes, key: "track:2", present: false)
        overlay.begin(unlike, record: nil, at: date)
        XCTAssertEqual(overlay.admitting(.likes, LibraryFixtures.likes(["1", "2"]), fetchedFrom: date, now: date).map(\.key), ["track:1"])

        overlay.settle(unlike, succeeded: false, at: date)
        XCTAssertNil(overlay.wanted(.likes, key: "track:2", fetchedFrom: .distantPast, now: date))
    }

    func testAStaleSettleDoesNotClearANewerMutation() {
        var overlay = LibraryMutationOverlay()
        let date = Date(timeIntervalSince1970: 1_000)
        let first = LibraryPendingMutation(id: UUID(), collection: .likes, key: "track:9", present: true)
        let second = LibraryPendingMutation(id: UUID(), collection: .likes, key: "track:9", present: false)
        overlay.begin(first, record: LibraryFixtures.track("9"), at: date)
        overlay.begin(second, record: nil, at: date.addingTimeInterval(1))
        overlay.settle(first, succeeded: false, at: date.addingTimeInterval(2))

        XCTAssertEqual(overlay.wanted(.likes, key: "track:9", fetchedFrom: date, now: date.addingTimeInterval(2)), false)
    }

    func testLikeDuringAnInFlightFillSticks() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2", "3"]))
        let gated = GatedLibraryRemote(remote)
        let core = makeCore(remote: gated)

        await gated.holdNextPage()
        let fill = Task { await core.fill(.likes, account: "me") }
        await gated.waitUntilHeld()
        clock.advance(1)
        let undo = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        await gated.release()
        let outcome = await fill.value
        XCTAssertEqual(outcome, .finished)

        let whilePending = await likeKeys()
        XCTAssertEqual(whilePending.first, "track:9")

        await core.settle(undo, succeeded: true)
        clock.advance(5)
        try? await core.patchHead(.likes)
        let afterRefresh = await likeKeys()
        XCTAssertEqual(afterRefresh, ["track:9", "track:1", "track:2", "track:3"])
    }

    func testLikeDuringAHeadRefreshSticks() async throws {
        let (core, gated) = await seeded(["1", "2", "3"])

        await gated.holdNextPage()
        let refresh = Task { try await core.patchHead(.likes) }
        await gated.waitUntilHeld()
        clock.advance(1)
        let undo = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        await gated.release()
        try await refresh.value

        let keys = await likeKeys()
        XCTAssertEqual(keys, ["track:9", "track:1", "track:2", "track:3"])
        await core.settle(undo, succeeded: true)
    }

    func testUnlikeDuringARefreshSticks() async throws {
        let (core, gated) = await seeded(["1", "2", "3", "4"])

        await gated.holdNextPage()
        let refresh = Task { try await core.patchHead(.likes) }
        await gated.waitUntilHeld()
        clock.advance(1)
        let undo = await core.apply(.unlike(trackID: "2"))
        await gated.release()
        try await refresh.value

        let keys = await likeKeys()
        XCTAssertEqual(keys, ["track:1", "track:3", "track:4"])

        await core.settle(undo, succeeded: true)
        clock.advance(5)
        try await core.patchHead(.likes)
        let afterSettle = await likeKeys()
        XCTAssertEqual(afterSettle, ["track:1", "track:3", "track:4"])
    }

    func testUnlikeDuringAFullWalkIsNotReAdded() async throws {
        let (core, gated) = await seeded(["1", "2", "3"])

        try await core.startWalk(.likes)
        await gated.holdNextPage()
        let walk = Task { try await core.walk(.likes) }
        await gated.waitUntilHeld()
        clock.advance(1)
        _ = await core.apply(.unlike(trackID: "3"))
        await gated.release()
        try await walk.value

        let keys = await likeKeys()
        XCTAssertEqual(keys, ["track:1", "track:2"])
    }

    func testARecentLikeSurvivesAWalkThatPrunesOlderGenerations() async throws {
        let (core, _) = await seeded(["1", "2"])

        let undo = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        await core.settle(undo, succeeded: true)
        clock.advance(10)
        try await core.startWalk(.likes)
        try await core.walk(.likes)

        let keys = await likeKeys()
        XCTAssertEqual(keys, ["track:9", "track:1", "track:2"])
    }

    func testFailureRollsBackOnceAndARefreshDoesNotRestoreIt() async throws {
        let (core, _) = await seeded(["1", "2"])

        let like = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        await core.settle(like, succeeded: false)
        await core.revert(like)
        try await core.patchHead(.likes)
        let afterLike = await likeKeys()
        XCTAssertEqual(afterLike, ["track:1", "track:2"])

        let unlike = await core.apply(.unlike(trackID: "1"))
        await core.settle(unlike, succeeded: false)
        await core.revert(unlike)
        try await core.patchHead(.likes)
        let afterUnlike = await likeKeys()
        XCTAssertEqual(afterUnlike, ["track:1", "track:2"])
    }

    func testServerTruthWinsOnceTheGraceHasPassed() async throws {
        let (core, _) = await seeded(["1", "2"])

        let undo = await core.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        await core.settle(undo, succeeded: true)
        clock.advance(LibraryMutationOverlay.standardGrace + 1)
        try await core.patchHead(.likes)

        let keys = await likeKeys()
        XCTAssertEqual(keys, ["track:1", "track:2"])
    }

    func testAnOlderPeerChunkDoesNotDropAPendingLike() async {
        await remote.set(.likes, LibraryFixtures.likes(["1", "2", "3"]))
        let source = makeCore(remote: remote)
        _ = await source.run(account: "me")

        let clock = clock!
        let targetStore = LibrarySQLiteStore(directory: directory.appendingPathComponent(UUID().uuidString), clock: { clock.now })
        _ = await targetStore.bind(account: "me")
        let target = makeCore(remote: ScriptedLibraryRemote(), store: targetStore)
        _ = await target.adopt(await source.allChunks(account: "me", writerId: "phone"), expectedAccount: "me")

        clock.advance(2)
        _ = await target.apply(.like(LibraryFixtures.track("9", likedAt: 5_000_000)))
        clock.advance(2)
        _ = await source.apply(.unlike(trackID: "3"))
        let changed = await source.chunks(account: "me", writerId: "phone", cloud: false, since: 0, limit: nil)
        _ = await target.adopt(changed, expectedAccount: "me")

        let keys = await targetStore.keys(.likes, limit: nil)
        XCTAssertTrue(keys.contains("track:9"))
        XCTAssertFalse(keys.contains("track:3"))
    }
}

@MainActor
final class NowPlayingLikeRetryTests: XCTestCase {
    @MainActor
    private final class ScriptedLikeService: NowPlayingLikeService {
        var sent: [Bool] = []
        var errors: [Int: any Error] = [:]
        var indexed = false
        var delay: Duration = .zero

        func setLiked(_ liked: Bool, trackId: String, resolved: Track?) async throws {
            let attempt = sent.count
            sent.append(liked)
            if delay > .zero { try? await Task.sleep(for: delay) }
            if let error = errors[attempt] { throw error }
        }

        func indexedLike(trackId: String) async -> Bool { indexed }
    }

    private let trackId = "42"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var pauses: [TimeInterval] = []

    private func model(_ service: ScriptedLikeService, stoppedUntil: Date? = nil) -> NowPlayingLikeModel {
        let start = start
        return NowPlayingLikeModel(
            service: service,
            settleDelay: .milliseconds(10),
            now: { start },
            pause: { [weak self] seconds in self?.pauses.append(seconds) },
            stoppedUntil: { stoppedUntil }
        )
    }

    func testRateLimitKeepsTheLikePendingAndRetriesAfterTheBackOff() async {
        let service = ScriptedLikeService()
        service.errors = [0: APIError.temporarilyBlocked(until: start.addingTimeInterval(90), statusCode: 429)]
        let likes = model(service, stoppedUntil: start.addingTimeInterval(90))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)

        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true, true])
        XCTAssertEqual(pauses, [90])
        XCTAssertNil(likes.failure)
    }

    func testRateLimitWithoutAResetUsesTheTrafficStop() async {
        let service = ScriptedLikeService()
        service.errors = [0: APIError.rateLimited(resetAt: nil)]
        let likes = model(service, stoppedUntil: start.addingTimeInterval(120))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)

        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(pauses, [120])
    }

    func testARealFailureRollsBackOnceAndShowsTheError() async {
        let service = ScriptedLikeService()
        service.errors = [0: APIError.serverError(500)]
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        await likes.waitUntilSettled(trackId)

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true])
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(likes.failure?.liked, true)
        XCTAssertEqual(likes.failure?.title, "Couldn’t Add to Likes")
    }

    func testALongStopRollsBackAndLeavesTheNoticeToTheTrafficBar() async {
        let service = ScriptedLikeService()
        let until = start.addingTimeInterval(3_600)
        service.errors = [0: APIError.temporarilyBlocked(until: until, statusCode: 429)]
        let likes = model(service, stoppedUntil: until)

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true])
        XCTAssertNil(likes.failure)
    }

    func testRepeatedRateLimitsGiveUpAfterTheAttemptLimit() async {
        let service = ScriptedLikeService()
        for attempt in 0..<LikeRetryPolicy.maximumAttempts {
            service.errors[attempt] = APIError.rateLimited(resetAt: start.addingTimeInterval(30))
        }
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent.count, LikeRetryPolicy.maximumAttempts)
        XCTAssertNotNil(likes.failure)
    }

    func testARefreshDuringAPendingLikeDoesNotFlipItBack() async {
        let service = ScriptedLikeService()
        service.delay = .milliseconds(80)
        service.indexed = false
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(30))
        likes.refresh(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))

        await likes.waitUntilSettled(trackId)
        likes.refresh(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
    }

    func testRetryPolicyClassifiesErrors() {
        XCTAssertNil(LikeRetryPolicy.resumeDate(after: APIError.serverError(500), now: start, stoppedUntil: nil))
        XCTAssertNil(LikeRetryPolicy.resumeDate(after: APIError.temporarilyBlocked(until: start.addingTimeInterval(60), statusCode: 403), now: start, stoppedUntil: nil))
        XCTAssertEqual(
            LikeRetryPolicy.resumeDate(after: APIError.rateLimited(resetAt: nil), now: start, stoppedUntil: nil),
            start.addingTimeInterval(LikeRetryPolicy.fallbackWait)
        )
        XCTAssertNil(LikeRetryPolicy.resumeDate(
            after: APIError.rateLimited(resetAt: start.addingTimeInterval(LikeRetryPolicy.maximumWait + 1)),
            now: start,
            stoppedUntil: nil
        ))
        XCTAssertEqual(
            LikeRetryPolicy.resumeDate(after: SoundCloudGatewayError.backgroundPaused(until: start.addingTimeInterval(45)), now: start, stoppedUntil: nil),
            start.addingTimeInterval(45)
        )
    }
}

#endif
