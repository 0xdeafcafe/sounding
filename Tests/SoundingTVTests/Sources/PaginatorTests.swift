import XCTest
@testable import SoundingTV

private struct Row: Identifiable, Equatable {
    let id: Int
}

private struct FakeFailure: Error {}

@MainActor
private final class FakePages {
    var pages: [[Int]]
    var failuresRemaining = 0
    var requested: [PagedCursor?] = []
    var delay: Duration?

    init(pages: [[Int]]) {
        self.pages = pages
    }

    private func chunk(at index: Int) -> PagedChunk<Row> {
        let next: PagedCursor? = index + 1 < pages.count
            ? .url(URL(string: "https://api.example.test/page/\(index + 1)")!)
            : nil
        return PagedChunk(items: pages[index].map(Row.init), next: next)
    }

    var source: PagedSource<Row> {
        PagedSource(
            first: { [self] in
                requested.append(nil)
                return chunk(at: 0)
            },
            next: { [self] cursor in
                requested.append(cursor)
                if let delay { try await Task.sleep(for: delay) }
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw FakeFailure()
                }
                guard case .url(let url) = cursor, let index = Int(url.lastPathComponent) else {
                    throw FakeFailure()
                }
                return chunk(at: index)
            }
        )
    }
}

@MainActor
final class PaginatorTests: XCTestCase {
    func testNextHrefChainsThroughEveryPageInOrder() async {
        let fake = FakePages(pages: [[1, 2, 3], [4, 5, 6], [7]])
        let pager = Paginator(source: fake.source)

        await pager.reload()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3])
        XCTAssertTrue(pager.hasMore)

        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4, 5, 6])
        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(fake.requested.count, 3)
    }

    func testStopsAtTheEndAndDoesNotRequestAgain() async {
        let fake = FakePages(pages: [[1, 2], [3]])
        let pager = Paginator(source: fake.source)
        await pager.reload()
        await pager.loadMore()

        XCTAssertTrue(pager.isComplete)
        XCTAssertFalse(pager.hasMore)
        let requests = fake.requested.count

        await pager.loadMore()
        await pager.loadMore()
        XCTAssertEqual(fake.requested.count, requests)
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3])
    }

    func testConcurrentTriggersLoadEachPageOnce() async {
        let fake = FakePages(pages: [[1, 2], [3, 4], [5, 6]])
        fake.delay = .milliseconds(40)
        let pager = Paginator(source: fake.source)
        await pager.reload()

        async let a: Void = pager.loadMore()
        async let b: Void = pager.loadMore()
        async let c: Void = pager.loadMore()
        _ = await (a, b, c)

        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(fake.requested.count, 2)
    }

    func testNearEndTriggerOnlyFiresWithinTheLeadWindow() async throws {
        let fake = FakePages(pages: [Array(1...20), [21, 22]])
        let pager = Paginator(source: fake.source)
        await pager.reload()

        pager.loadMoreIfNeeded(after: Row(id: 3), lead: 5)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pager.items.count, 20)

        pager.loadMoreIfNeeded(after: Row(id: 17), lead: 5)
        pager.loadMoreIfNeeded(after: Row(id: 19), lead: 5)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(pager.items.count, 22)
        XCTAssertEqual(fake.requested.count, 2)
    }

    func testFailureSurfacesRetryAndDoesNotAutoRepeat() async {
        let fake = FakePages(pages: [[1, 2], [3, 4]])
        let pager = Paginator(source: fake.source)
        await pager.reload()

        fake.failuresRemaining = 1
        await pager.loadMore()
        XCTAssertTrue(pager.didFailLoadingMore)
        XCTAssertEqual(pager.items.map(\.id), [1, 2])
        XCTAssertTrue(pager.hasMore)

        let requests = fake.requested.count
        await pager.loadMore()
        XCTAssertEqual(fake.requested.count, requests)

        await pager.retry()
        XCTAssertFalse(pager.didFailLoadingMore)
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4])
    }

    func testCacheThenNetworkContinuesWhereTheCacheStopped() async {
        var networkRequests: [PagedCursor] = []
        let cacheRows = (1...5).map(Row.init)
        let network: [Int: [Int]] = [0: [4, 5, 6], 1: [7, 8]]

        let source = PagedSource<Row>(
            first: {
                PagedChunk(items: Array(cacheRows.prefix(3)), next: .offset(3))
            },
            next: { cursor in
                switch cursor {
                case .offset(let offset):
                    let slice = Array(cacheRows.dropFirst(offset).prefix(3))
                    if offset + slice.count >= cacheRows.count {
                        return PagedChunk(items: slice, next: .start)
                    }
                    return PagedChunk(items: slice, next: .offset(offset + slice.count))
                case .start:
                    networkRequests.append(cursor)
                    return PagedChunk(
                        items: network[0]!.map(Row.init),
                        next: .url(URL(string: "https://api.example.test/page/1")!)
                    )
                case .url(let url):
                    networkRequests.append(cursor)
                    let index = Int(url.lastPathComponent)!
                    return PagedChunk(items: network[index]!.map(Row.init), next: nil)
                }
            }
        )
        let pager = Paginator(source: source)
        await pager.reload()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3])

        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertTrue(networkRequests.isEmpty)

        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4, 5, 6])
        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(pager.isComplete)
    }

    func testDuplicateOnlyPagesKeepAdvancingWithoutAnotherTrigger() async {
        let fake = FakePages(pages: [[1, 2], [1, 2], [2, 1], [3]])
        let pager = Paginator(source: fake.source)
        await pager.reload()
        await pager.loadMore()

        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3])
        XCTAssertTrue(pager.isComplete)
    }

    func testTrafficStopPausesThenResumesOnceWithoutHammering() async {
        let fake = FakePages(pages: [[1, 2], [3, 4]])
        var blockedUntil: Date?
        var sleeps: [TimeInterval] = []
        let pager = Paginator(
            source: fake.source,
            gate: { blockedUntil },
            now: { Date(timeIntervalSince1970: 4_000) },
            sleep: { seconds in
                sleeps.append(seconds)
                blockedUntil = nil
            }
        )
        await pager.reload()
        blockedUntil = Date(timeIntervalSince1970: 5_000)

        await pager.loadMore()
        await pager.loadMore()
        await pager.loadMore()
        XCTAssertTrue(pager.isPaused)
        XCTAssertEqual(fake.requested.count, 1)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertFalse(pager.isPaused)
        XCTAssertEqual(fake.requested.count, 1, "the pager waits for a visible footer instead of firing when the stop ends")

        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(fake.requested.count, 2)
    }

    func testFooterWalkStopsAfterTenUnattendedPagesUntilTheUserAsks() async {
        let fake = FakePages(pages: (0..<30).map { [$0 * 2 + 1, $0 * 2 + 2] })
        let pager = Paginator(source: fake.source)
        await pager.reload()
        for _ in 0..<20 {
            pager.requestMore()
            for _ in 0..<20 where pager.isLoadingMore { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fake.requested.count, 11)
        XCTAssertTrue(pager.awaitsUser)

        pager.continueLoading()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fake.requested.count, 12)
        XCTAssertFalse(pager.awaitsUser)
    }

    func testLocalOffsetPagesLoadDuringATrafficStopButNetworkPagesWait() async {
        var requested: [PagedCursor] = []
        let source = PagedSource<Row>(
            first: { PagedChunk(items: []) },
            next: { cursor in
                requested.append(cursor)
                switch cursor {
                case .offset: return PagedChunk(items: [Row(id: 2)], next: .url(URL(string: "https://api.example.test/page/1")!))
                default: return PagedChunk(items: [Row(id: 3)], next: nil)
                }
            }
        )
        let pager = Paginator(
            source: source,
            gate: { Date(timeIntervalSince1970: 5_000) },
            gateApplies: { cursor in
                if case .offset? = cursor { return false }
                return true
            },
            now: { Date(timeIntervalSince1970: 4_000) },
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        pager.prime(items: [Row(id: 1)], cursor: .offset(1))

        await pager.loadMore()
        XCTAssertEqual(pager.items.map(\.id), [1, 2])
        XCTAssertFalse(pager.isPaused)

        await pager.loadMore()
        XCTAssertTrue(pager.isPaused)
        XCTAssertEqual(pager.items.map(\.id), [1, 2])
        XCTAssertEqual(requested.count, 1)
        pager.reset()
    }

    func testBlockedErrorPausesInsteadOfShowingARetryRow() async {
        let until = Date(timeIntervalSince1970: 9_000)
        let source = PagedSource<Row>(
            first: { PagedChunk(items: [Row(id: 1)], next: .offset(1)) },
            next: { _ in throw APIError.temporarilyBlocked(until: until, statusCode: 429) }
        )
        let pager = Paginator(
            source: source,
            blockedUntil: { error in
                if case APIError.temporarilyBlocked(let until, _) = error { return until }
                return nil
            },
            now: { Date(timeIntervalSince1970: 8_000) },
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        await pager.reload()
        await pager.loadMore()

        XCTAssertTrue(pager.isPaused)
        XCTAssertFalse(pager.didFailLoadingMore)
        XCTAssertFalse(pager.isLoadingMore)
        pager.reset()
    }

    func testTotalCountCopyShowsPlusUntilComplete() async {
        let source = PagedSource<Row>(
            first: { PagedChunk(items: [Row(id: 1), Row(id: 2)], next: .offset(2)) },
            next: { _ in PagedChunk(items: [Row(id: 3)], next: nil) }
        )
        let pager = Paginator(source: source)
        await pager.reload()
        XCTAssertEqual(pager.countText(singular: "track", plural: "tracks"), "2+ tracks")
        await pager.loadMore()
        XCTAssertEqual(pager.countText(singular: "track", plural: "tracks"), "3 tracks")

        let known = PagedSource<Row>(
            first: { PagedChunk(items: [Row(id: 1)], next: .offset(1), total: 510) },
            next: { _ in PagedChunk(items: [], next: nil) }
        )
        let withTotal = Paginator(source: known)
        await withTotal.reload()
        XCTAssertEqual(withTotal.countText(singular: "track", plural: "tracks"), "510 tracks")
    }

    func testIsNearEndUsesAWindowRatherThanASinglePosition() {
        let rows = (1...30).map(Row.init)
        XCTAssertFalse(rows.isNearEnd(Row(id: 10), lead: 8))
        XCTAssertTrue(rows.isNearEnd(Row(id: 23), lead: 8))
        XCTAssertTrue(rows.isNearEnd(Row(id: 30), lead: 8))
    }
}
