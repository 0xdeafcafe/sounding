import AppIntents
import Foundation

enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notEntitled
    case notFound
    case signedOut
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notEntitled:
            return "That isn't available to play right now — it may need SoundCloud Go+, or it's no longer accessible."
        case .notFound:
            return "Couldn't find that on SoundCloud."
        case .signedOut:
            return "Open Sounding and sign in to SoundCloud first."
        case .refused(let message):
            return "\(message)"
        }
    }
}

@MainActor
protocol IntentPlaybackSink: AnyObject {
    func play(_ track: Track, in context: [Track], collectionId: String?) async -> String?
    func play(shuffled tracks: [Track], collectionId: String?) async -> String?
}

@MainActor
final class LocalIntentPlaybackSink: IntentPlaybackSink {
    func play(_ track: Track, in context: [Track], collectionId: String?) async -> String? {
        await PlayerService.shared.play(track, in: context, collectionId: collectionId)
        return PlayerService.shared.playbackErrorMessage
    }

    func play(shuffled tracks: [Track], collectionId: String?) async -> String? {
        guard let start = tracks.randomElement() else { return "There's nothing to play." }
        PlayerService.shared.isShuffleEnabled = true
        await PlayerService.shared.play(start, in: tracks, collectionId: collectionId)
        return PlayerService.shared.playbackErrorMessage
    }
}

@MainActor
protocol IntentPlaybackSource: AnyObject {
    var isSignedIn: Bool { get }
    func likedTracks(limit: Int) async -> [Track]
    func track(id: String) async throws -> Track
    func playlistTracks(id: String) async throws -> [Track]
    func artistTracks(id: String, limit: Int) async throws -> [Track]
    func relatedTracks(seedTrackID: String, limit: Int) async throws -> [Track]
    func isPlayable(_ track: Track) -> Bool
}

@MainActor
final class SoundCloudIntentPlaybackSource: IntentPlaybackSource {
    private let local = DeviceLocalCatalog()

    var isSignedIn: Bool { SoundCloudAPI.credentials?.accessToken != nil }

    func likedTracks(limit: Int) async -> [Track] {
        let cached = await local.recentLikedTracks(limit: limit)
        guard cached.isEmpty else { return cached }
        return ((try? await SoundCloudAPI.shared.getLikedTracks(limit: 50))?.collection ?? []).map(\.item)
    }

    func track(id: String) async throws -> Track {
        if let cached = await local.likedTracks(ids: [id]).first, isPlayable(cached) {
            return cached
        }
        return try await SoundCloudAPI.shared.getTrack(id: id)
    }

    func playlistTracks(id: String) async throws -> [Track] {
        let playlist = try await SoundCloudAPI.shared.getPlaylist(id: id)
        let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        return (try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: ids)) ?? playlist.loadedTracks
    }

    func artistTracks(id: String, limit: Int) async throws -> [Track] {
        try await SoundCloudAPI.shared.getUserTracks(userId: id, limit: limit).collection
    }

    func relatedTracks(seedTrackID: String, limit: Int) async throws -> [Track] {
        try await SoundCloudAPI.shared.getRelatedTracks(trackID: seedTrackID, limit: limit).collection
    }

    func isPlayable(_ track: Track) -> Bool {
        track.streamURL != nil || PlayerService.shared.downloads.isLocallyAvailable(track)
    }
}

enum IntentPlayback {
    private static let minimumResumePosition: TimeInterval = 5
    static let likesQueueLimit = 500
    static let artistQueueLimit = 50
    static let stationQueueLimit = 30

    @MainActor static var sink: any IntentPlaybackSink = LocalIntentPlaybackSink()
    @MainActor static var source: any IntentPlaybackSource = SoundCloudIntentPlaybackSource()

    @MainActor
    static func play(_ request: MediaRequest, resolver: MediaRequestResolver = MediaRequestResolver()) async throws -> MediaResolution {
        try requireSignIn()
        let resolution = try await resolver.resolve(request)
        try await play(resolution)
        return resolution
    }

    @MainActor
    static func play(_ resolution: MediaResolution) async throws {
        switch resolution.target {
        case .likes:
            try await playLikes(shuffle: resolution.shuffle)
        case .track(let id):
            try await playTrack(id: id)
        case .playlist(let id):
            try await playPlaylist(id: id, shuffle: resolution.shuffle)
        case .artist(let id):
            try await playArtist(id: id, shuffle: resolution.shuffle)
        case .station(let seed):
            try await playStation(seedTrackID: seed)
        }
    }

    @MainActor
    static func playTrack(id: String, startingAt position: TimeInterval = 0) async throws {
        try requireSignIn()
        guard let track = try? await source.track(id: id) else { throw PlaybackIntentError.notFound }
        guard source.isPlayable(track) else { throw PlaybackIntentError.notEntitled }
        try await start(track, in: [track])
        if position >= minimumResumePosition {
            PlayerService.shared.seek(to: position, expectedTrackID: track.id)
        }
    }

    @MainActor
    static func playPlaylist(id: String, shuffle: Bool = false) async throws {
        if id == MediaTarget.likesID {
            try await playLikes(shuffle: shuffle)
            return
        }
        try requireSignIn()
        guard let tracks = try? await source.playlistTracks(id: id) else { throw PlaybackIntentError.notFound }
        try await start(tracks.filter { source.isPlayable($0) }, collectionId: id, shuffle: shuffle)
    }

    @MainActor
    static func playArtist(id: String, shuffle: Bool = false) async throws {
        try requireSignIn()
        guard let tracks = try? await source.artistTracks(id: id, limit: artistQueueLimit) else {
            throw PlaybackIntentError.notFound
        }
        try await start(tracks.filter { source.isPlayable($0) }, shuffle: shuffle)
    }

    @MainActor
    static func playLikes(shuffle: Bool) async throws {
        try requireSignIn()
        let likes = await source.likedTracks(limit: likesQueueLimit)
        guard !likes.isEmpty else { throw MediaRequestError.noLikes }
        try await start(likes.filter { source.isPlayable($0) }, collectionId: CollectionPolicyID.likedTracks, shuffle: shuffle)
    }

    @MainActor
    static func playStation(seedTrackID: String) async throws {
        try requireSignIn()
        guard let related = try? await source.relatedTracks(seedTrackID: seedTrackID, limit: stationQueueLimit) else {
            throw PlaybackIntentError.notFound
        }
        try await start(related.filter { $0.id != seedTrackID && source.isPlayable($0) })
    }

    @MainActor
    private static func requireSignIn() throws {
        guard source.isSignedIn else { throw PlaybackIntentError.signedOut }
    }

    @MainActor
    private static func start(_ tracks: [Track], collectionId: String? = nil, shuffle: Bool = false) async throws {
        guard let first = tracks.first else { throw PlaybackIntentError.notEntitled }
        if shuffle {
            if let message = await sink.play(shuffled: tracks, collectionId: collectionId) {
                throw PlaybackIntentError.refused(message)
            }
        } else {
            try await start(first, in: tracks, collectionId: collectionId)
        }
    }

    @MainActor
    private static func start(_ track: Track, in context: [Track], collectionId: String? = nil) async throws {
        if let message = await sink.play(track, in: context, collectionId: collectionId) {
            throw PlaybackIntentError.refused(message)
        }
    }
}

// MARK: - Intents

struct PlayTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Track"
    static let description = IntentDescription("Plays a track in Sounding.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Track")
    var track: TrackEntity

    init() {}

    init(track: TrackEntity) {
        self.track = track
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$track)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentPlayback.playTrack(id: track.id)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist, or your Likes, in Sounding.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentPlayback.playPlaylist(id: playlist.id, shuffle: shuffle)
        return .result()
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays an artist's tracks in Sounding.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentPlayback.playArtist(id: artist.id)
        return .result()
    }
}

struct PlayLikesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Likes"
    static let description = IntentDescription("Plays your SoundCloud Likes in Sounding.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentPlayback.playLikes(shuffle: false)
        return .result()
    }
}

struct ShuffleLikesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Likes"
    static let description = IntentDescription("Shuffles your SoundCloud Likes in Sounding.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentPlayback.playLikes(shuffle: true)
        return .result()
    }
}

struct PlayLastLikedSetIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Last Liked Set"
    static let description = IntentDescription("Plays the set you liked most recently.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolution = try await IntentPlayback.play(MediaRequest(kind: .set, mine: true, order: .newest))
        return .result(dialog: "Playing \(resolution.title).")
    }
}

struct PlaySimilarIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Something Like This"
    static let description = IntentDescription("Plays tracks like the one that's playing.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentPlayback.play(MediaRequest(kind: .station))
        return .result()
    }
}

struct SoundingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayLikesIntent(),
            phrases: [
                "Play my likes in \(.applicationName)",
                "Play my likes on \(.applicationName)",
                "Play my liked tracks in \(.applicationName)",
                "Play my \(.applicationName) likes",
            ],
            shortTitle: "Play Likes",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleLikesIntent(),
            phrases: [
                "Shuffle my likes in \(.applicationName)",
                "Shuffle my likes on \(.applicationName)",
                "Shuffle my \(.applicationName) likes",
            ],
            shortTitle: "Shuffle Likes",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayLastLikedSetIntent(),
            phrases: [
                "Play the set I liked last in \(.applicationName)",
                "Play the set I liked last on \(.applicationName)",
                "Play my last liked set in \(.applicationName)",
                "Play my last liked set on \(.applicationName)",
            ],
            shortTitle: "Last Liked Set",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: PlaySimilarIntent(),
            phrases: [
                "Play something like this in \(.applicationName)",
                "Play something like this on \(.applicationName)",
                "Play more like this in \(.applicationName)",
                "Play more like this on \(.applicationName)",
            ],
            shortTitle: "Play Similar",
            systemImageName: "dot.radiowaves.left.and.right"
        )
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
        AppShortcut(
            intent: PartyModeIntent(),
            phrases: [
                "Start Party Mode in \(.applicationName)",
                "Party Mode in \(.applicationName)",
                "Start a party with \(.applicationName)",
            ],
            shortTitle: "Party Mode",
            systemImageName: "party.popper"
        )
        AppShortcut(
            intent: WindDownIntent(),
            phrases: [
                "Wind down with \(.applicationName)",
                "Wind down in \(.applicationName)",
            ],
            shortTitle: "Wind Down",
            systemImageName: "moon.zzz"
        )
        #if os(iOS) || os(macOS)
        AppShortcut(
            intent: IdentifySongIntent(),
            phrases: [
                "Identify this song with \(.applicationName)",
                "Identify this song in \(.applicationName)",
                "What's this song in \(.applicationName)",
                "Name this song with \(.applicationName)",
            ],
            shortTitle: "Identify Song",
            systemImageName: "shazam.logo"
        )
        #endif
    }
}
