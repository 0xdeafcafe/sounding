import Foundation
import CoreGraphics
import NowPlaying
import Observation

@Observable
@MainActor
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *)
final class MediaSessionMirror: MediaSessionRepresentable {
    let id = "red.forbes.sounding.mediasession"
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    var commands: [MediaCommand] = []
}

@MainActor
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *)
final class MediaSessionNowPlayingBridge: SystemNowPlayingBridge {
    private let mirror = MediaSessionMirror()
    private var session: MediaSession<MediaSessionMirror>?
    private var currentItem: SystemNowPlayingItem?
    private var publishedDuration: TimeInterval = 0
    private var publishedState: MediaPlaybackSnapshot.PlaybackState?
    private var anchorElapsed: TimeInterval = 0
    private var anchorDate = Date.distantPast
    private var primaryRequestTask: Task<Void, Never>?

    func activate(handlers: SystemTransportHandlers) {
        mirror.commands = Self.commands(dispatching: handlers)
        if session == nil {
            session = MediaSession(mirror)
        }
        #if DEBUG
        if let session {
            print("[NowPlaying] session id=\(session.id) canBecomePrimary=\(session.canBecomeApplicationPrimary) isPrimary=\(session.isApplicationPrimary)")
        }
        #endif
    }

    func deactivate() {
        primaryRequestTask?.cancel()
        primaryRequestTask = nil
        mirror.content = nil
        mirror.playbackSnapshot = nil
        mirror.commands = []
        currentItem = nil
        publishedState = nil
        publishedDuration = 0
        session = nil
    }

    func publishNowPlaying(_ item: SystemNowPlayingItem?) {
        currentItem = item
        publishedState = nil
        publishedDuration = 0
        primaryRequestTask?.cancel()
        primaryRequestTask = nil

        guard let item else {
            mirror.content = nil
            mirror.playbackSnapshot = nil
            return
        }

        mirror.content = Self.content(for: item, duration: 0)
        #if DEBUG
        print("[NowPlaying] published content: \(item.title)")
        #endif
        requestPrimaryIfNeeded()
    }

    func publishPlayback(_ playback: SystemPlaybackStatus) {
        guard let item = currentItem else { return }

        if abs(playback.duration - publishedDuration) > 1 {
            publishedDuration = playback.duration
            mirror.content = Self.content(for: item, duration: playback.duration)
        }

        let state: MediaPlaybackSnapshot.PlaybackState = playback.isPlaying ? .playing(rate: 1.0) : .paused
        if publishedState == state {
            let predicted = playback.isPlaying
                ? anchorElapsed + Date().timeIntervalSince(anchorDate)
                : anchorElapsed
            if abs(predicted - playback.elapsed) < 1 { return }
        }

        publishedState = state
        anchorElapsed = playback.elapsed
        anchorDate = Date()
        mirror.playbackSnapshot = MediaPlaybackSnapshot(
            state: state,
            defaultPlaybackRate: 1.0,
            elapsedTime: playback.elapsed,
            timestamp: anchorDate
        )
        #if DEBUG
        print("[NowPlaying] published snapshot: \(state) elapsed=\(String(format: "%.1f", playback.elapsed))")
        #endif
    }

    private func requestPrimaryIfNeeded() {
        guard let session,
              session.canBecomeApplicationPrimary,
              !session.isApplicationPrimary,
              primaryRequestTask == nil else { return }
        primaryRequestTask = Task { @MainActor [weak self] in
            guard let self, let session = self.session else { return }
            do {
                try await session.requestToBecomeApplicationPrimary()
                #if DEBUG
                print("[NowPlaying] application primary: \(session.isApplicationPrimary)")
                #endif
            } catch {
                #if DEBUG
                print("[NowPlaying] requestToBecomeApplicationPrimary failed: \(error)")
                #endif
            }
            self.primaryRequestTask = nil
        }
    }

    private static func commands(dispatching handlers: SystemTransportHandlers) -> [MediaCommand] {
        [
            .play { handlers.play() },
            .pause { handlers.pause() },
            .togglePlayPause { handlers.togglePlayPause() },
            .next { await handlers.next() },
            .previous { await handlers.previous() },
            .seekToPosition { position in handlers.seek(position) }
        ]
    }

    private static func content(for item: SystemNowPlayingItem, duration: TimeInterval) -> GenericContent {
        var artwork: Artwork?
        if let artworkURL = item.artworkURL {
            artwork = Artwork(id: "\(item.trackId)#\(artworkURL.absoluteString)") { requestedSize in
                #if DEBUG
                print("[NowPlaying] artwork requested at \(Int(requestedSize.width))x\(Int(requestedSize.height))")
                #endif
                _ = requestedSize
                guard let cgImage = await Self.artworkCGImage(for: artworkURL) else {
                    throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
                }
                return try ArtworkRepresentation(cgImage: cgImage)
            }
        }
        return GenericContent(
            id: item.trackId,
            title: item.title,
            subtitle: item.artist,
            type: .audio,
            duration: duration > 0 ? .finite(duration) : nil,
            artwork: artwork
        )
    }

    private static func artworkCGImage(for url: URL) async -> CGImage? {
        await SCArtworkStore.shared.cgImage(for: url, variant: .standard)
    }
}
