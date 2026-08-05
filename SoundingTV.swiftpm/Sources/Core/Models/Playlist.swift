import Foundation

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkURL: URL?
    let permalinkURL: URL
    let duration: TimeInterval
    let trackCount: Int
    let likeCount: Int
    let repostCount: Int
    let userFavorite: Bool
    let userReposted: Bool
    let createdAt: Date
    let isAlbum: Bool
    let sharing: String
    let user: User

    let tracks: [Track]?

    let trackIDs: [String]?

    var urn: String { "soundcloud:playlists:\(id)" }

    var formattedDuration: String {
        let totalMinutes = Int(duration) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    var largeArtworkURL: URL? {
        guard let url = artworkURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t500x500"))
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, duration, user, tracks
        case artworkURL = "artwork_url"
        case permalinkURL = "permalink_url"
        case trackCount = "track_count"
        case likeCount = "likes_count"
        case repostCount = "reposts_count"
        case userFavorite = "user_favorite"
        case userReposted = "user_reposted"
        case createdAt = "created_at"
        case isAlbum = "is_album"
        case sharing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(Int.self, forKey: .id)
        id = String(rawID)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        permalinkURL = try container.decode(URL.self, forKey: .permalinkURL)
        duration = TimeInterval(try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0) / 1000
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        repostCount = try container.decodeIfPresent(Int.self, forKey: .repostCount) ?? 0
        userFavorite = try container.decodeIfPresent(Bool.self, forKey: .userFavorite) ?? false
        userReposted = try container.decodeIfPresent(Bool.self, forKey: .userReposted) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isAlbum = try container.decodeIfPresent(Bool.self, forKey: .isAlbum) ?? false
        sharing = try container.decodeIfPresent(String.self, forKey: .sharing) ?? "public"
        user = try container.decode(User.self, forKey: .user)

        if var elements = try? container.nestedUnkeyedContainer(forKey: .tracks) {
            let manifest = try PlaylistTracksDecoder.drain(&elements)
            tracks = manifest.tracks
            trackIDs = manifest.ids

            if manifest.ids.count != manifest.tracks.count || manifest.unreadableCount > 0 {
                let entryCount = manifest.ids.count
                let hydratedCount = manifest.tracks.count
                let unreadable = manifest.unreadableCount
                Log.api.info(
                    "Playlist \(rawID, privacy: .public): \(entryCount, privacy: .public) track entries, \(hydratedCount, privacy: .public) hydrated, \(entryCount - hydratedCount, privacy: .public) awaiting fetch by id, \(unreadable, privacy: .public) unreadable"
                )
            }
        } else {
            tracks = nil
            trackIDs = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(id), forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try container.encode(permalinkURL, forKey: .permalinkURL)
        try container.encode(Int(duration * 1000), forKey: .duration)
        try container.encode(trackCount, forKey: .trackCount)
        try container.encode(likeCount, forKey: .likeCount)
        try container.encode(repostCount, forKey: .repostCount)
        try container.encode(userFavorite, forKey: .userFavorite)
        try container.encode(userReposted, forKey: .userReposted)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isAlbum, forKey: .isAlbum)
        try container.encode(sharing, forKey: .sharing)
        try container.encode(user, forKey: .user)

        if let manifest = trackIDs {
            let hydrated = Dictionary(
                (tracks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            var nested = container.nestedUnkeyedContainer(forKey: .tracks)
            for trackID in manifest {
                if let track = hydrated[trackID] {
                    try nested.encode(track)
                } else {
                    try nested.encode(PlaylistTrackIDStub(id: trackID))
                }
            }
        } else {
            try container.encodeIfPresent(tracks, forKey: .tracks)
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id
    }
}

extension Playlist {

    var loadedTracks: [Track] { tracks ?? [] }

    var loadedTrackCount: Int { tracks?.count ?? 0 }

    var totalTrackCount: Int { trackIDs?.count ?? trackCount }

    var hasUnloadedTracks: Bool { totalTrackCount > loadedTrackCount }

    var unloadedTrackIDs: [String] {
        guard let trackIDs else { return [] }
        let hydrated = Set(loadedTracks.map(\.id))
        return trackIDs.filter { !hydrated.contains($0) }
    }
}

struct PlaylistTrackCursor {

    static let batchSize = 50

    let trackIDs: [String]

    private(set) var tracks: [Track] = []

    private(set) var offset: Int = 0

    private(set) var unavailableCount: Int = 0

    init(playlist: Playlist) {
        trackIDs = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
    }

    var totalCount: Int { trackIDs.count }

    var loadedCount: Int { tracks.count }

    var canLoadMore: Bool { offset < trackIDs.count }

    func nextBatch(size: Int = PlaylistTrackCursor.batchSize) -> [String] {
        guard canLoadMore, size > 0 else { return [] }
        return Array(trackIDs[offset..<Swift.min(offset + size, trackIDs.count)])
    }

    mutating func accept(_ fetched: [Track], for requested: [String]) {
        tracks.append(contentsOf: fetched)
        unavailableCount += Swift.max(0, requested.count - fetched.count)
        offset = Swift.min(offset + requested.count, trackIDs.count)
    }

    mutating func reset() {
        tracks = []
        offset = 0
        unavailableCount = 0
    }
}

private struct PlaylistTrackEntry: Decodable {
    let id: String?
    let track: Track?

    init(from decoder: Decoder) throws {
        id = (try? PageDecodeIDProbe(from: decoder))?.id
        track = try? Track(from: decoder)
    }
}

private struct PlaylistTrackIDEntry: Decodable {
    let id: String?

    init(from decoder: Decoder) throws {
        id = (try? PageDecodeIDProbe(from: decoder))?.id
    }
}

private enum PlaylistTracksDecoder {
    struct Manifest {
        var tracks: [Track] = []
        var ids: [String] = []
        var unreadableCount = 0
    }

    static func drain(_ elements: inout UnkeyedDecodingContainer) throws -> Manifest {
        var manifest = Manifest()
        while !elements.isAtEnd {
            let entry = try elements.decode(PlaylistTrackEntry.self)
            if let id = entry.id {
                manifest.ids.append(id)
            } else {
                manifest.unreadableCount += 1
            }
            if let track = entry.track {
                manifest.tracks.append(track)
            }
        }
        return manifest
    }

    static func drainIDs(_ elements: inout UnkeyedDecodingContainer) throws -> [String] {
        var ids: [String] = []
        while !elements.isAtEnd {
            if let id = try elements.decode(PlaylistTrackIDEntry.self).id {
                ids.append(id)
            }
        }
        return ids
    }
}

private struct PlaylistTrackIDStub: Encodable {
    let id: String

    enum CodingKeys: String, CodingKey { case id, kind }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let numeric = Int(id) {
            try container.encode(numeric, forKey: .id)
        } else {
            try container.encode(id, forKey: .id)
        }
        try container.encode("track", forKey: .kind)
    }
}

struct PlaylistTrackIDs: Decodable {
    let trackIDs: [String]

    private enum CodingKeys: String, CodingKey { case tracks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if var elements = try? container.nestedUnkeyedContainer(forKey: .tracks) {
            trackIDs = try PlaylistTracksDecoder.drainIDs(&elements)
        } else {
            trackIDs = []
        }
    }
}

private struct PageDecodeIDProbe: Decodable {
    let id: String?

    enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numeric = try? container.decode(Int.self, forKey: .id) {
            id = String(numeric)
        } else {
            id = try? container.decode(String.self, forKey: .id)
        }
    }
}

extension Page {
    init(collection: [T], nextHref: URL?, droppedCount: Int) {
        self.collection = collection
        self.nextHref = nextHref
        self.droppedCount = droppedCount
    }

    func map<U: Codable>(_ transform: (T) -> U) -> Page<U> {
        Page<U>(
            collection: collection.map(transform),
            nextHref: nextHref,
            droppedCount: droppedCount
        )
    }
}

struct Page<T: Codable>: Codable {
    var collection: [T]
    let nextHref: URL?

    let droppedCount: Int

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextHref = try container.decodeIfPresent(URL.self, forKey: .nextHref)

        var items: [T] = []
        var droppedIDs: [String] = []
        var dropped = 0

        var elements = try container.nestedUnkeyedContainer(forKey: .collection)
        while !elements.isAtEnd {
            let outcome = try elements.decode(DecodedElement<T>.self)
            switch outcome {
            case .success(let value):
                items.append(value)
            case .failure(let id, let description):
                dropped += 1
                if let id { droppedIDs.append(id) }
                Log.api.error(
                    "Page<\(String(describing: T.self), privacy: .public)>: dropped one element, id=\(id ?? "unknown", privacy: .public) — \(description, privacy: .public)"
                )
            }
        }

        if dropped > 0, items.isEmpty {
            let context = DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.collection],
                debugDescription: "Page<\(T.self)>: all \(dropped) element(s) in \"collection\" failed to "
                    + "decode; refusing to report a false-empty page. ids attempted: "
                    + "\(droppedIDs.isEmpty ? "none decoded" : droppedIDs.joined(separator: ", "))"
            )
            Log.api.error(
                "Page<\(String(describing: T.self), privacy: .public)>: all \(dropped, privacy: .public) element(s) failed — refusing to return a false-empty page"
            )
            throw DecodingError.dataCorrupted(context)
        }

        if dropped > 0 {
            Log.api.error(
                "Page<\(String(describing: T.self), privacy: .public)>: dropped \(dropped, privacy: .public) of \(dropped + items.count, privacy: .public) element(s); \(items.count, privacy: .public) survived in order. dropped ids: \(droppedIDs.joined(separator: ","), privacy: .public)"
            )
        }

        collection = items
        droppedCount = dropped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(collection, forKey: .collection)
        try container.encodeIfPresent(nextHref, forKey: .nextHref)
    }
}

extension Page: Sendable where T: Sendable {}

private enum DecodedElement<T: Decodable>: Decodable {
    case success(T)
    case failure(id: String?, description: String)

    init(from decoder: Decoder) throws {
        do {
            self = .success(try T(from: decoder))
        } catch {
            self = .failure(id: DecodedElement.probeID(decoder), description: String(describing: error))
        }
    }

    private static func probeID(_ decoder: Decoder) -> String? {
        (try? PageDecodeIDProbe(from: decoder))?.id
    }
}

struct ResilientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        var dropped = 0
        var droppedIDs: [String] = []

        while !container.isAtEnd {
            switch try container.decode(DecodedElement<Element>.self) {
            case .success(let value):
                items.append(value)
            case .failure(let id, let description):
                dropped += 1
                if let id { droppedIDs.append(id) }
                Log.api.error(
                    "ResilientArray<\(String(describing: Element.self), privacy: .public)>: dropped one element, id=\(id ?? "unknown", privacy: .public) — \(description, privacy: .public)"
                )
            }
        }

        elements = items
        droppedCount = dropped
    }
}

struct PageCursor<Element: Codable> {
    private(set) var lastPage: Page<Element>?

    private(set) var isExhausted = false

    var canLoadMore: Bool { !isExhausted && lastPage?.nextHref != nil }

    mutating func advance(to page: Page<Element>) {
        lastPage = page
        isExhausted = page.nextHref == nil
    }

    mutating func reset() {
        lastPage = nil
        isExhausted = false
    }
}

extension Array where Element: Identifiable {
    mutating func appendUnique(contentsOf newItems: [Element]) {
        var seen = Set(map(\.id))
        for item in newItems where seen.insert(item.id).inserted {
            append(item)
        }
    }

    func isNearEnd(_ item: Element, lead: Int) -> Bool {
        guard !isEmpty else { return false }
        return item.id == self[Swift.max(0, count - lead)].id
    }
}

struct Like<T: Codable>: Codable {
    let createdAt: Date
    let item: T

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case track, playlist, user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        if let track = try container.decodeIfPresent(T.self, forKey: .track) {
            item = track
        } else if let playlist = try container.decodeIfPresent(T.self, forKey: .playlist) {
            item = playlist
        } else if let user = try container.decodeIfPresent(T.self, forKey: .user) {
            item = user
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "No item found")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(item, forKey: .track)
    }
}

extension Like: Sendable where T: Sendable {}


enum CollectionKind: String {
    case set
    case playlist
    case track

    static let longFormThresholdSeconds: TimeInterval = 20 * 60

    static func classify(trackDurationSeconds: TimeInterval) -> CollectionKind {
        trackDurationSeconds >= longFormThresholdSeconds ? .set : .track
    }

    static func classify(playlist: Playlist) -> CollectionKind {
        guard playlist.trackCount > 0 else { return .playlist }
        let averageDuration = playlist.duration / Double(playlist.trackCount)
        return averageDuration >= longFormThresholdSeconds ? .set : .playlist
    }

    var displayName: String {
        switch self {
        case .set:      return "Set"
        case .playlist: return "Playlist"
        case .track:    return "Track"
        }
    }
}
