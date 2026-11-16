#if os(iOS) || os(macOS)
import AppIntents
import Foundation

// MARK: - Entities

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.song)
struct SongEntity {
    static let defaultQuery = SongEntityQuery()

    let id: String
    var title: String
    var artistName: String
    var composerName: String?
    var albumTitle: String?
    var artists: [AudioArtistEntity]
    var album: AlbumEntity?
    var composers: [AudioArtistEntity]
    var internationalStandardRecordingCode: String?

    let artworkURL: URL?

    init(_ track: TrackEntity) {
        id = track.id
        artworkURL = track.artworkURL
        title = track.title
        artistName = track.artistName
        composerName = nil
        albumTitle = nil
        artists = track.artistID.map { [AudioArtistEntity(id: $0, name: track.artistName)] } ?? []
        album = nil
        composers = []
        internationalStandardRecordingCode = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct SongEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SongEntity.ID]) async throws -> [SongEntity] {
        try await TrackEntityQuery().entities(for: identifiers).map(SongEntity.init)
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        try await TrackEntityQuery().entities(matching: string).map(SongEntity.init)
    }

    func suggestedEntities() async throws -> [SongEntity] {
        try await TrackEntityQuery().suggestedEntities().map(SongEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct AudioArtistEntity {
    static let defaultQuery = AudioArtistEntityQuery()

    let id: String
    var name: String

    let avatarURL: URL?

    init(id: String, name: String, avatarURL: URL? = nil) {
        self.id = id
        self.avatarURL = avatarURL
        self.name = name
    }

    init(_ artist: ArtistEntity) {
        self.init(id: artist.id, name: artist.name, avatarURL: artist.avatarURL)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: avatarURL.map { .init(url: $0) })
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [AudioArtistEntity.ID]) async throws -> [AudioArtistEntity] {
        try await ArtistEntityQuery().entities(for: identifiers).map(AudioArtistEntity.init)
    }

    func entities(matching string: String) async throws -> [AudioArtistEntity] {
        try await ArtistEntityQuery().entities(matching: string).map(AudioArtistEntity.init)
    }

    func suggestedEntities() async throws -> [AudioArtistEntity] {
        try await ArtistEntityQuery().suggestedEntities().map(AudioArtistEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum AudioPlaylistOwner {
    case name(String)
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct AudioPlaylistEntity {
    static let defaultQuery = AudioPlaylistEntityQuery()

    let id: String
    var title: String
    var owner: AudioPlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    let artworkURL: URL?

    init(_ playlist: PlaylistEntity, currentUserID: String?) {
        id = playlist.id
        artworkURL = playlist.artworkURL
        title = playlist.title
        owner = playlist.ownerName.isEmpty ? nil : .name(playlist.ownerName)
        createdByMe = playlist.isLikes ? true : currentUserID.map { $0 == playlist.ownerID }
        curatedForMe = playlist.isLikes ? true : nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: artworkURL.map { .init(url: $0) })
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct AudioPlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [AudioPlaylistEntity.ID]) async throws -> [AudioPlaylistEntity] {
        let me = await AudioSchemaSupport.currentUserID()
        return try await PlaylistEntityQuery().entities(for: identifiers).map { AudioPlaylistEntity($0, currentUserID: me) }
    }

    func entities(matching string: String) async throws -> [AudioPlaylistEntity] {
        let me = await AudioSchemaSupport.currentUserID()
        return try await PlaylistEntityQuery().entities(matching: string)
            .filter { !$0.isAlbum }
            .map { AudioPlaylistEntity($0, currentUserID: me) }
    }

    func suggestedEntities() async throws -> [AudioPlaylistEntity] {
        let me = await AudioSchemaSupport.currentUserID()
        return try await PlaylistEntityQuery().suggestedEntities()
            .filter { !$0.isAlbum }
            .map { AudioPlaylistEntity($0, currentUserID: me) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.album)
struct AlbumEntity {
    static let defaultQuery = AlbumEntityQuery()

    let id: String
    var title: String
    var artistName: String
    var artists: [AudioArtistEntity]
    var universalProductCode: String?

    let artworkURL: URL?

    init(_ playlist: PlaylistEntity) {
        id = playlist.id
        artworkURL = playlist.artworkURL
        title = playlist.title
        artistName = playlist.ownerName
        artists = playlist.ownerID.map { [AudioArtistEntity(id: $0, name: playlist.ownerName)] } ?? []
        universalProductCode = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct AlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [AlbumEntity.ID]) async throws -> [AlbumEntity] {
        try await PlaylistEntityQuery().entities(for: identifiers).map(AlbumEntity.init)
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        try await PlaylistEntityQuery().entities(matching: string).filter(\.isAlbum).map(AlbumEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult {
    static let defaultQuery = WarmupAudioQueueResultQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Sounding")
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct WarmupAudioQueueResultQuery: EntityStringQuery {
    func entities(for identifiers: [WarmupAudioQueueResult.ID]) async throws -> [WarmupAudioQueueResult] {
        identifiers.map(WarmupAudioQueueResult.init)
    }

    func entities(matching string: String) async throws -> [WarmupAudioQueueResult] {
        []
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum AudioItem {
    case song(SongEntity)
    case artist(AudioArtistEntity)
    case playlist(AudioPlaylistEntity)
    case album(AlbumEntity)
}

// MARK: - Enums

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum AudioPlaybackAttribute: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum AudioQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Play Last",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.affinityState)
enum AudioAffinityState: String {
    case like
    case dislike
    case unset

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .like: "Like",
        .dislike: "Dislike",
        .unset: "Unset",
    ]
}

// MARK: - Intents

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    var audioEntity: AudioItem
    var playbackAttributes: Set<AudioPlaybackAttribute>
    var warmupAudioQueueResult: WarmupAudioQueueResult?
    var queueLocation: AudioQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        if let queueLocation, case let .song(song) = audioEntity {
            try await AudioSchemaSupport.enqueue(trackID: song.id, at: queueLocation)
            return .result()
        }
        try await IntentPlayback.play(MediaResolution(
            target: audioEntity.mediaTarget,
            title: "",
            source: .search,
            shuffle: playbackAttributes.contains(.shuffle)
        ))
        AudioSchemaSupport.apply(playbackAttributes)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.createStation)
struct CreateStationIntent: AudioPlaybackIntent {
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentPlayback.play(MediaRequest(kind: .station))
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AudioItem {
    var mediaTarget: MediaTarget {
        switch self {
        case let .song(song): return .track(song.id)
        case let .artist(artist): return .artist(artist.id)
        case let .playlist(playlist): return playlist.id == MediaTarget.likesID ? .likes : .playlist(playlist.id)
        case let .album(album): return .playlist(album.id)
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToLibrary)
struct AddAudioToLibraryIntent {
    var audioEntity: AudioItem

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AudioSchemaSupport.setLiked(true, item: audioEntity)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddAudioToPlaylistIntent {
    var audioEntity: AudioItem
    var playlist: AudioPlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard case let .song(song) = audioEntity else {
            throw AudioSchemaError.unsupported
        }
        try await SoundCloudAPI.shared.addTrack(song.id, toPlaylist: playlist.id)
        return .result()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.updateAudioAffinity)
struct UpdateAudioAffinityIntent {
    var affinityState: AudioAffinityState
    var target: AudioItem

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AudioSchemaSupport.setLiked(affinityState == .like, item: target)
        return .result()
    }
}

// MARK: - Support

enum AudioSchemaError: Error, CustomLocalizedStringResourceConvertible {
    case unsupported

    var localizedStringResource: LocalizedStringResource {
        "Sounding can't do that with this item."
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum AudioSchemaSupport {
    @MainActor
    static func currentUserID() async -> String? {
        SoundCloudAPI.credentials?.currentUser?.id
    }

    @MainActor
    static func enqueue(trackID: String, at location: AudioQueueInsertionLocation) async throws {
        guard let track = try? await SoundCloudAPI.shared.getTrack(id: trackID) else {
            throw PlaybackIntentError.notFound
        }
        let player = PlayerService.shared
        guard player.currentTrack != nil else {
            try await IntentPlayback.playTrack(id: trackID)
            return
        }
        switch location {
        case .next:
            player.insertIntoQueue(track, at: player.currentIndex + 1)
        case .tail:
            player.addToQueue(track)
        }
    }

    @MainActor
    static func apply(_ attributes: Set<AudioPlaybackAttribute>) {
        let player = PlayerService.shared
        if attributes.contains(.repeat), player.repeatMode == .off {
            player.repeatMode = .all
        }
    }

    @MainActor
    static func noteNowPlaying(_ track: Track?) {
        Task {
            if let track {
                try? await RelevantEntities.shared.updateEntities(
                    [SongEntity(TrackEntity(track))],
                    for: .audio(.nowPlaying)
                )
            } else {
                try? await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
            }
        }
    }

    @MainActor
    static func setLiked(_ liked: Bool, item: AudioItem) async throws {
        switch item {
        case let .song(song):
            guard let track = try? await SoundCloudAPI.shared.getTrack(id: song.id) else {
                throw PlaybackIntentError.notFound
            }
            if liked {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
        case let .playlist(playlist):
            try await setPlaylistLiked(liked, id: playlist.id)
        case let .album(album):
            try await setPlaylistLiked(liked, id: album.id)
        case .artist:
            throw AudioSchemaError.unsupported
        }
    }

    @MainActor
    private static func setPlaylistLiked(_ liked: Bool, id: String) async throws {
        guard let playlist = try? await SoundCloudAPI.shared.getPlaylist(id: id) else {
            throw PlaybackIntentError.notFound
        }
        try await SoundCloudAPI.shared.setPlaylistLiked(liked, playlist: playlist)
    }
}
#endif
