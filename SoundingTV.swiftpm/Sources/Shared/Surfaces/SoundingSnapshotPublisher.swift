import Combine
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class SoundingSnapshotPublisher {
    static let shared = SoundingSnapshotPublisher()

    private static let writeDelay: Duration = .milliseconds(750)
    private static let driftTolerance: TimeInterval = 3

    private let fileURL: URL?
    private var snapshot: SoundingSnapshot
    private var cancellables = Set<AnyCancellable>()
    private weak var player: PlayerService?
    private var pendingWrite: Task<Void, Never>?
    private var surfaceState: SurfaceState?

    private struct SurfaceState: Equatable {
        var trackID: String?
        var isPlaying: Bool
        var recentIDs: [String]
        var mixID: String?
        var anchorBucket: Int?
    }

    init(fileURL: URL? = SoundingSnapshotStore.defaultFileURL) {
        self.fileURL = fileURL
        snapshot = SoundingSnapshotStore.load(from: fileURL) ?? .empty
    }

    var current: SoundingSnapshot { snapshot }

    func start(player: PlayerService) {
        guard self.player !== player else { return }
        self.player = player
        cancellables.removeAll()

        player.$currentTrack
            .map(\.?.id)
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        player.$activeCollectionId
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        player.clock.$currentTime
            .sink { [weak self] time in self?.noteClock(time) }
            .store(in: &cancellables)

        #if os(iOS) || os(macOS)
        WidgetCollectionPublisher.shared.start()
        #endif
    }

    func clear() {
        pendingWrite?.cancel()
        pendingWrite = nil
        snapshot = SoundingSnapshot(generatedAt: Date())
        SoundingSnapshotStore.remove(at: fileURL)
        #if os(iOS) || os(macOS)
        WidgetArtworkWriter.shared.reset()
        WidgetCollectionPublisher.shared.clear()
        #endif
        reloadSurfaces(force: true)
    }

    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    func adoptRecents(_ items: [SoundingSnapshot.Item]) {
        var next = snapshot
        next.recents = Array(items.prefix(SoundingSnapshot.recentsLimit))
        if let nowPlaying = next.nowPlaying, nowPlaying.isPlaying {
            next = next.recording(nowPlaying.item)
        }
        guard next.recents != snapshot.recents else { return }
        snapshot = next
        SoundingSnapshotStore.save(snapshot, to: fileURL)
        #if os(iOS) || os(macOS)
        WidgetArtworkWriter.shared.sync(snapshot) { [weak self] in
            self?.reloadSurfaces(force: true)
        }
        #endif
        reloadSurfaces(force: false)
    }

    private func noteClock(_ time: TimeInterval) {
        guard pendingWrite == nil,
              let player,
              let nowPlaying = snapshot.nowPlaying,
              nowPlaying.item.id == player.currentTrack?.id else { return }
        let predicted = nowPlaying.position(at: Date())
        guard abs(predicted - time) > Self.driftTolerance else { return }
        scheduleWrite()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    private func write() {
        guard let player else { return }
        let now = Date()
        snapshot = Self.next(
            after: snapshot,
            track: player.currentTrack.map(Self.item(for:)),
            position: player.currentTime,
            isPlaying: player.isPlaying,
            collectionID: player.activeCollectionId,
            queueIndex: player.queue.isEmpty ? nil : player.currentIndex,
            queueCount: player.queue.isEmpty ? nil : player.queue.count,
            at: now
        )
        SoundingSnapshotStore.save(snapshot, to: fileURL)
        #if os(iOS) || os(macOS)
        WidgetArtworkWriter.shared.sync(snapshot) { [weak self] in
            self?.reloadSurfaces(force: true)
        }
        #endif
        reloadSurfaces(force: false)
    }

    static func item(for track: Track) -> SoundingSnapshot.Item {
        SoundingSnapshot.Item(
            kind: .track,
            id: track.id,
            title: track.title,
            subtitle: track.user.displayName,
            artworkURL: track.largeArtworkURL ?? track.artworkURL,
            duration: track.duration > 0 ? track.duration : nil,
            isMix: DeckIdentityResolver.isLikelyMix(track)
        )
    }

    static func next(
        after previous: SoundingSnapshot,
        track: SoundingSnapshot.Item?,
        position: TimeInterval,
        isPlaying: Bool,
        collectionID: String?,
        queueIndex: Int?,
        queueCount: Int?,
        at now: Date
    ) -> SoundingSnapshot {
        var next = previous
        next.version = SoundingSnapshot.currentVersion
        next.generatedAt = now

        guard let track else {
            next.nowPlaying = nil
            return next
        }

        next.nowPlaying = SoundingSnapshot.NowPlaying(
            item: track,
            anchor: SoundingSnapshot.PositionAnchor(
                position: position,
                anchoredAt: now,
                rate: isPlaying ? 1 : 0
            ),
            isPlaying: isPlaying,
            collectionID: collectionID,
            queueIndex: queueIndex,
            queueCount: queueCount
        )

        if isPlaying {
            next = next.recording(track)
        }

        if track.isMix {
            next.lastMix = SoundingSnapshot.Resume(
                item: track,
                position: max(0, position.isFinite ? position : 0),
                collectionID: collectionID,
                savedAt: now
            )
        }
        return next
    }

    private func reloadSurfaces(force: Bool) {
        let state = SurfaceState(
            trackID: snapshot.nowPlaying?.item.id,
            isPlaying: snapshot.nowPlaying?.isPlaying ?? false,
            recentIDs: snapshot.recents.prefix(8).map(\.id),
            mixID: snapshot.lastMix?.item.id,
            anchorBucket: snapshot.nowPlaying.map { nowPlaying in
                let seconds = nowPlaying.isPlaying
                    ? nowPlaying.anchor.startDate.timeIntervalSinceReferenceDate
                    : nowPlaying.anchor.position
                return Int((seconds / Self.driftTolerance).rounded(.down))
            }
        )
        guard force || state != surfaceState else { return }
        surfaceState = state
        #if canImport(WidgetKit) && (os(iOS) || os(macOS))
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.nowPlayingWidget)
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.recentlyPlayedWidget)
        WidgetCenter.shared.reloadTimelines(ofKind: SoundingSurfaceKind.collectionWidget)
        ControlCenter.shared.reloadControls(ofKind: SoundingSurfaceKind.playPauseControl)
        #endif
    }
}
