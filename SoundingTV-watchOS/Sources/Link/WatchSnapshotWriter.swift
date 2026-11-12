import Foundation
import WidgetKit

@MainActor
final class WatchSnapshotWriter {
    static let shared = WatchSnapshotWriter()

    private static let seekTolerance: TimeInterval = 3

    private var snapshot: SoundingSnapshot?

    func record(_ nowPlaying: WatchNowPlaying, receivedAt: Date) {
        let current = load()
        guard let trackId = nowPlaying.trackId else {
            guard let previous = current.nowPlaying else { return }
            var next = current
            next.generatedAt = receivedAt
            next.nowPlaying = nil
            next.lastMix = SoundingSnapshot.Resume(
                item: previous.item,
                position: previous.position(at: receivedAt),
                collectionID: previous.collectionID,
                savedAt: receivedAt
            )
            commit(next)
            return
        }

        let item = SoundingSnapshot.Item(
            kind: .track,
            id: trackId,
            title: nowPlaying.title,
            subtitle: nowPlaying.artist,
            artworkURL: nowPlaying.artworkURL,
            duration: nowPlaying.durationSeconds > 0 ? nowPlaying.durationSeconds : nil
        )
        let anchor = SoundingSnapshot.PositionAnchor(
            position: nowPlaying.positionSeconds,
            anchoredAt: receivedAt,
            rate: nowPlaying.isPlaying ? 1 : 0
        )
        let next = SoundingSnapshot.NowPlaying(
            item: item,
            anchor: anchor,
            isPlaying: nowPlaying.isPlaying,
            collectionID: nil,
            queueIndex: nil,
            queueCount: nowPlaying.queueCount
        )
        if let previous = current.nowPlaying,
           previous.item == next.item,
           previous.isPlaying == next.isPlaying,
           abs(previous.position(at: receivedAt) - next.position(at: receivedAt)) < Self.seekTolerance {
            return
        }
        var updated = current
        updated.generatedAt = receivedAt
        updated.nowPlaying = next
        commit(updated)
    }

    func assume(isPlaying: Bool) {
        let current = load()
        guard var nowPlaying = current.nowPlaying, nowPlaying.isPlaying != isPlaying else { return }
        let now = Date()
        nowPlaying.anchor = SoundingSnapshot.PositionAnchor(
            position: nowPlaying.position(at: now),
            anchoredAt: now,
            rate: isPlaying ? 1 : 0
        )
        nowPlaying.isPlaying = isPlaying
        var updated = current
        updated.generatedAt = now
        updated.nowPlaying = nowPlaying
        commit(updated)
    }

    private func load() -> SoundingSnapshot {
        if let snapshot { return snapshot }
        let loaded = SoundingSnapshotStore.load() ?? SoundingSnapshot()
        snapshot = loaded
        return loaded
    }

    private func commit(_ next: SoundingSnapshot) {
        snapshot = next
        guard SoundingSnapshotStore.save(next) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.watchNowPlayingWidget)
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.watchListeningWidget)
        WidgetCenter.shared.invalidateRelevance(ofKind: SoundingSurfaceKind.watchListeningWidget)
        ControlCenter.shared.reloadControls(ofKind: SoundingSurfaceKind.playPauseControl)
    }
}
