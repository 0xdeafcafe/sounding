import Foundation

@MainActor
enum MacTransport {
    enum State {
        case stopped
        case playing
        case paused
    }

    static var track: Track? { MacNowPlayingModel.shared.track }

    static var isPlaying: Bool { MacPlaybackTimeline.shared.isPlaying }

    static var state: State {
        if isPlaying { return .playing }
        return track == nil ? .stopped : .paused
    }

    static var canLike: Bool { track?.supportsSoundCloudActions == true }

    static var isLiked: Bool {
        track.map { MacTrackEngagement.shared.isLiked($0) } ?? false
    }

    static func playPause() {
        let console = MacConsoleController.shared
        if console.isConsoleActive {
            console.togglePlayPause(console.focusedDeck)
        } else if let remote = MacPlaybackTarget.output {
            remote.togglePlayPause()
        } else if PlayerService.shared.currentTrack == nil {
            resume()
        } else {
            PlayerService.shared.togglePlayPause()
        }
    }

    static func play() {
        guard !isPlaying else { return }
        playPause()
    }

    static func pause() {
        guard isPlaying else { return }
        playPause()
    }

    static func next() {
        guard !MacConsoleController.shared.isConsoleActive else { return }
        MacPlayback.next()
    }

    static func previous() {
        guard !MacConsoleController.shared.isConsoleActive else { return }
        MacPlayback.previous()
    }

    static func toggleLike() {
        guard let track, track.supportsSoundCloudActions else { return }
        Task { await MacTrackEngagement.shared.toggleLike(track) }
    }

    static func play(recent item: SoundingSnapshot.Item) {
        Task { try? await WidgetLinkRouter.play(kind: item.kind, id: item.id, position: 0) }
    }

    static func recentTracks(limit: Int) -> [SoundingSnapshot.Item] {
        let current = track?.id
        return Array(
            SoundingSnapshotPublisher.shared.current.recents
                .filter { $0.kind == .track && $0.id != current }
                .prefix(limit)
        )
    }

    private static func resume() {
        Task { try? await PlaybackControlBridge.setPlaying(true) }
    }
}
