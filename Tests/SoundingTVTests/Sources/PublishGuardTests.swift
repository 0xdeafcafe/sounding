import Combine
import XCTest
@testable import SoundingTV

private struct GuardRow: Identifiable, Equatable {
    let id: Int
}

@MainActor
final class PublishGuardTests: XCTestCase {
    private func count(_ publisher: ObservableObjectPublisher, during work: () -> Void) -> Int {
        var fired = 0
        let token = publisher.sink { fired += 1 }
        work()
        token.cancel()
        return fired
    }

    func testAnalysisStatusSkipsRepeatedState() {
        let status = AutomaticAnalysisStatus.shared
        let trackId = "publish-guard-\(UUID().uuidString)"
        defer { status.clear(trackId) }
        let fired = count(status.objectWillChange) {
            status.set(.analysing, for: trackId)
            status.set(.analysing, for: trackId)
            status.set(.analysing, for: trackId)
        }
        XCTAssertEqual(fired, 1)
    }

    func testAnalysisStatusClearOfUnknownTrackIsSilent() {
        let status = AutomaticAnalysisStatus.shared
        let fired = count(status.objectWillChange) {
            status.clear("publish-guard-missing-\(UUID().uuidString)")
        }
        XCTAssertEqual(fired, 0)
    }

    func testQueuePositionsPublishOnceAndOnlyOnChange() {
        let status = AutomaticAnalysisStatus.shared
        let ids = (0..<50).map { "publish-guard-\($0)-\(UUID().uuidString)" }
        let positions = ids.enumerated().map { ($0.element, $0.offset + 1) }
        defer { ids.forEach(status.clear) }
        let first = count(status.objectWillChange) { status.setQueuePositions(positions) }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(status.state(for: ids[3]), .queued(position: 4))
        let repeated = count(status.objectWillChange) { status.setQueuePositions(positions) }
        XCTAssertEqual(repeated, 0)
    }

    func testPaginatorAttendIsSilentWhenNotWaiting() {
        let pager = Paginator<GuardRow>(source: PagedSource(
            first: { PagedChunk(items: []) },
            next: { _ in PagedChunk(items: []) }
        ))
        let fired = count(pager.objectWillChange) {
            pager.attend()
            pager.attend()
        }
        XCTAssertEqual(fired, 0)
    }
}
