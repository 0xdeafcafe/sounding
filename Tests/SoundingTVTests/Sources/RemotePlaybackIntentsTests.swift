import XCTest
@testable import SoundingTV

final class RemotePlaybackIntentsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func frame(
        playing: Bool,
        position: Double,
        track: String = "a",
        duration: Double = 300,
        revision: Int
    ) -> PlaybackStatePayload {
        PlaybackStatePayload(
            isPlaying: playing,
            positionSeconds: position,
            durationSeconds: duration,
            trackId: track,
            title: "Title \(track)",
            artist: "Artist \(track)",
            artworkURL: nil,
            isDJEngineLive: false,
            revision: revision,
            issuedAtMillis: 0,
            signature: ""
        )
    }

    private let queue = [
        QueueTrack(id: "a", title: "Title a", artist: "Artist a", artworkURL: nil, duration: 300),
        QueueTrack(id: "b", title: "Title b", artist: "Artist b", artworkURL: nil, duration: 200),
        QueueTrack(id: "c", title: "Title c", artist: "Artist c", artworkURL: nil, duration: 100),
    ]

    // MARK: - Play and pause

    func testPauseShowsPausedImmediatelyAndFreezesPosition() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.notePlaying(false, observed: observed, observedAt: t0, at: t0.addingTimeInterval(2))

        let shown = intents.present(observed, observedAt: t0, at: t0.addingTimeInterval(2.5)).playback
        XCTAssertFalse(shown.isPlaying)
        XCTAssertEqual(shown.positionSeconds, 12, accuracy: 0.001)
        let later = intents.present(observed, observedAt: t0, at: t0.addingTimeInterval(2.9)).playback
        XCTAssertEqual(later.positionSeconds, 12, accuracy: 0.001)
    }

    func testStaleFrameInsideGraceDoesNotFlickerBack() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.notePlaying(false, observed: observed, observedAt: t0, at: t0)

        let stale = frame(playing: true, position: 10.2, revision: 6)
        let staleAt = t0.addingTimeInterval(0.2)
        intents.settle(observed: stale, observedAt: staleAt, isLive: true, at: staleAt)
        XCTAssertNotNil(intents.transport)
        XCTAssertFalse(intents.present(stale, observedAt: staleAt, at: staleAt).playback.isPlaying)
    }

    func testConfirmingFrameSettlesToTheTruth() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.notePlaying(false, observed: observed, observedAt: t0, at: t0)

        let confirmed = frame(playing: false, position: 10.1, revision: 6)
        let at = t0.addingTimeInterval(0.3)
        intents.settle(observed: confirmed, observedAt: at, isLive: true, at: at)
        XCTAssertTrue(intents.isEmpty)
        XCTAssertNil(intents.anchor)
        XCTAssertEqual(intents.present(confirmed, observedAt: at, at: at).playback, confirmed)
    }

    func testDisagreeingFrameAfterGraceWins() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: false, position: 10, revision: 5)
        intents.notePlaying(true, observed: observed, observedAt: t0, at: t0)

        let refused = frame(playing: false, position: 10, revision: 7)
        let at = t0.addingTimeInterval(RemotePlaybackIntents.grace + 0.1)
        intents.settle(observed: refused, observedAt: at, isLive: true, at: at)
        XCTAssertTrue(intents.isEmpty)
        XCTAssertFalse(intents.present(refused, observedAt: at, at: at).playback.isPlaying)
    }

    func testSilenceSettlesAtTheDeadline() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: false, position: 10, revision: 5)
        intents.notePlaying(true, observed: observed, observedAt: t0, at: t0)
        XCTAssertEqual(intents.nextDeadline, t0.addingTimeInterval(RemotePlaybackIntents.deadline))

        intents.settle(observed: observed, observedAt: t0, isLive: true, at: t0.addingTimeInterval(1.5))
        XCTAssertFalse(intents.isEmpty)
        intents.settle(observed: observed, observedAt: t0, isLive: true, at: t0.addingTimeInterval(RemotePlaybackIntents.deadline))
        XCTAssertTrue(intents.isEmpty)
        XCTAssertNil(intents.nextDeadline)
    }

    func testDisconnectDropsEveryIntent() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.notePlaying(false, observed: observed, observedAt: t0, at: t0)
        intents.noteSeek(to: 40, observed: observed, observedAt: t0, at: t0)
        intents.settle(observed: observed, observedAt: t0, isLive: false, at: t0.addingTimeInterval(0.1))
        XCTAssertTrue(intents.isEmpty)
        XCTAssertNil(intents.anchor)
    }

    func testIntentsNeedAnObservationToAnchorTo() {
        var intents = RemotePlaybackIntents()
        intents.notePlaying(true, observed: nil, observedAt: t0, at: t0)
        intents.noteSkip(to: queue[1], observed: nil, observedAt: t0, at: t0)
        XCTAssertTrue(intents.isEmpty)
    }

    // MARK: - Skips

    func testNextShowsTheTargetTrackFromZero() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 120, revision: 5)
        intents.noteSkip(to: queue[1], observed: observed, observedAt: t0, at: t0)

        let shown = intents.present(observed, observedAt: t0, at: t0.addingTimeInterval(0.5)).playback
        XCTAssertEqual(shown.trackId, "b")
        XCTAssertEqual(shown.title, "Title b")
        XCTAssertEqual(shown.durationSeconds, 200)
        XCTAssertEqual(shown.positionSeconds, 0.5, accuracy: 0.001)
    }

    func testSkipSettlesWhenTheTrackChanges() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 120, revision: 5)
        intents.noteSkip(to: queue[1], observed: observed, observedAt: t0, at: t0)

        let stale = frame(playing: true, position: 120.3, revision: 6)
        intents.settle(observed: stale, observedAt: t0.addingTimeInterval(0.3), isLive: true, at: t0.addingTimeInterval(0.3))
        XCTAssertNotNil(intents.skip)
        XCTAssertEqual(intents.present(stale, observedAt: t0, at: t0.addingTimeInterval(0.3)).playback.trackId, "b")

        let landed = frame(playing: true, position: 0.2, track: "b", duration: 200, revision: 7)
        intents.settle(observed: landed, observedAt: t0.addingTimeInterval(0.5), isLive: true, at: t0.addingTimeInterval(0.5))
        XCTAssertTrue(intents.isEmpty)
    }

    func testRestartShowsZeroAndSettlesNearTheStart() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 80, revision: 5)
        XCTAssertEqual(
            RemoteSkipPlanner.previous(tracks: queue, currentIndex: 1, presentedTrackId: "b", position: 80),
            .restart
        )
        intents.noteSkip(to: nil, observed: observed, observedAt: t0, at: t0)
        let shown = intents.present(observed, observedAt: t0, at: t0).playback
        XCTAssertEqual(shown.trackId, "a")
        XCTAssertEqual(shown.positionSeconds, 0, accuracy: 0.001)

        let restarted = frame(playing: true, position: 0.4, revision: 6)
        intents.settle(observed: restarted, observedAt: t0.addingTimeInterval(0.4), isLive: true, at: t0.addingTimeInterval(0.4))
        XCTAssertTrue(intents.isEmpty)
    }

    func testPlannerPicksNeighboursAroundThePresentedTrack() {
        XCTAssertEqual(RemoteSkipPlanner.nextTarget(tracks: queue, currentIndex: 0, presentedTrackId: "a"), queue[1])
        XCTAssertEqual(RemoteSkipPlanner.nextTarget(tracks: queue, currentIndex: 0, presentedTrackId: "b"), queue[2])
        XCTAssertNil(RemoteSkipPlanner.nextTarget(tracks: queue, currentIndex: 2, presentedTrackId: "c"))
        XCTAssertNil(RemoteSkipPlanner.nextTarget(tracks: [], currentIndex: 0, presentedTrackId: nil))
        XCTAssertEqual(
            RemoteSkipPlanner.previous(tracks: queue, currentIndex: 2, presentedTrackId: "c", position: 1),
            .track(queue[1])
        )
        XCTAssertEqual(
            RemoteSkipPlanner.previous(tracks: queue, currentIndex: 0, presentedTrackId: "a", position: 1),
            .restart
        )
        XCTAssertEqual(
            RemoteSkipPlanner.previous(tracks: [], currentIndex: 0, presentedTrackId: "a", position: 1),
            .unknown
        )
    }

    // MARK: - Seeks

    func testSeekHoldsTheTargetUntilTheTelevisionCatchesUp() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.noteSeek(to: 150, observed: observed, observedAt: t0, at: t0)
        XCTAssertEqual(intents.present(observed, observedAt: t0, at: t0.addingTimeInterval(0.5)).playback.positionSeconds, 150.5, accuracy: 0.001)

        let stale = frame(playing: true, position: 10.3, revision: 6)
        intents.settle(observed: stale, observedAt: t0.addingTimeInterval(0.3), isLive: true, at: t0.addingTimeInterval(0.3))
        XCTAssertNotNil(intents.seek)

        let caughtUp = frame(playing: true, position: 150.6, revision: 7)
        intents.settle(observed: caughtUp, observedAt: t0.addingTimeInterval(0.6), isLive: true, at: t0.addingTimeInterval(0.6))
        XCTAssertTrue(intents.isEmpty)
    }

    func testSeekIsClampedToTheTrack() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: false, position: 10, duration: 60, revision: 5)
        intents.noteSeek(to: 900, observed: observed, observedAt: t0, at: t0)
        XCTAssertEqual(intents.seek?.target, 60)
        intents.noteSeek(to: -4, observed: observed, observedAt: t0, at: t0)
        XCTAssertEqual(intents.seek?.target, 0)
    }

    func testPauseAfterSeekFreezesAtTheSeekTarget() {
        var intents = RemotePlaybackIntents()
        let observed = frame(playing: true, position: 10, revision: 5)
        intents.noteSeek(to: 100, observed: observed, observedAt: t0, at: t0)
        intents.notePlaying(false, observed: observed, observedAt: t0, at: t0.addingTimeInterval(1))
        let shown = intents.present(observed, observedAt: t0, at: t0.addingTimeInterval(2)).playback
        XCTAssertFalse(shown.isPlaying)
        XCTAssertEqual(shown.positionSeconds, 101, accuracy: 0.001)
    }

    // MARK: - Queue projection

    func testUpNextFollowsAnOptimisticSkip() {
        let before = RemoteQueueProjection.upNext(tracks: queue, currentIndex: 0, presentedTrackId: "a").map(\.track.id)
        XCTAssertEqual(before, ["b", "c"])
        let after = RemoteQueueProjection.upNext(tracks: queue, currentIndex: 0, presentedTrackId: "b").map(\.track.id)
        XCTAssertEqual(after, ["c"])
        let unknown = RemoteQueueProjection.upNext(tracks: queue, currentIndex: 0, presentedTrackId: "zzz").map(\.index)
        XCTAssertEqual(unknown, [1, 2])
    }

    func testPlayNextMovesAnUpcomingTrackBehindTheCurrentOne() {
        let longer = queue + [QueueTrack(id: "d", title: "Title d", artist: "Artist d", artworkURL: nil, duration: 90)]
        XCTAssertEqual(RemoteQueueProjection.playNextDestination(for: 3, tracks: longer, currentIndex: 0, presentedTrackId: "a"), 1)
        XCTAssertNil(RemoteQueueProjection.playNextDestination(for: 1, tracks: longer, currentIndex: 0, presentedTrackId: "a"))
        XCTAssertNil(RemoteQueueProjection.playNextDestination(for: 9, tracks: longer, currentIndex: 0, presentedTrackId: "a"))
    }

    // MARK: - Phase

    func testPhaseResolution() {
        XCTAssertEqual(RemotePhase.resolve(link: .unlinked, peerNeedsSignIn: false, hasPlayback: true, isLive: true), .unlinked)
        XCTAssertEqual(RemotePhase.resolve(link: .unreachable, peerNeedsSignIn: false, hasPlayback: true, isLive: false), .unreachable)
        XCTAssertEqual(RemotePhase.resolve(link: .connecting, peerNeedsSignIn: false, hasPlayback: false, isLive: false), .connecting)
        XCTAssertEqual(RemotePhase.resolve(link: .connecting, peerNeedsSignIn: false, hasPlayback: true, isLive: false), .playing(isLive: false))
        XCTAssertEqual(RemotePhase.resolve(link: .connected, peerNeedsSignIn: true, hasPlayback: true, isLive: true), .needsSignIn)
        XCTAssertEqual(RemotePhase.resolve(link: .connected, peerNeedsSignIn: false, hasPlayback: false, isLive: true), .nothingPlaying)
        XCTAssertEqual(RemotePhase.resolve(link: .connected, peerNeedsSignIn: false, hasPlayback: true, isLive: true), .playing(isLive: true))
    }
}
