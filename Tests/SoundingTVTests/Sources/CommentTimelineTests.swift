import Foundation
import XCTest
@testable import SoundingTV

final class CommentTimelineTests: XCTestCase {
    private func comment(id: Int, seconds: Double?) -> Comment {
        let timestamp = seconds.map { "\(Int($0 * 1000))" } ?? "null"
        let json = """
        {
            "id": \(id),
            "body": "comment \(id)",
            "timestamp": \(timestamp),
            "user": {
                "id": \(id * 100),
                "username": "user\(id)",
                "permalink": "user\(id)",
                "permalink_url": "https://soundcloud.com/user\(id)"
            }
        }
        """
        return try! JSONDecoder().decode(Comment.self, from: Data(json.utf8))
    }

    private func ordered(_ times: [Double]) -> [Comment] {
        CommentTimeline.ordered(times.enumerated().map { comment(id: $0.offset + 1, seconds: $0.element) })
    }

    func testOrderedDropsUntimedAndSortsByTime() {
        let comments = [
            comment(id: 1, seconds: 90),
            comment(id: 2, seconds: nil),
            comment(id: 3, seconds: 10),
            comment(id: 4, seconds: 40),
        ]
        XCTAssertEqual(CommentTimeline.ordered(comments).map(\.id), ["3", "4", "1"])
    }

    func testOrderedBreaksTiesByIdRegardlessOfInputOrder() {
        let forward = [comment(id: 9, seconds: 30), comment(id: 10, seconds: 30), comment(id: 2, seconds: 30)]
        let backward = Array(forward.reversed())
        XCTAssertEqual(CommentTimeline.ordered(forward).map(\.id), ["2", "9", "10"])
        XCTAssertEqual(CommentTimeline.ordered(backward).map(\.id), ["2", "9", "10"])
    }

    func testOrderedKeepsInputOrderForDuplicateIds() {
        let first = comment(id: 5, seconds: 12)
        let second = comment(id: 5, seconds: 12)
        let result = CommentTimeline.ordered([first, second])
        XCTAssertEqual(result, [first, second])
    }

    func testSplitBeforeFirstCommentHasNothingReached() {
        let comments = ordered([30, 60, 90])
        let split = CommentTimeline.split(comments, at: 5)
        XCTAssertEqual(split.reachedCount, 0)
        XCTAssertNil(split.currentIndex)
    }

    func testSplitPartitionsPastAndLater() {
        let comments = ordered([30, 60, 90, 200])
        let split = CommentTimeline.split(comments, at: 75)
        XCTAssertEqual(split.reachedCount, 2)
        XCTAssertEqual(comments.prefix(split.reachedCount).map(\.id), ["1", "2"])
        XCTAssertEqual(comments.dropFirst(split.reachedCount).map(\.id), ["3", "4"])
        XCTAssertEqual(split.currentIndex, 1)
    }

    func testSplitAfterLastCommentHasNothingLater() {
        let comments = ordered([30, 60])
        let split = CommentTimeline.split(comments, at: 500)
        XCTAssertEqual(split.reachedCount, 2)
        XCTAssertNil(split.currentIndex)
    }

    func testCurrentExpiresAfterWindow() {
        let comments = ordered([100])
        XCTAssertEqual(CommentTimeline.split(comments, at: 100).currentIndex, 0)
        XCTAssertEqual(CommentTimeline.split(comments, at: 124.9).currentIndex, 0)
        XCTAssertNil(CommentTimeline.split(comments, at: 125).currentIndex)
        XCTAssertEqual(CommentTimeline.split(comments, at: 125).reachedCount, 1)
    }

    func testToleranceIncludesCommentJustAhead() {
        let comments = ordered([60])
        XCTAssertEqual(CommentTimeline.split(comments, at: 59.4).reachedCount, 1)
        XCTAssertEqual(CommentTimeline.split(comments, at: 59.4, tolerance: 0.2).reachedCount, 0)
        XCTAssertEqual(CommentTimeline.split(comments, at: 59.5).reachedCount, 1)
        XCTAssertEqual(CommentTimeline.split(comments, at: 59.49).reachedCount, 1)
        XCTAssertEqual(CommentTimeline.split(comments, at: 59.4999, tolerance: 0.5).reachedCount, 1)
    }

    func testTiesMoveTogetherAndCurrentIsTheLastOfTheTies() {
        let comments = ordered([30, 60, 60, 60, 120])
        let before = CommentTimeline.split(comments, at: 58)
        XCTAssertEqual(before.reachedCount, 1)
        let at = CommentTimeline.split(comments, at: 60)
        XCTAssertEqual(at.reachedCount, 4)
        XCTAssertEqual(at.currentIndex, 3)
    }

    func testPlayingForwardNeverReturnsAReachedCommentToLater() {
        let comments = ordered([10, 20, 20, 45, 80, 80, 130])
        var previous = 0
        for step in stride(from: 0.0, through: 140.0, by: 0.25) {
            let count = CommentTimeline.split(comments, at: step).reachedCount
            XCTAssertGreaterThanOrEqual(count, previous)
            previous = count
        }
        XCTAssertEqual(previous, comments.count)
    }

    func testSeekingBackMovesPastCommentsToLater() {
        let comments = ordered([10, 50, 90])
        XCTAssertEqual(CommentTimeline.split(comments, at: 95).reachedCount, 3)
        XCTAssertEqual(CommentTimeline.split(comments, at: 20).reachedCount, 1)
    }

    func testEmptyInput() {
        let split = CommentTimeline.split([Comment](), at: 10)
        XCTAssertEqual(split.reachedCount, 0)
        XCTAssertNil(split.currentIndex)
    }

    func testGenericSplitUsesSuppliedTimes() {
        let times: [TimeInterval] = [1, 2, 3, 40]
        let split = CommentTimeline.split(times, at: 3) { $0 }
        XCTAssertEqual(split.reachedCount, 3)
        XCTAssertEqual(split.currentIndex, 2)
    }

    func testLaterAccessibilityLabelNamesTheTime() {
        XCTAssertEqual(
            CommentTimeline.laterAccessibilityLabel(name: "Ana", clock: "3:42", body: "this drop"),
            "Ana, later in the track, at 3:42, this drop"
        )
    }
}
