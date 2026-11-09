import XCTest
@testable import SoundingTV

@MainActor
final class PlayingNextQueueTests: XCTestCase {
    private let context = ["now", "c1", "c2", "c3", "c4"]

    private func queued(_ ids: [String], into queue: inout [String], currentIndex: Int, last: Bool) -> PlayingNextQueue {
        var block = PlayingNextQueue()
        for id in ids {
            let index = last ? block.addToQueueIndex(in: queue, currentIndex: currentIndex) : block.playNextIndex(currentIndex: currentIndex)
            block.noteInserted(id, at: index, before: queue, currentIndex: currentIndex)
            queue.insert(id, at: index)
        }
        return block
    }

    func testAddToQueuePlaysBeforeTheRestOfTheContext() {
        var queue = context
        let block = queued(["u1", "u2"], into: &queue, currentIndex: 0, last: true)
        XCTAssertEqual(queue, ["now", "u1", "u2", "c1", "c2", "c3", "c4"])
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 2)
    }

    func testPlayNextGoesToTheFrontOfPlayingNext() {
        var queue = context
        var block = queued(["u1"], into: &queue, currentIndex: 0, last: true)
        let index = block.playNextIndex(currentIndex: 0)
        block.noteInserted("u2", at: index, before: queue, currentIndex: 0)
        queue.insert("u2", at: index)
        XCTAssertEqual(queue, ["now", "u2", "u1", "c1", "c2", "c3", "c4"])
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 2)
    }

    func testAutoMixMayOnlyTakeTheFirstQueuedTrack() {
        var queue = context
        let block = queued(["u1", "u2"], into: &queue, currentIndex: 0, last: true)
        XCTAssertEqual(block.autoMixCandidates(in: queue, currentIndex: 0), ["u1"])
        XCTAssertEqual(PlayingNextQueue().autoMixCandidates(in: context, currentIndex: 0), ["c1", "c2", "c3", "c4"])
    }

    func testAutoMixPicksAgainOnceTheUserQueueHasPlayed() {
        var queue = context
        var block = queued(["u1"], into: &queue, currentIndex: 0, last: true)
        block.prune(queue: queue, currentIndex: 1)
        XCTAssertEqual(block.count(in: queue, currentIndex: 1), 0)
        XCTAssertEqual(block.autoMixCandidates(in: queue, currentIndex: 1), ["c1", "c2", "c3", "c4"])
    }

    func testDraggingIntoAndOutOfPlayingNext() {
        var queue = context
        var block = queued(["u1", "u2"], into: &queue, currentIndex: 0, last: true)

        let wasQueued = block.contains(offset: 4, in: queue, currentIndex: 0)
        XCTAssertFalse(wasQueued)
        let moved = queue.remove(at: 4)
        queue.insert(moved, at: 1)
        block.noteMoved(moved, wasQueued: wasQueued, to: 1, after: queue, currentIndex: 0)
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 3)

        let leaving = queue.remove(at: 1)
        queue.insert(leaving, at: 5)
        block.noteMoved(leaving, wasQueued: true, to: 5, after: queue, currentIndex: 0)
        XCTAssertEqual(queue, ["now", "u1", "u2", "c1", "c3", "c2", "c4"])
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 2)

        let tail = queue.remove(at: 1)
        queue.insert(tail, at: 2)
        block.noteMoved(tail, wasQueued: true, to: 2, after: queue, currentIndex: 0)
        XCTAssertEqual(queue, ["now", "u2", "u1", "c1", "c3", "c2", "c4"])
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 2)
    }

    func testRemovingAQueuedTrackShrinksPlayingNext() {
        var queue = context
        var block = queued(["u1", "u2"], into: &queue, currentIndex: 0, last: true)
        let removed = queue.remove(at: 1)
        block.noteRemoved(removed, wasQueued: true)
        XCTAssertEqual(block.count(in: queue, currentIndex: 0), 1)
        XCTAssertEqual(block.autoMixCandidates(in: queue, currentIndex: 0), ["u2"])
    }

    func testLayoutPutsTheUserQueueFirstThenTheAutoMixPick() {
        let queuedLayout = UpNextLayout.make(upcomingCount: 6, playingNextCount: 2, autoMixOn: true)
        XCTAssertEqual(queuedLayout.playingNext, 0..<2)
        XCTAssertNil(queuedLayout.autoMixPick)
        XCTAssertEqual(queuedLayout.continuePlaying, 2..<6)

        let picked = UpNextLayout.make(upcomingCount: 6, playingNextCount: 0, autoMixOn: true)
        XCTAssertEqual(picked.autoMixPick, 0)
        XCTAssertEqual(picked.continuePlaying, 1..<6)
        XCTAssertEqual(picked.section(at: 0), .autoMix)

        let plain = UpNextLayout.make(upcomingCount: 3, playingNextCount: 0, autoMixOn: false)
        XCTAssertNil(plain.autoMixPick)
        XCTAssertEqual(plain.continuePlaying, 0..<3)
    }

    func testPlayerKeepsQueuedTracksAheadOfAutoMixPromotion() {
        let player = PlayerService.shared
        let tracks = Array(VisualFixtures.tracks.prefix(6))
        player.installVisualFixture(track: tracks[0], queue: Array(tracks.prefix(4)), position: 0)

        player.addToQueue(tracks[4])
        player.addToQueue(tracks[5])
        XCTAssertEqual(player.queue.map(\.id), [tracks[0], tracks[4], tracks[5], tracks[1], tracks[2], tracks[3]].map(\.id))
        XCTAssertEqual(player.playingNextCount, 2)

        player.promoteToUpcoming(trackId: tracks[3].id)
        XCTAssertEqual(player.queue[1].id, tracks[4].id)

        player.moveQueueItem(from: 2, to: 1)
        XCTAssertEqual(player.queue.prefix(3).map(\.id), [tracks[0], tracks[5], tracks[4]].map(\.id))
        XCTAssertEqual(player.playingNextCount, 2)
    }
}
