import Foundation
import Combine

@MainActor
final class SoundingPageLinkRouter: ObservableObject {
    enum Page {
        case artist(User)
        case playlist(Playlist)
        case track(Track)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let page: Page

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    static let shared = SoundingPageLinkRouter()
    static let host = "open-page"

    @Published var pending: Request?

    private var resolving: Task<Void, Never>?

    private init() {}

    static func source(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == SoundingWidgetLink.scheme,
              url.host?.lowercased() == host,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let source = URL(string: raw),
              source.scheme?.lowercased() == "https",
              let sourceHost = source.host?.lowercased(),
              sourceHost == "soundcloud.com" || sourceHost.hasSuffix(".soundcloud.com") else { return nil }
        return source
    }

    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == SoundingWidgetLink.scheme, url.host?.lowercased() == host else { return false }
        guard let source = source(from: url) else { return true }
        shared.open(source)
        return true
    }

    func open(_ source: URL) {
        resolving?.cancel()
        resolving = Task {
            guard let resolved = try? await SoundCloudAPI.shared.resolve(url: source), !Task.isCancelled else { return }
            switch resolved {
            case .user(let user): pending = Request(page: .artist(user))
            case .playlist(let playlist): pending = Request(page: .playlist(playlist))
            case .track(let track): pending = Request(page: .track(track))
            }
        }
    }

    func take(_ request: Request) -> Page? {
        guard pending == request else { return nil }
        pending = nil
        return request.page
    }
}

@MainActor
enum WidgetLinkRouter {
    static func handle(_ url: URL) -> Bool {
        if SoundingPageLinkRouter.handle(url) { return true }
        guard let link = SoundingWidgetLink(url: url) else { return false }
        switch link {
        case .nowPlaying:
            break
        case .play(let kind, let id, let position):
            Task { try? await play(kind: kind, id: id, position: position) }
        case .open(let source, let placement):
            Task { try? await open(source, placement: placement) }
        }
        return true
    }

    static func play(kind: SoundingSnapshot.ItemKind, id: String, position: TimeInterval) async throws {
        switch kind {
        case .track, .setlist:
            if PlayerService.shared.currentTrack?.id == id {
                try await PlaybackControlBridge.setPlaying(true)
            } else {
                try await IntentPlayback.playTrack(id: id, startingAt: position)
            }
        case .playlist:
            try await IntentPlayback.playPlaylist(id: id)
        case .artist:
            try await IntentPlayback.playArtist(id: id)
        }
    }

    static func open(_ source: URL, placement: SoundingWidgetLink.Placement) async throws {
        let resolved = try await SoundCloudAPI.shared.resolve(url: source)
        guard placement != .now else {
            switch resolved {
            case .track(let track):
                try await IntentPlayback.playTrack(id: track.id)
            case .playlist(let playlist):
                try await IntentPlayback.playPlaylist(id: playlist.id)
            case .user(let user):
                try await IntentPlayback.playArtist(id: user.id)
            }
            return
        }

        let tracks: [Track]
        switch resolved {
        case .track(let track):
            tracks = [track]
        case .playlist(let playlist):
            tracks = try await IntentPlayback.source.playlistTracks(id: playlist.id)
        case .user(let user):
            tracks = try await IntentPlayback.source.artistTracks(id: user.id, limit: IntentPlayback.artistQueueLimit)
        }
        let playable = tracks.filter { IntentPlayback.source.isPlayable($0) }
        guard let first = playable.first else { throw PlaybackIntentError.notEntitled }

        guard PlayerService.shared.currentTrack != nil || (IntentPlayback.sink as? OutputRouter)?.isRemote == true else {
            if let message = await IntentPlayback.sink.play(first, in: playable, collectionId: nil) {
                throw PlaybackIntentError.refused(message)
            }
            return
        }

        let router = IntentPlayback.sink as? OutputRouter
        switch placement {
        case .next:
            for track in playable.reversed() {
                if let router {
                    router.playNext(track)
                } else {
                    PlayerService.shared.insertIntoQueue(track, at: PlayerService.shared.currentIndex + 1)
                }
            }
        case .last, .now:
            for track in playable {
                if let router {
                    router.addToQueue(track)
                } else {
                    PlayerService.shared.addToQueue(track)
                }
            }
        }
    }
}
