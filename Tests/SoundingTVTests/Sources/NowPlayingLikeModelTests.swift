import XCTest
@testable import SoundingTV

@MainActor
final class NowPlayingLikeModelTests: XCTestCase {
    @MainActor
    private final class FakeLikeService: NowPlayingLikeService {
        var sent: [Bool] = []
        var failures: Set<Int> = []
        var indexed = false
        var delay: Duration = .zero

        func setLiked(_ liked: Bool, trackId: String, resolved: Track?) async throws {
            let attempt = sent.count
            sent.append(liked)
            if delay > .zero { try? await Task.sleep(for: delay) }
            if failures.contains(attempt) { throw APIError.serverError(500) }
        }

        func indexedLike(trackId: String) async -> Bool { indexed }
    }

    private let trackId = "42"

    private func model(_ service: FakeLikeService) -> NowPlayingLikeModel {
        NowPlayingLikeModel(service: service, settleDelay: .milliseconds(20))
    }

    func testLikeUnlikeAndLikeAgainAllReachTheServer() async {
        let service = FakeLikeService()
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))

        XCTAssertEqual(service.sent, [true, false, true])
    }

    func testTapWhileARequestIsInFlightIsNotDropped() async {
        let service = FakeLikeService()
        service.delay = .milliseconds(150)
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(service.sent, [true])
        likes.toggle(trackId: trackId, resolved: nil)
        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        await likes.waitUntilSettled(trackId)

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true, false])
    }

    func testRapidTapsCoalesceIntoOneRequest() async {
        let service = FakeLikeService()
        let likes = model(service)

        for _ in 0..<5 { likes.toggle(trackId: trackId, resolved: nil) }
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        await likes.waitUntilSettled(trackId)

        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true])
    }

    func testAnEvenNumberOfRapidTapsSendsNothing() async {
        let service = FakeLikeService()
        let likes = model(service)

        for _ in 0..<4 { likes.toggle(trackId: trackId, resolved: nil) }
        await likes.waitUntilSettled(trackId)

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [])
    }

    func testAFailureRevertsToTheServerStateAndTheNextTapStillWorks() async {
        let service = FakeLikeService()
        service.failures = [1]
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))
        XCTAssertFalse(likes.isSyncing(trackId))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [true, false, false])
    }

    func testRefreshDoesNotOverrideALocalChange() async {
        let service = FakeLikeService()
        service.indexed = true
        let likes = model(service)

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        likes.refresh(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
    }

    func testRefreshAdoptsTheLibraryIndexBeforeAnyLocalChange() async {
        let service = FakeLikeService()
        service.indexed = true
        let likes = model(service)

        likes.refresh(trackId: trackId, resolved: nil)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(likes.isLiked(trackId, resolved: nil))

        likes.toggle(trackId: trackId, resolved: nil)
        await likes.waitUntilSettled(trackId)
        XCTAssertFalse(likes.isLiked(trackId, resolved: nil))
        XCTAssertEqual(service.sent, [false])
    }
}
