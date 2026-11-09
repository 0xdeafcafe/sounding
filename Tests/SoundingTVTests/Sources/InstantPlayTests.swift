import XCTest
@testable import SoundingTV

final class CollectionStartPlannerTests: XCTestCase {
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map { "t\($0)" } }

    func testStartsImmediatelyFromLoadedTracksAndHydratesTheRestAfterwards() {
        let ordered = ids(1...500)
        let loaded = ids(1...5)
        let plan = CollectionStartPlanner.plan(orderedIDs: ordered, loadedIDs: loaded, playableIDs: Set(loaded))

        XCTAssertEqual(plan.start, .now(trackID: "t1"))
        XCTAssertFalse(plan.waitsOnNetwork)
        XCTAssertEqual(plan.initialQueueIDs, loaded)
        XCTAssertEqual(plan.hydrateAfterStartIDs, ids(6...500))
    }

    func testFirstTrackNeverWaitsOnTheFullList() {
        let ordered = ids(1...2_000)
        let plan = CollectionStartPlanner.plan(orderedIDs: ordered, loadedIDs: [], playableIDs: [])

        guard case .afterFirstPage(let page) = plan.start else {
            return XCTFail("expected a first page, got \(plan.start)")
        }
        XCTAssertLessThanOrEqual(page.count, CollectionStartPlanner.firstPageSize)
        XCTAssertEqual(page, ids(1...CollectionStartPlanner.firstPageSize))
        XCTAssertEqual(plan.hydrateAfterStartIDs.count, ordered.count - page.count)
    }

    func testSkipsUnplayableLoadedTracksForTheStart() {
        let loaded = ids(1...4)
        let plan = CollectionStartPlanner.plan(
            orderedIDs: loaded,
            loadedIDs: loaded,
            playableIDs: ["t3", "t4"]
        )
        XCTAssertEqual(plan.start, .now(trackID: "t3"))
        XCTAssertEqual(plan.initialQueueIDs, ["t3", "t4"])
        XCTAssertTrue(plan.hydrateAfterStartIDs.isEmpty)
    }

    func testShuffleStartMustBeLoadedAndPlayable() {
        let loaded = ids(1...3)
        let honoured = CollectionStartPlanner.plan(
            orderedIDs: [], loadedIDs: loaded, playableIDs: Set(loaded), preferredStartID: "t2"
        )
        XCTAssertEqual(honoured.start, .now(trackID: "t2"))

        let ignored = CollectionStartPlanner.plan(
            orderedIDs: [], loadedIDs: loaded, playableIDs: Set(loaded), preferredStartID: "t99"
        )
        XCTAssertEqual(ignored.start, .now(trackID: "t1"))
    }

    func testUnknownCollectionNeedsOneLookup() {
        let plan = CollectionStartPlanner.plan(orderedIDs: [], loadedIDs: [], playableIDs: [])
        XCTAssertEqual(plan.start, .afterCollectionLookup)
        XCTAssertTrue(plan.waitsOnNetwork)
    }

    func testNothingPlayableAndNothingLeftToFetch() {
        let loaded = ids(1...2)
        let plan = CollectionStartPlanner.plan(orderedIDs: loaded, loadedIDs: loaded, playableIDs: [])
        XCTAssertEqual(plan.start, .nothing)
    }

    func testDuplicateIDsAreIgnored() {
        let plan = CollectionStartPlanner.plan(
            orderedIDs: ["a", "b", "b", "c"],
            loadedIDs: ["a", "a"],
            playableIDs: ["a"]
        )
        XCTAssertEqual(plan.initialQueueIDs, ["a"])
        XCTAssertEqual(plan.hydrateAfterStartIDs, ["b", "c"])
    }

    func testHydrationBatchesAreBoundedAndOrdered() {
        let batches = CollectionStartPlanner.batches(ids(1...120), size: 50)
        XCTAssertEqual(batches.map(\.count), [50, 50, 20])
        XCTAssertEqual(batches.flatMap { $0 }, ids(1...120))
        XCTAssertTrue(CollectionStartPlanner.batches([], size: 50).isEmpty)
    }

    func testAppendingKeepsExistingOrderAndDropsDuplicates() {
        XCTAssertEqual(
            CollectionStartPlanner.appended(["a", "b"], with: ["b", "c", "c", "d"]),
            ["a", "b", "c", "d"]
        )
    }
}

final class ResolvedStreamURLCacheTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func url(_ name: String) -> URL { URL(string: "https://cf-hls-media.sndcdn.com/\(name).m3u8")! }

    func testUnsignedURLsLiveThirtySeconds() {
        var cache = ResolvedStreamURLCache()
        cache.store(url("a"), signedExpiry: nil, for: "a", now: start)
        XCTAssertEqual(cache.url(for: "a", now: start.addingTimeInterval(29)), url("a"))
        XCTAssertNil(cache.url(for: "a", now: start.addingTimeInterval(31)))
        XCTAssertNil(cache.entries["a"])
    }

    func testSignedURLsExpireBeforeTheirSignature() {
        var cache = ResolvedStreamURLCache()
        let signed = start.addingTimeInterval(10 * 60)
        cache.store(url("a"), signedExpiry: signed, for: "a", now: start)
        let margin = ResolvedStreamURLCache.signedExpiryMargin
        XCTAssertNotNil(cache.url(for: "a", now: signed.addingTimeInterval(-margin - 1)))
        XCTAssertNil(cache.url(for: "a", now: signed.addingTimeInterval(-margin + 1)))
    }

    func testSignedLifetimeIsCapped() {
        let farFuture = start.addingTimeInterval(24 * 60 * 60)
        let expiry = ResolvedStreamURLCache.usableExpiry(signedExpiry: farFuture, fetchedAt: start)
        XCTAssertEqual(expiry, start.addingTimeInterval(ResolvedStreamURLCache.maximumSignedLifetime))
    }

    func testSignatureCloserThanTheMarginFallsBackToUnsignedLifetime() {
        let soon = start.addingTimeInterval(60)
        XCTAssertNil(ResolvedStreamURLCache.usableExpiry(signedExpiry: soon, fetchedAt: start))
        var cache = ResolvedStreamURLCache()
        cache.store(url("a"), signedExpiry: soon, for: "a", now: start)
        XCTAssertNotNil(cache.url(for: "a", now: start.addingTimeInterval(20)))
        XCTAssertNil(cache.url(for: "a", now: start.addingTimeInterval(40)))
    }

    func testEvictsTheLeastRecentlyUsedEntry() {
        var cache = ResolvedStreamURLCache(capacity: 2)
        let signed = start.addingTimeInterval(15 * 60)
        cache.store(url("a"), signedExpiry: signed, for: "a", now: start)
        cache.store(url("b"), signedExpiry: signed, for: "b", now: start.addingTimeInterval(1))
        XCTAssertNotNil(cache.url(for: "a", now: start.addingTimeInterval(2)))
        cache.store(url("c"), signedExpiry: signed, for: "c", now: start.addingTimeInterval(3))

        XCTAssertNotNil(cache.peek("a", now: start.addingTimeInterval(4)))
        XCTAssertNil(cache.peek("b", now: start.addingTimeInterval(4)))
        XCTAssertNotNil(cache.peek("c", now: start.addingTimeInterval(4)))
    }

    func testRoundTripsThroughCodable() throws {
        var cache = ResolvedStreamURLCache()
        cache.store(url("a"), signedExpiry: start.addingTimeInterval(600), for: "a", now: start)
        let decoded = try JSONDecoder().decode(ResolvedStreamURLCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(decoded, cache)
    }
}

final class PlayedAudioCacheLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 60 * 60
    private let limits = PlayedAudioCacheLedger.Limits(
        minimumRetention: 3 * 60 * 60,
        maximumAge: 72 * 60 * 60,
        softCapBytes: 100,
        hardCapBytes: 150,
        maximumItemBytes: 80
    )

    private func entry(_ id: String, bytes: Int64, playedAt: Date) -> PlayedAudioCacheLedger.Entry {
        .init(trackID: id, fileName: "\(id).sctv", fileExtension: "m4a", bytes: bytes, cachedAt: playedAt, lastPlayedAt: playedAt)
    }

    func testKeepsRecentPlaysForAtLeastThreeHoursEvenOverTheSoftCap() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("a", bytes: 60, playedAt: start), now: start, limits: limits)
        let evicted = ledger.insert(entry("b", bytes: 60, playedAt: start.addingTimeInterval(hour)), now: start.addingTimeInterval(hour), limits: limits)
        XCTAssertTrue(evicted.isEmpty)
        XCTAssertNotNil(ledger.entry(for: "a", now: start.addingTimeInterval(hour), limits: limits))
        XCTAssertEqual(ledger.totalBytes, 120)
    }

    func testEvictsTheOldestOutsideTheRetentionWindowFirst() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("old", bytes: 50, playedAt: start), now: start, limits: limits)
        ledger.insert(entry("mid", bytes: 40, playedAt: start.addingTimeInterval(hour)), now: start.addingTimeInterval(hour), limits: limits)
        let now = start.addingTimeInterval(5 * hour)
        let evicted = ledger.insert(entry("new", bytes: 40, playedAt: now), now: now, limits: limits)
        XCTAssertEqual(evicted.map(\.trackID), ["old"])
        XCTAssertNotNil(ledger.entry(for: "mid", now: now, limits: limits))
        XCTAssertNotNil(ledger.entry(for: "new", now: now, limits: limits))
    }

    func testTouchingATrackKeepsItFromEviction() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("a", bytes: 50, playedAt: start), now: start, limits: limits)
        ledger.insert(entry("b", bytes: 40, playedAt: start.addingTimeInterval(hour)), now: start.addingTimeInterval(hour), limits: limits)
        ledger.touch("a", now: start.addingTimeInterval(4 * hour))
        let now = start.addingTimeInterval(5 * hour)
        let evicted = ledger.insert(entry("c", bytes: 40, playedAt: now), now: now, limits: limits)
        XCTAssertEqual(evicted.map(\.trackID), ["b"])
    }

    func testHardCapWinsOverTheRetentionWindow() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("a", bytes: 70, playedAt: start), now: start, limits: limits)
        ledger.insert(entry("b", bytes: 70, playedAt: start.addingTimeInterval(60)), now: start.addingTimeInterval(60), limits: limits)
        let evicted = ledger.insert(entry("c", bytes: 70, playedAt: start.addingTimeInterval(120)), now: start.addingTimeInterval(120), limits: limits)
        XCTAssertEqual(evicted.map(\.trackID), ["a"])
        XCTAssertLessThanOrEqual(ledger.totalBytes, limits.hardCapBytes)
        XCTAssertNotNil(ledger.entry(for: "c", now: start.addingTimeInterval(120), limits: limits))
    }

    func testEntriesExpireAfterTheMaximumAge() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("a", bytes: 10, playedAt: start), now: start, limits: limits)
        let later = start.addingTimeInterval(limits.maximumAge + 1)
        XCTAssertNil(ledger.entry(for: "a", now: later, limits: limits))
        let evicted = ledger.evict(now: later, limits: limits)
        XCTAssertEqual(evicted.map(\.trackID), ["a"])
        XCTAssertEqual(ledger.totalBytes, 0)
    }

    func testRejectsItemsLargerThanTheItemLimit() {
        let ledger = PlayedAudioCacheLedger()
        XCTAssertTrue(ledger.accepts(bytes: 80, limits: limits))
        XCTAssertFalse(ledger.accepts(bytes: 81, limits: limits))
        XCTAssertFalse(ledger.accepts(bytes: 0, limits: limits))
    }

    func testReplacingATrackReturnsTheOldFile() {
        var ledger = PlayedAudioCacheLedger()
        ledger.insert(entry("a", bytes: 10, playedAt: start), now: start, limits: limits)
        var replacement = entry("a", bytes: 12, playedAt: start.addingTimeInterval(10))
        replacement = .init(
            trackID: "a", fileName: "a.2.sctv", fileExtension: "m4a", bytes: 12,
            cachedAt: replacement.cachedAt, lastPlayedAt: replacement.lastPlayedAt
        )
        let evicted = ledger.insert(replacement, now: start.addingTimeInterval(10), limits: limits)
        XCTAssertEqual(evicted.map(\.fileName), ["a.sctv"])
        XCTAssertEqual(ledger.totalBytes, 12)
    }

    func testStandardLimitsKeepAtLeastThreeHoursAndAtMostTwoGigabytes() {
        let standard = PlayedAudioCacheLedger.Limits.standard
        XCTAssertGreaterThanOrEqual(standard.minimumRetention, 3 * 60 * 60)
        XCTAssertLessThanOrEqual(standard.hardCapBytes, 2_000_000_000)
        XCTAssertLessThanOrEqual(standard.softCapBytes, standard.hardCapBytes)
    }
}

final class InstantPlayTuningTests: XCTestCase {
    func testLocalBytesStartImmediatelyWithoutStallWaiting() {
        XCTAssertTrue(InstantPlayTuning.startsImmediately(origin: .localCache, itemIsPrepared: false))
        XCTAssertFalse(InstantPlayTuning.waitsToMinimizeStalling(origin: .localCache))
    }

    func testNetworkStreamsKeepStallProtectionUnlessAlreadyBuffered() {
        XCTAssertFalse(InstantPlayTuning.startsImmediately(origin: .networkStream, itemIsPrepared: false))
        XCTAssertTrue(InstantPlayTuning.startsImmediately(origin: .networkStream, itemIsPrepared: true))
        XCTAssertTrue(InstantPlayTuning.waitsToMinimizeStalling(origin: .networkStream))
        XCTAssertFalse(InstantPlayTuning.startsImmediately(origin: .peerStream, itemIsPrepared: true))
    }
}
