import Foundation
import CoreGraphics
import MediaPlayer

struct SystemNowPlayingItem: Equatable {
    let trackId: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let queueIndex: Int?
    let queueCount: Int?
}

struct SystemPlaybackStatus: Equatable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
}

struct SystemTransportHandlers {
    let play: @MainActor () -> Void
    let pause: @MainActor () -> Void
    let togglePlayPause: @MainActor () -> Void
    let next: @MainActor () async -> Void
    let previous: @MainActor () async -> Void
    let seek: @MainActor (TimeInterval) -> Void
}

@MainActor
protocol NowPlayingArtworkProvider: AnyObject {
    func artwork(for cgImage: CGImage) -> MPMediaItemArtwork
}

@MainActor
protocol SystemNowPlayingBridge: AnyObject {
    func activate(handlers: SystemTransportHandlers)
    func deactivate()
    func publishNowPlaying(_ item: SystemNowPlayingItem?)
    func publishPlayback(_ playback: SystemPlaybackStatus)
    func publishTransportAvailability(hasNext: Bool)
}

extension SystemNowPlayingBridge {
    func publishTransportAvailability(hasNext: Bool) {}
}

@MainActor
final class MediaPlayerNowPlayingBridge: SystemNowPlayingBridge {
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var currentItem: SystemNowPlayingItem?
    private var isActive = false
    private var publishedIsPlaying: Bool?
    private var publishedDuration: TimeInterval = 0
    private var anchorElapsed: TimeInterval = 0
    private var anchorDate = Date.distantPast
    weak var artworkProvider: (any NowPlayingArtworkProvider)?

    func activate(handlers: SystemTransportHandlers) {
        isActive = true
        removeCommandTargets()
        let center = MPRemoteCommandCenter.shared()

        commandTargets.append((center.playCommand, center.playCommand.addTarget { _ in
            Task { @MainActor in handlers.play() }
            return .success
        }))
        commandTargets.append((center.pauseCommand, center.pauseCommand.addTarget { _ in
            Task { @MainActor in handlers.pause() }
            return .success
        }))
        commandTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in handlers.togglePlayPause() }
            return .success
        }))
        commandTargets.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in await handlers.next() }
            return .success
        }))
        commandTargets.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in await handlers.previous() }
            return .success
        }))
        commandTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in handlers.seek(event.positionTime) }
            return .success
        }))
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeCommandTargets()
        artworkTask?.cancel()
        artworkTask = nil
        currentItem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func removeCommandTargets() {
        for (command, token) in commandTargets {
            command.removeTarget(token)
        }
        commandTargets.removeAll()
    }

    func publishNowPlaying(_ item: SystemNowPlayingItem?) {
        artworkTask?.cancel()
        artworkTask = nil
        currentItem = item
        publishedIsPlaying = nil
        publishedDuration = 0

        guard let item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.artist
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let queueIndex = item.queueIndex, let queueCount = item.queueCount {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let artworkURL = item.artworkURL, let artworkProvider = artworkProvider else { return }
        let trackId = item.trackId
        artworkTask = Task { @MainActor [weak self] in
            guard let cgImage = await SCArtworkStore.shared.cgImage(for: artworkURL, variant: .standard),
                  !Task.isCancelled,
                  self?.currentItem?.trackId == trackId else { return }

            let artwork = artworkProvider.artwork(for: cgImage)
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            updated[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    func publishTransportAvailability(hasNext: Bool) {
        guard isActive else { return }
        let command = MPRemoteCommandCenter.shared().nextTrackCommand
        if command.isEnabled != hasNext { command.isEnabled = hasNext }
    }

    func publishPlayback(_ playback: SystemPlaybackStatus) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        // Skip the XPC write when nothing observable changed: while playing,
        // mediaserverd extrapolates elapsed time from the rate itself, so a
        // sub-second drift from the last anchor does not need a rewrite.
        if publishedIsPlaying == playback.isPlaying,
           abs(playback.duration - publishedDuration) <= 1 {
            let predicted = playback.isPlaying
                ? anchorElapsed + Date().timeIntervalSince(anchorDate)
                : anchorElapsed
            if abs(predicted - playback.elapsed) < 1 { return }
        }
        publishedIsPlaying = playback.isPlaying
        publishedDuration = playback.duration
        anchorElapsed = playback.elapsed
        anchorDate = Date()

        // NaN (e.g. from an invalid CMTime) raises an uncatchable
        // NSInvalidArgumentException inside MediaPlayer.
        let elapsed = playback.elapsed.isFinite ? max(0, playback.elapsed) : 0
        let duration = playback.duration.isFinite ? max(0, playback.duration) : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = playback.isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
