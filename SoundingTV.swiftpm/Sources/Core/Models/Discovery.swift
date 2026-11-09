import Foundation

enum DiscoveryEntry: Identifiable, Equatable, Codable {
    case playlist(Playlist)
    case station(SystemPlaylist)
    case user(User)

    var id: String {
        switch self {
        case .playlist(let playlist): return playlist.id
        case .station(let station): return station.id
        case .user(let user): return "user:\(user.id)"
        }
    }

    var artIdentity: String {
        switch self {
        case .user(let user): return user.id
        default: return id
        }
    }

    var cardTitle: String {
        switch self {
        case .playlist(let playlist): return playlist.title
        case .station(let station): return station.shortTitle?.nilIfEmpty ?? station.title
        case .user(let user): return user.displayName
        }
    }

    var cardSubtitle: String? {
        switch self {
        case .playlist(let playlist): return playlist.user.displayName
        case .station(let station): return station.shortDescription?.nilIfEmpty ?? station.description
        case .user(let user): return "\(user.formattedFollowers) followers"
        }
    }

    var artworkURL: URL? {
        switch self {
        case .playlist(let playlist): return playlist.largeDisplayArtworkURL
        case .station(let station): return station.artworkURL
        case .user(let user): return user.largeAvatarURL ?? user.avatarURL
        }
    }

    var crownUser: User? {
        switch self {
        case .playlist(let playlist): return playlist.user
        case .user(let user): return user
        case .station: return nil
        }
    }
}

struct DiscoveryShelf: Identifiable, Equatable, Codable {
    enum Content: Equatable, Codable {
        case tracks([Track])
        case playlists([Playlist])
        case stations([SystemPlaylist])
        case users([User])
        case mixed([DiscoveryEntry])
    }

    enum Kind: Equatable, Codable {
        case editorial
        case chartCollections
        case trending
        case related
        case station
        case recent
    }

    let id: String
    let title: String
    let subtitle: String?
    let kind: Kind
    let content: Content

    var count: Int {
        switch content {
        case .tracks(let tracks): return tracks.count
        case .playlists(let playlists): return playlists.count
        case .stations(let stations): return stations.count
        case .users(let users): return users.count
        case .mixed(let entries): return entries.count
        }
    }

    var isEmpty: Bool { count == 0 }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case unauthorized
    case forbidden
    case notFound
    case serverError(Int)
    case rateLimited(resetAt: Date?)
    case temporarilyBlocked(until: Date, statusCode: Int)
    case noStreamURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .decodingError(let error): return "Failed to parse response: \(error.localizedDescription)"
        case .unauthorized: return "Please sign in to continue"
        case .forbidden: return "SoundCloud did not allow this request"
        case .notFound: return "Content not found"
        case .serverError(let code): return "Server error: \(code)"
        case .rateLimited(let resetAt):
            if let resetAt { return "SoundCloud’s playback limit resets \(resetAt.formatted(date: .abbreviated, time: .shortened))." }
            return "SoundCloud’s playback limit has been reached. Try again later."
        case .temporarilyBlocked(let until, let statusCode):
            return "SoundCloud temporarily blocked requests (HTTP \(statusCode)). Waiting until \(until.formatted(date: .abbreviated, time: .shortened))."
        case .noStreamURL: return "Stream not available"
        }
    }
}

struct Selection: Identifiable, Codable {

    let id: String

    let title: String

    let description: String?

    let trackingFeatureName: String?

    let queryURN: String?

    let lastUpdated: Date?

    let items: Page<SelectionItem>

    var playlists: [Playlist] {
        items.collection.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } }
    }

    var stations: [SystemPlaylist] {
        items.collection.compactMap { if case .systemPlaylist(let s) = $0 { return s } else { return nil } }
    }

    var users: [User] {
        items.collection.compactMap { if case .user(let u) = $0 { return u } else { return nil } }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, items
        case trackingFeatureName = "tracking_feature_name"
        case queryURN = "query_urn"
        case lastUpdated = "last_updated"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        trackingFeatureName = try c.decodeIfPresent(String.self, forKey: .trackingFeatureName)
        queryURN = try c.decodeIfPresent(String.self, forKey: .queryURN)
        lastUpdated = (try? c.decodeIfPresent(Date.self, forKey: .lastUpdated)) ?? nil
        items = try c.decode(Page<SelectionItem>.self, forKey: .items)
    }

}

enum SelectionItem: Codable {
    case playlist(Playlist)
    case systemPlaylist(SystemPlaylist)
    case user(User)

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind)
        switch kind {
        case "playlist":
            self = .playlist(try Playlist(from: decoder))
        case "system-playlist":
            self = .systemPlaylist(try SystemPlaylist(from: decoder))
        case "user":
            self = .user(try User(from: decoder))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "SelectionItem: unrecognised kind \(kind.map { "\"\($0)\"" } ?? "<absent>")"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .playlist(let p): try p.encode(to: encoder)
        case .systemPlaylist(let s): try s.encode(to: encoder)
        case .user(let u): try u.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .playlist: try c.encode("playlist", forKey: .kind)
        case .systemPlaylist: try c.encode("system-playlist", forKey: .kind)
        case .user: try c.encode("user", forKey: .kind)
        }
    }
}

struct PlayHistoryItem: Identifiable, Codable {

    let playedAt: Date

    let trackID: String

    let track: Track

    var id: String { trackID }

    init(playedAt: Date, track: Track) {
        self.playedAt = playedAt
        self.trackID = track.id
        self.track = track
    }

    enum CodingKeys: String, CodingKey {
        case track
        case playedAt = "played_at"
        case trackID = "track_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let millis = try? c.decode(Int64.self, forKey: .playedAt) {
            playedAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        } else {
            playedAt = try c.decode(Date.self, forKey: .playedAt)
        }

        if let numeric = try? c.decode(Int64.self, forKey: .trackID) {
            trackID = String(numeric)
        } else {
            trackID = try c.decode(String.self, forKey: .trackID)
        }

        track = try c.decode(Track.self, forKey: .track)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Int64((playedAt.timeIntervalSince1970 * 1000).rounded()), forKey: .playedAt)
        if let numeric = Int64(trackID) {
            try c.encode(numeric, forKey: .trackID)
        } else {
            try c.encode(trackID, forKey: .trackID)
        }
        try c.encode(track, forKey: .track)
    }
}

struct SoundCloudTrackReferences: Decodable {
    let ids: [String]

    private struct Reference: Decodable {
        let id: String?

        enum CodingKeys: String, CodingKey { case id, urn }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let numeric = try? c.decode(Int64.self, forKey: .id) {
                id = String(numeric)
            } else if let urn = try? c.decode(String.self, forKey: .urn), let last = urn.split(separator: ":").last, Int64(last) != nil {
                id = String(last)
            } else {
                id = (try? c.decode(String.self, forKey: .id)).flatMap { Int64($0) != nil ? $0 : nil }
            }
        }
    }

    private enum PageKeys: String, CodingKey { case collection }

    init(from decoder: Decoder) throws {
        let references: [Reference]
        if let list = try? decoder.singleValueContainer().decode([Reference].self) {
            references = list
        } else {
            references = try decoder.container(keyedBy: PageKeys.self).decode([Reference].self, forKey: .collection)
        }
        var seen = Set<String>()
        ids = references.compactMap(\.id).filter { seen.insert($0).inserted }
    }
}

struct PlayHistoryContext: Identifiable, Codable {
    let playedAt: Date
    let entry: DiscoveryEntry

    var id: String { entry.id }

    init(playedAt: Date, entry: DiscoveryEntry) {
        self.playedAt = playedAt
        self.entry = entry
    }

    enum CodingKeys: String, CodingKey {
        case kind, user, station, playlist
        case playedAt = "played_at"
        case systemPlaylist = "system_playlist"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let millis = try? c.decode(Int64.self, forKey: .playedAt) {
            playedAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        } else {
            playedAt = try c.decode(Date.self, forKey: .playedAt)
        }
        let kind = (try? c.decodeIfPresent(String.self, forKey: .kind))?.lowercased() ?? ""
        let playlist = try? c.decodeIfPresent(Playlist.self, forKey: .playlist)
        let station = (try? c.decodeIfPresent(SystemPlaylist.self, forKey: .systemPlaylist))
            ?? (try? c.decodeIfPresent(SystemPlaylist.self, forKey: .station))
        let user = try? c.decodeIfPresent(User.self, forKey: .user)
        let wantsStation = kind.contains("station") || kind.contains("system")
        let wantsUser = kind == "user" || kind == "profile"
        if wantsStation, let station {
            entry = .station(station)
        } else if wantsUser, let user {
            entry = .user(user)
        } else if let playlist {
            entry = .playlist(playlist)
        } else if let station {
            entry = .station(station)
        } else if let user {
            entry = .user(user)
        } else {
            throw Self.missing(c, kind)
        }
    }

    private static func missing(_ c: KeyedDecodingContainer<CodingKeys>, _ kind: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: c.codingPath,
            debugDescription: "PlayHistoryContext: no playable object for kind \"\(kind)\""
        ))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Int64((playedAt.timeIntervalSince1970 * 1000).rounded()), forKey: .playedAt)
        switch entry {
        case .playlist(let playlist):
            try c.encode("playlist", forKey: .kind)
            try c.encode(playlist, forKey: .playlist)
        case .station(let station):
            try c.encode("system_playlist", forKey: .kind)
            try c.encode(station, forKey: .systemPlaylist)
        case .user(let user):
            try c.encode("user", forKey: .kind)
            try c.encode(user, forKey: .user)
        }
    }
}

struct ChartEntry: Identifiable, Codable {
    let score: Double
    let track: Track

    var id: String { track.id }
}

enum ChartGenre {
    static let allMusic = "soundcloud:genres:all-music"
}

enum ChartKind: String {
    case trending
    case top
}

struct SystemPlaylist: Identifiable, Codable, Hashable {

    let id: String

    let title: String

    let shortTitle: String?

    let description: String?

    let shortDescription: String?

    let artworkURL: URL?

    let playlistType: String?

    let permalinkURL: URL?

    let user: User?

    let seedURN: String?

    let likeCount: Int
    let isPublic: Bool

    let trackIDs: [String]

    var stationKind: StationKind {
        switch playlistType?.uppercased() {
        case "TRACK_STATION": return .track
        case "ARTIST_STATION": return .artist
        default:
            if id.contains(":track-stations:") { return .track }
            if id.contains(":artist-stations:") { return .artist }
            return .other
        }
    }

    enum StationKind { case track, artist, other }

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, urn, tracks
        case shortTitle = "short_title"
        case shortDescription = "short_description"
        case artworkURL = "artwork_url"
        case calculatedArtworkURL = "calculated_artwork_url"
        case playlistType = "playlist_type"
        case permalinkURL = "permalink_url"
        case likeCount = "likes_count"
        case isPublic = "is_public"
        case seed
    }

    private enum SeedKeys: String, CodingKey { case urn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let urn = try c.decodeIfPresent(String.self, forKey: .urn) {
            id = urn
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        title = try c.decode(String.self, forKey: .title)
        shortTitle = try c.decodeIfPresent(String.self, forKey: .shortTitle)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        shortDescription = try c.decodeIfPresent(String.self, forKey: .shortDescription)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .calculatedArtworkURL)
            ?? c.decodeIfPresent(URL.self, forKey: .artworkURL)
        playlistType = try c.decodeIfPresent(String.self, forKey: .playlistType)
        permalinkURL = try c.decodeIfPresent(URL.self, forKey: .permalinkURL)
        user = try c.decodeIfPresent(User.self, forKey: .user)
        likeCount = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? true

        if let seed = try? c.nestedContainer(keyedBy: SeedKeys.self, forKey: .seed) {
            seedURN = try? seed.decodeIfPresent(String.self, forKey: .urn)
        } else {
            seedURN = nil
        }

        trackIDs = (try? PlaylistTrackIDs(from: decoder))?.trackIDs ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .urn)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(shortTitle, forKey: .shortTitle)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(shortDescription, forKey: .shortDescription)
        try c.encodeIfPresent(artworkURL, forKey: .calculatedArtworkURL)
        try c.encodeIfPresent(playlistType, forKey: .playlistType)
        try c.encodeIfPresent(permalinkURL, forKey: .permalinkURL)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encode(likeCount, forKey: .likeCount)
        try c.encode(isPublic, forKey: .isPublic)

        if let seedURN {
            var seed = c.nestedContainer(keyedBy: SeedKeys.self, forKey: .seed)
            try seed.encode(seedURN, forKey: .urn)
        }

        if !trackIDs.isEmpty {
            var tracks = c.nestedUnkeyedContainer(forKey: .tracks)
            for identifier in trackIDs {
                var stub = tracks.nestedContainer(keyedBy: TrackStubKeys.self)
                if let numeric = Int(identifier) {
                    try stub.encode(numeric, forKey: .id)
                } else {
                    try stub.encode(identifier, forKey: .id)
                }
            }
        }
    }

    private enum TrackStubKeys: String, CodingKey { case id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: SystemPlaylist, rhs: SystemPlaylist) -> Bool { lhs.id == rhs.id }
}

struct DiscoverySourceFailure: Identifiable, Equatable {
    let id: String
    let reason: String

    let isCredentialRejection: Bool

    init(id: String, reason: String, isCredentialRejection: Bool = false) {
        self.id = id
        self.reason = Self.withoutQueryValues(reason)
        self.isCredentialRejection = isCredentialRejection
    }

    init(id: String, error: Error) {
        self.init(
            id: id,
            reason: String(describing: error),
            isCredentialRejection: Self.isCredentialShaped(error)
        )
    }

    static func isCredentialShaped(_ error: Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        return false
    }

    static func withoutQueryValues(_ text: String) -> String {
        guard text.contains("?") else { return text }
        return text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard token.contains("://"), let mark = token.firstIndex(of: "?") else { return token }
                let tail = token[mark...]
                guard let end = tail.firstIndex(where: { $0.isWhitespace }) else {
                    return token[token.startIndex..<mark] + "?<redacted>"
                }
                return token[token.startIndex..<mark] + "?<redacted>" + token[end...]
            }
            .joined(separator: " ")
    }
}
