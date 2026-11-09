import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

enum PlaybackStateStoreSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            (lines + failures.map { "FAIL: \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()

        let snapshot = PlaybackStateStore.Snapshot(
            trackIds: ["101", "202", "303"],
            currentIndex: 1,
            positionSeconds: 42.5,
            isShuffleEnabled: true,
            repeatMode: .all,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard let data = try? JSONEncoder().encode(snapshot) else {
            report.failures.append("snapshot failed to encode")
            return report
        }
        report.lines.append("encoded snapshot (\(data.count) bytes)")

        guard let decoded = try? JSONDecoder().decode(PlaybackStateStore.Snapshot.self, from: data) else {
            report.failures.append("snapshot failed to decode")
            return report
        }

        if decoded == snapshot {
            report.lines.append("round-trip preserved all fields")
        } else {
            report.failures.append("round-trip produced a different snapshot: \(decoded)")
        }

        return report
    }
}
#endif

final class PlaybackPipelineTests: XCTestCase {
    func testPauseWhileResolvingPreventsLateAutoplay() {
        var pipeline = PlaybackPipeline()
        let token = pipeline.begin(trackID: "track-a", intent: .play)

        pipeline.requestPause(trackID: "track-a")

        XCTAssertFalse(pipeline.wantsPlayback)
        XCTAssertFalse(pipeline.isLoading)
        XCTAssertEqual(pipeline.loadingState, .idle)
        XCTAssertTrue(pipeline.transition(.buffering(trackID: "track-a"), for: token))
        XCTAssertFalse(pipeline.wantsPlayback)
        XCTAssertFalse(pipeline.isLoading)
    }

    func testOldTrackCannotOverwriteNewerSelection() {
        var pipeline = PlaybackPipeline()
        let oldToken = pipeline.begin(trackID: "track-a", intent: .play)
        let newToken = pipeline.begin(trackID: "track-b", intent: .play)

        XCTAssertFalse(pipeline.transition(.playing(trackID: "track-a"), for: oldToken))
        XCTAssertTrue(pipeline.transition(.playing(trackID: "track-b"), for: newToken))
        XCTAssertTrue(pipeline.isPlaying)
        XCTAssertEqual(pipeline.phase, .playing(trackID: "track-b"))
    }

    func testFailureStopsRetryIntentAndLoadingUI() {
        var pipeline = PlaybackPipeline()
        let token = pipeline.begin(trackID: "track-a", intent: .play)
        XCTAssertTrue(pipeline.isLoading)

        pipeline.requestPause(trackID: "track-a")
        XCTAssertTrue(pipeline.transition(.failed(trackID: "track-a", message: "offline"), for: token))

        XCTAssertFalse(pipeline.wantsPlayback)
        XCTAssertFalse(pipeline.isPlaying)
        XCTAssertFalse(pipeline.isLoading)
        XCTAssertEqual(pipeline.loadingState, .idle)
    }
}

final class PlaybackPrewarmingPolicyTests: XCTestCase {
    func testOnlyMatchingFreshPreparationCanBeAdopted() {
        let now = Date(timeIntervalSince1970: 10_000)
        let preparedAt = now.addingTimeInterval(-5)

        XCTAssertTrue(PlaybackPrewarmingPolicy.isFresh(
            preparedTrackID: "track-a",
            expectedTrackID: "track-a",
            preparedAt: preparedAt,
            now: now
        ))
        XCTAssertFalse(PlaybackPrewarmingPolicy.isFresh(
            preparedTrackID: "track-a",
            expectedTrackID: "track-b",
            preparedAt: preparedAt,
            now: now
        ))
    }

    func testPreparationExpiresAndRemainsBounded() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(PlaybackPrewarmingPolicy.isFresh(
            preparedTrackID: "track-a",
            expectedTrackID: "track-a",
            preparedAt: now.addingTimeInterval(-PlaybackPrewarmingPolicy.expirationInterval),
            now: now
        ))
        XCTAssertEqual(PlaybackPrewarmingPolicy.maximumPreparedItems, 1)
        XCTAssertEqual(PlaybackPrewarmingPolicy.preferredForwardBufferDuration, 5)
    }
}

final class PlaybackPersistenceAccountPolicyTests: XCTestCase {
    func testAccountKeyStaysStableWhileASyncedSessionIsAdopted() {
        let verified = PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: "account-1",
            currentUserID: "account-1",
            rememberedAccountID: "account-1",
            isSignedOut: false
        )
        let adopting = PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: "account-1",
            currentUserID: nil,
            rememberedAccountID: "account-1",
            isSignedOut: false
        )
        let launching = PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: nil,
            currentUserID: nil,
            rememberedAccountID: "account-1",
            isSignedOut: false
        )
        XCTAssertEqual(verified, "account-1")
        XCTAssertEqual(adopting, verified)
        XCTAssertEqual(launching, verified)
    }

    func testUnknownAccountWaitsAndSignOutUsesTheGuestKey() {
        XCTAssertNil(PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: nil,
            currentUserID: nil,
            rememberedAccountID: nil,
            isSignedOut: false
        ))
        XCTAssertEqual(PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: "account-1",
            currentUserID: "account-1",
            rememberedAccountID: "account-1",
            isSignedOut: true
        ), PlaybackPersistenceAccountPolicy.guestAccountID)
    }
}

final class PlaybackAccountTransitionPolicyTests: XCTestCase {
    func testTransientMissingAccountPreservesNowPlaying() {
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: "account-1", to: nil, hasLiveSession: true),
            .keep
        )
    }

    func testSameAccountAfterSessionAdoptionDoesNotRestartRestore() {
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: "account-1", to: "account-1", hasLiveSession: false),
            .keep
        )
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: "account-1", to: "account-1", hasLiveSession: true),
            .keep
        )
    }

    func testFirstKnownAccountRestoresWhenNothingIsPlaying() {
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: nil, to: "account-1", hasLiveSession: false),
            .restore("account-1")
        )
    }

    func testPlaybackStartedBeforeTheAccountResolvedIsKept() {
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: nil, to: "account-1", hasLiveSession: true),
            .adopt("account-1")
        )
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(
                from: PlaybackPersistenceAccountPolicy.guestAccountID,
                to: "account-1",
                hasLiveSession: true
            ),
            .adopt("account-1")
        )
    }

    func testDifferentAccountReplacesTheRestoredSession() {
        XCTAssertEqual(
            PlaybackAccountTransitionPolicy.transition(from: "account-1", to: "account-2", hasLiveSession: true),
            .replace("account-2")
        )
    }
}

final class PlaybackRestoreLedgerTests: XCTestCase {
    private let snapshotIds = ["a", "b", "c", "d", "e"]

    func testUnchangedPartialQueueSavesTheWholeSnapshotOrder() throws {
        let ledger = PlaybackRestoreLedger(snapshotIds: snapshotIds, resolvedIds: ["b", "d", "e"])
        XCTAssertEqual(ledger.keptIds, ["b", "d", "e"])
        XCTAssertFalse(ledger.isComplete)

        let order = try XCTUnwrap(ledger.persistedOrder(liveIds: ["b", "d", "e"], liveIndex: 1))
        XCTAssertEqual(order.ids, snapshotIds)
        XCTAssertEqual(order.index, 3)
    }

    func testEditedQueueIsNoLongerMerged() {
        let ledger = PlaybackRestoreLedger(snapshotIds: snapshotIds, resolvedIds: ["b", "d", "e"])
        XCTAssertNil(ledger.persistedOrder(liveIds: ["d", "b", "e"], liveIndex: 0))
        XCTAssertNil(ledger.persistedOrder(liveIds: ["b", "d", "e"], liveIndex: 3))
    }

    func testEnrichmentKeepsTheSameCurrentTrack() throws {
        let ledger = PlaybackRestoreLedger(snapshotIds: snapshotIds, resolvedIds: ["b", "d", "e"])
        let enriched = try XCTUnwrap(ledger.enriched(with: ["a", "c"], liveIds: ["b", "d", "e"], liveIndex: 1))
        XCTAssertTrue(enriched.ledger.isComplete)
        XCTAssertEqual(enriched.ledger.keptIds, snapshotIds)
        XCTAssertEqual(enriched.ledger.keptIds[enriched.index], "d")
    }

    func testDuplicateTracksMapByPosition() throws {
        let ledger = PlaybackRestoreLedger(snapshotIds: ["a", "x", "a", "y"], resolvedIds: ["a"])
        XCTAssertEqual(ledger.keptIds, ["a", "a"])
        let enriched = try XCTUnwrap(ledger.enriched(with: ["x", "y"], liveIds: ["a", "a"], liveIndex: 1))
        XCTAssertEqual(enriched.index, 2)
    }
}

final class PlaybackSnapshotAutoMixTests: XCTestCase {
    func testAutoMixStateRoundTrips() throws {
        let snapshot = PlaybackStateStore.Snapshot(
            trackIds: ["101", "202", "303"],
            currentIndex: 2,
            positionSeconds: 61,
            isShuffleEnabled: true,
            repeatMode: .all,
            collectionId: "likes",
            queueSource: .likes,
            djProfileId: .junkie,
            collectionAutoMixWasActive: false,
            autoMixWasActive: true,
            djSessionWasRequested: false,
            originalTrackIds: ["303", "101", "202"],
            currentTrackPayload: Data("{}".utf8),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try JSONDecoder().decode(
            PlaybackStateStore.Snapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.autoMixWasActive, true)
        XCTAssertEqual(decoded.djProfileId, .junkie)
        XCTAssertTrue(decoded.wantsMix)
        XCTAssertEqual(decoded.currentTrackId, "303")
    }

    func testSnapshotsFromOlderBuildsStillDecode() throws {
        let object: [String: Any] = [
            "trackIds": ["1", "2"],
            "currentIndex": 1,
            "positionSeconds": 5,
            "isShuffleEnabled": false,
            "repeatMode": RepeatMode.off.rawValue,
            "collectionAutoMixWasActive": true,
            "savedAt": 0,
        ]
        let decoded = try JSONDecoder().decode(
            PlaybackStateStore.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.autoMixWasActive)
        XCTAssertNil(decoded.currentTrackPayload)
        XCTAssertTrue(decoded.wantsMix)
    }

    func testCurrentTrackPayloadRoundTrips() throws {
        let json = """
        {
            "id": 424242, "title": "Fixture", "description": null,
            "artwork_url": null, "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/424242",
            "playback_count": 0, "likes_count": 0, "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": { "id": 1, "username": "example", "permalink": "example",
                      "permalink_url": "https://soundcloud.com/example" },
            "media": { "transcodings": [ {
                "url": "https://api-v2.soundcloud.com/media/example/424242/stream",
                "duration": 200000, "quality": "hq",
                "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                "preset": "aac_256k"
            } ] }
        }
        """
        let track = try LikesSyncEngine.makeDecoder().decode(Track.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(PlaybackStateStore.encodeTrack(track))
        let decoded = try XCTUnwrap(PlaybackStateStore.decodeTrack(payload))
        XCTAssertEqual(decoded.id, track.id)
        XCTAssertEqual(decoded.title, track.title)
        XCTAssertEqual(decoded.streamURL, track.streamURL)
        XCTAssertEqual(decoded.duration, track.duration)
    }
}

