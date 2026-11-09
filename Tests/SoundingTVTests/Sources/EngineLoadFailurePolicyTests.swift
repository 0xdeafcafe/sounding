import XCTest
@testable import SoundingTV

final class EngineLoadFailurePolicyTests: XCTestCase {
    func testLocalPlaybackStillFallsBackToAVPlayer() {
        XCTAssertEqual(
            EngineLoadFailurePolicy.action(requiresEngineOutput: false, retriesSoFar: 0, consecutiveSkips: 0, hasNextTrack: true),
            .fallBackToAVPlayer
        )
    }

    func testSonosRetriesTheTrackInTheEngineFirst() {
        XCTAssertEqual(
            EngineLoadFailurePolicy.action(requiresEngineOutput: true, retriesSoFar: 0, consecutiveSkips: 0, hasNextTrack: true),
            .retry(after: EngineLoadFailurePolicy.retryDelay)
        )
    }

    func testSonosSkipsToTheNextTrackAfterTheRetryFails() {
        XCTAssertEqual(
            EngineLoadFailurePolicy.action(requiresEngineOutput: true, retriesSoFar: 1, consecutiveSkips: 0, hasNextTrack: true),
            .skipToNext
        )
    }

    func testSonosNeverHandsAFailedTrackToTheMutedAVPlayer() {
        for retries in 0...3 {
            for skips in 0...5 {
                for hasNext in [true, false] {
                    let action = EngineLoadFailurePolicy.action(
                        requiresEngineOutput: true,
                        retriesSoFar: retries,
                        consecutiveSkips: skips,
                        hasNextTrack: hasNext
                    )
                    XCTAssertNotEqual(action, .fallBackToAVPlayer)
                }
            }
        }
    }

    func testSonosStopsWhenNothingIsLeftToPlay() {
        XCTAssertEqual(
            EngineLoadFailurePolicy.action(requiresEngineOutput: true, retriesSoFar: 1, consecutiveSkips: 0, hasNextTrack: false),
            .stop
        )
    }

    func testSonosStopsAfterARunOfFailedSkips() {
        XCTAssertEqual(
            EngineLoadFailurePolicy.action(
                requiresEngineOutput: true,
                retriesSoFar: 1,
                consecutiveSkips: EngineLoadFailurePolicy.maxConsecutiveSkips,
                hasNextTrack: true
            ),
            .stop
        )
    }
}
