import XCTest
@testable import SoundingTV

@MainActor
final class QueueReorderTests: XCTestCase {
    func testMovingDownPlacesTheItemBeforeTheTargetAdjustedForRemoval() {
        XCTAssertEqual(QueueReorder.move(source: 0, before: 3, count: 5), .init(from: 0, to: 2))
    }

    func testMovingUpPlacesTheItemAtTheTargetIndex() {
        XCTAssertEqual(QueueReorder.move(source: 3, before: 1, count: 5), .init(from: 3, to: 1))
    }

    func testDroppingAtTheEndMovesToTheLastIndex() {
        XCTAssertEqual(QueueReorder.move(source: 1, before: nil, count: 4), .init(from: 1, to: 3))
    }

    func testDroppingNextToItselfIsANoOp() {
        XCTAssertNil(QueueReorder.move(source: 2, before: 2, count: 5))
        XCTAssertNil(QueueReorder.move(source: 2, before: 3, count: 5))
        XCTAssertNil(QueueReorder.move(source: 4, before: nil, count: 5))
    }

    func testOutOfRangeAndSingleItemQueuesAreRejected() {
        XCTAssertNil(QueueReorder.move(source: 5, before: 0, count: 5))
        XCTAssertNil(QueueReorder.move(source: 0, before: nil, count: 1))
        XCTAssertNil(QueueReorder.move(source: 0, before: 9, count: 5))
    }

    func testAccessibilityStepsStayInsideTheUpNextRange() {
        XCTAssertEqual(QueueReorder.moveByOne(source: 2, up: true, within: 1..<4), .init(from: 2, to: 1))
        XCTAssertNil(QueueReorder.moveByOne(source: 1, up: true, within: 1..<4))
        XCTAssertEqual(QueueReorder.moveByOne(source: 2, up: false, within: 1..<4), .init(from: 2, to: 3))
        XCTAssertNil(QueueReorder.moveByOne(source: 3, up: false, within: 1..<4))
    }

    func testPlayerQueueMoveKeepsTheCurrentTrackSelected() throws {
        let player = PlayerService.shared
        let tracks = Array(VisualFixtures.tracks.prefix(6))
        let current = tracks[1]
        player.installVisualFixture(track: current, queue: tracks, position: 0)

        let move = try XCTUnwrap(QueueReorder.move(source: 2, before: 5, count: tracks.count))
        player.moveQueueItem(from: move.from, to: move.to)

        XCTAssertEqual(player.queue.map(\.id), [tracks[0], tracks[1], tracks[3], tracks[4], tracks[2], tracks[5]].map(\.id))
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.currentTrack?.id, current.id)

        player.moveQueueItem(from: 4, to: 0)
        XCTAssertEqual(player.queue.first?.id, tracks[2].id)
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.queue[player.currentIndex].id, current.id)
    }
}
