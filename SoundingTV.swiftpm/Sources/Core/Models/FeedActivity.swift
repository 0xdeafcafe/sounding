import Foundation

struct FeedActivity: Identifiable, Codable {

    enum Kind: String, Codable {
        case track
        case trackRepost = "track-repost"
        case playlist
        case playlistRepost = "playlist-repost"
    }

    let kind: Kind
    let createdAt: Date

    let actor: User
    let uuid: String?
    let caption: String?
    let track: Track?
    let playlist: Playlist?

    var isRepost: Bool {
        switch kind {
        case .trackRepost, .playlistRepost: return true
        case .track, .playlist: return false
        }
    }

    var id: String {
        if let uuid, !uuid.isEmpty { return uuid }
        let itemID = track?.id ?? playlist?.id ?? "unknown"
        return "\(kind.rawValue)-\(itemID)-\(Int(createdAt.timeIntervalSince1970))"
    }

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case createdAt = "created_at"
        case actor = "user"
        case uuid, caption, track, playlist
    }

    init(
        kind: Kind, createdAt: Date, actor: User, uuid: String?, caption: String?,
        track: Track?, playlist: Playlist?
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.actor = actor
        self.uuid = uuid
        self.caption = caption
        self.track = track
        self.playlist = playlist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        kind = try container.decode(Kind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        actor = try container.decode(User.self, forKey: .actor)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        track = try container.decodeIfPresent(Track.self, forKey: .track)
        playlist = try container.decodeIfPresent(Playlist.self, forKey: .playlist)

        switch kind {
        case .track, .trackRepost:
            guard track != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .track, in: container,
                    debugDescription: "kind=\(kind.rawValue) but no track payload"
                )
            }
        case .playlist, .playlistRepost:
            guard playlist != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .playlist, in: container,
                    debugDescription: "kind=\(kind.rawValue) but no playlist payload"
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(actor, forKey: .actor)
        try container.encodeIfPresent(uuid, forKey: .uuid)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(track, forKey: .track)
        try container.encodeIfPresent(playlist, forKey: .playlist)
    }
}
