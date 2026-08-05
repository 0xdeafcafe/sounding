import AppIntents
import Foundation

enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notEntitled
    case notFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notEntitled:
            return "That isn't available to play right now — it may need SoundCloud Go+, or it's no longer accessible."
        case .notFound:
            return "Couldn't find that on SoundCloud."
        }
    }
}

struct PlayTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Track"
    static let description = IntentDescription("Plays a track in SoundingCloud.")
    static let openAppWhenRun = false

    @Parameter(title: "Track")
    var track: Track

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$track)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let fresh = try? await SoundCloudAPI.shared.getTrack(id: track.id) else {
            throw PlaybackIntentError.notFound
        }
        guard fresh.streamURL != nil else {
            throw PlaybackIntentError.notEntitled
        }
        await PlayerService.shared.play(fresh, in: [fresh])
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist in SoundingCloud.")
    static let openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: Playlist

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let fresh = try? await SoundCloudAPI.shared.getPlaylist(id: playlist.id) else {
            throw PlaybackIntentError.notFound
        }

        let allIDs = fresh.trackIDs ?? fresh.loadedTracks.map(\.id)
        let hydrated = (try? await SoundCloudAPI.shared.getPlaylistTracks(fresh, ids: allIDs)) ?? fresh.loadedTracks
        let playable = hydrated.filter { $0.streamURL != nil }

        guard let first = playable.first else {
            throw PlaybackIntentError.notEntitled
        }
        await PlayerService.shared.play(first, in: playable)
        return .result()
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays an artist's tracks in SoundingCloud.")
    static let openAppWhenRun = false

    @Parameter(title: "Artist")
    var artist: User

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let page = try? await SoundCloudAPI.shared.getUserTracks(userId: artist.id, limit: 50) else {
            throw PlaybackIntentError.notFound
        }
        let playable = page.collection.filter { $0.streamURL != nil }
        guard let first = playable.first else {
            throw PlaybackIntentError.notEntitled
        }
        await PlayerService.shared.play(first, in: playable)
        return .result()
    }
}

struct SoundingCloudShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: [
                "Play \(\.$track) in \(.applicationName)",
                "Play \(\.$track) on \(.applicationName)",
            ],
            shortTitle: "Play Track",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play \(\.$playlist) on \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play \(\.$artist) in \(.applicationName)",
                "Play \(\.$artist) on \(.applicationName)",
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )
    }
}
