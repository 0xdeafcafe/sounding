import AppIntents
import Foundation
#if os(iOS) || os(macOS)
import CoreSpotlight
#endif

struct TrackEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Track")
    }

    static let defaultQuery = TrackEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Artist")
    var artistName: String

    @Property(title: "Link")
    var permalinkURL: URL?

    let artistID: String?
    let artworkURL: URL?
    let durationSeconds: TimeInterval?
    var keywords: [String] = []

    init(
        id: String,
        title: String,
        artistName: String,
        artistID: String? = nil,
        artworkURL: URL? = nil,
        permalinkURL: URL? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.artistID = artistID
        self.artworkURL = artworkURL
        self.durationSeconds = durationSeconds
        self.title = title
        self.artistName = artistName
        self.permalinkURL = permalinkURL
    }

    init(_ track: Track) {
        self.init(
            id: track.id,
            title: track.title,
            artistName: track.user.displayName,
            artistID: track.user.id,
            artworkURL: track.largeArtworkURL ?? track.artworkURL,
            permalinkURL: track.permalinkURL,
            durationSeconds: track.duration > 0 ? track.duration : nil
        )
        keywords = ([track.genre].compactMap { $0 } + track.tags).filter { !$0.isEmpty }
    }

    init?(_ item: SoundingSnapshot.Item) {
        guard item.kind == .track else { return nil }
        self.init(
            id: item.id,
            title: item.title,
            artistName: item.subtitle,
            artworkURL: item.artworkURL,
            durationSeconds: item.duration
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

struct ArtistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Artist")
    }

    static let defaultQuery = ArtistEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Username")
    var username: String

    @Property(title: "Link")
    var permalinkURL: URL?

    let avatarURL: URL?

    init(id: String, name: String, username: String, avatarURL: URL? = nil, permalinkURL: URL? = nil) {
        self.id = id
        self.avatarURL = avatarURL
        self.name = name
        self.username = username
        self.permalinkURL = permalinkURL
    }

    init(_ user: User) {
        self.init(
            id: user.id,
            name: user.displayName,
            username: user.username,
            avatarURL: user.largeAvatarURL ?? user.avatarURL,
            permalinkURL: user.permalinkURL
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: username.isEmpty || username == name ? nil : "@\(username)",
            image: avatarURL.map { .init(url: $0) }
        )
    }
}

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist")
    }

    static let defaultQuery = PlaylistEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Owner")
    var ownerName: String

    @Property(title: "Track Count")
    var trackCount: Int

    @Property(title: "Album")
    var isAlbum: Bool

    @Property(title: "Link")
    var permalinkURL: URL?

    let ownerID: String?
    let artworkURL: URL?

    init(
        id: String,
        title: String,
        ownerName: String,
        ownerID: String? = nil,
        trackCount: Int = 0,
        isAlbum: Bool = false,
        artworkURL: URL? = nil,
        permalinkURL: URL? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.artworkURL = artworkURL
        self.title = title
        self.ownerName = ownerName
        self.trackCount = trackCount
        self.isAlbum = isAlbum
        self.permalinkURL = permalinkURL
    }

    init(_ playlist: Playlist) {
        self.init(
            id: playlist.id,
            title: playlist.title,
            ownerName: playlist.user.displayName,
            ownerID: playlist.user.id,
            trackCount: playlist.totalTrackCount,
            isAlbum: playlist.isAlbum,
            artworkURL: playlist.largeDisplayArtworkURL ?? playlist.displayArtworkURL,
            permalinkURL: playlist.permalinkURL
        )
    }

    static func likes(trackCount: Int) -> PlaylistEntity {
        PlaylistEntity(id: MediaTarget.likesID, title: "Likes", ownerName: "", trackCount: trackCount)
    }

    var isLikes: Bool { id == MediaTarget.likesID }

    var displayRepresentation: DisplayRepresentation {
        let count: LocalizedStringResource = trackCount == 1 ? "1 track" : "\(trackCount) tracks"
        if isLikes {
            return DisplayRepresentation(title: "Likes", subtitle: trackCount > 0 ? count : nil, image: .init(systemName: "heart.fill"))
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: ownerName.isEmpty ? count : "\(ownerName) · \(count)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

struct SetlistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Setlist")
    }

    static let defaultQuery = SetlistEntityQuery()

    let id: String

    @Property(title: "Mix")
    var title: String

    @Property(title: "Entries")
    var entryCount: Int

    let durationSeconds: TimeInterval
    let updatedAt: Date
    let entryLabels: [String]

    init(id: String, title: String, entryLabels: [String], durationSeconds: TimeInterval, updatedAt: Date) {
        self.id = id
        self.entryLabels = entryLabels
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
        self.title = title
        self.entryCount = entryLabels.count
    }

    init(_ setlist: GeneratedSetlist) {
        self.init(
            id: setlist.trackId,
            title: SetlistText.normalized(setlist.trackTitle),
            entryLabels: setlist.activeSegments.map(\.displayLabel),
            durationSeconds: setlist.duration,
            updatedAt: setlist.updatedAt
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: entryCount == 1 ? "1 track" : "\(entryCount) tracks"
        )
    }
}

// MARK: - Queries

struct TrackEntityQuery: EntityQuery, EntityStringQuery {
    var catalog: any SoundingEntityCatalog

    init() { catalog = LiveSoundingEntityCatalog() }
    init(catalog: any SoundingEntityCatalog) { self.catalog = catalog }

    func entities(for identifiers: [TrackEntity.ID]) async throws -> [TrackEntity] {
        try await catalog.tracks(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [TrackEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await catalog.searchTracks(matching: query)
    }

    func suggestedEntities() async throws -> [TrackEntity] {
        try await catalog.suggestedTracks()
    }
}

struct ArtistEntityQuery: EntityQuery, EntityStringQuery {
    var catalog: any SoundingEntityCatalog

    init() { catalog = LiveSoundingEntityCatalog() }
    init(catalog: any SoundingEntityCatalog) { self.catalog = catalog }

    func entities(for identifiers: [ArtistEntity.ID]) async throws -> [ArtistEntity] {
        try await catalog.artists(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await catalog.searchArtists(matching: query)
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        try await catalog.suggestedArtists()
    }
}

struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {
    var catalog: any SoundingEntityCatalog

    init() { catalog = LiveSoundingEntityCatalog() }
    init(catalog: any SoundingEntityCatalog) { self.catalog = catalog }

    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        try await catalog.playlists(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await catalog.searchPlaylists(matching: query)
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await catalog.suggestedPlaylists()
    }
}

struct SetlistEntityQuery: EntityQuery, EntityStringQuery {
    var catalog: any SoundingEntityCatalog

    init() { catalog = LiveSoundingEntityCatalog() }
    init(catalog: any SoundingEntityCatalog) { self.catalog = catalog }

    func entities(for identifiers: [SetlistEntity.ID]) async throws -> [SetlistEntity] {
        try await catalog.setlists(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [SetlistEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await catalog.searchSetlists(matching: query)
    }

    func suggestedEntities() async throws -> [SetlistEntity] {
        try await catalog.suggestedSetlists()
    }
}

// MARK: - Spotlight

#if os(iOS) || os(macOS)
extension TrackEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .audio)
        set.title = title
        set.artist = artistName
        set.contentDescription = artistName
        if let durationSeconds {
            set.duration = NSNumber(value: durationSeconds)
            if CollectionKind.classify(trackDurationSeconds: durationSeconds) == .set {
                set.keywords = ["Set", "Mix", "DJ Set"]
            }
        }
        if !keywords.isEmpty {
            set.keywords = (set.keywords ?? []) + keywords
        }
        set.thumbnailURL = artworkURL
        set.contentURL = permalinkURL
        return set
    }
}

extension ArtistEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .item)
        set.title = name
        set.contentDescription = username.isEmpty ? nil : "@\(username)"
        set.thumbnailURL = avatarURL
        set.contentURL = permalinkURL
        return set
    }
}

extension PlaylistEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .audio)
        set.title = title
        if isLikes {
            set.contentDescription = trackCount == 1 ? "1 liked track" : "\(trackCount) liked tracks"
            set.keywords = ["Likes", "Liked Tracks", "Favourites", "Library"]
            return set
        }
        set.artist = ownerName
        set.contentDescription = trackCount == 1 ? "1 track by \(ownerName)" : "\(trackCount) tracks by \(ownerName)"
        set.thumbnailURL = artworkURL
        set.contentURL = permalinkURL
        return set
    }
}

extension SetlistEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = title
        set.contentDescription = entryLabels.prefix(12).joined(separator: " · ")
        set.keywords = Array(entryLabels.prefix(40))
        set.duration = NSNumber(value: durationSeconds)
        return set
    }
}
#endif
