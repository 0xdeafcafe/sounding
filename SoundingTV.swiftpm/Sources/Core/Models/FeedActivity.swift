import Foundation

struct FeedActivity: Identifiable, Codable {

    enum Kind: String, Codable {
        case track
        case trackRepost = "track-repost"
        case playlist
        case playlistRepost = "playlist-repost"
        case trackPromoted = "track-promoted"
        case playlistPromoted = "playlist-promoted"
    }

    let kind: Kind
    let createdAt: Date

    let actor: User
    let uuid: String?
    let caption: String?
    let track: Track?
    let playlist: Playlist?
    let promoted: PromotedContent?

    var isRepost: Bool {
        switch kind {
        case .trackRepost, .playlistRepost: return true
        case .track, .playlist, .trackPromoted, .playlistPromoted: return false
        }
    }

    var isPromoted: Bool {
        kind == .trackPromoted || kind == .playlistPromoted || promoted != nil
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
        case uuid, caption, track, playlist, promoted, promoter
    }

    init(
        kind: Kind, createdAt: Date, actor: User, uuid: String?, caption: String?,
        track: Track?, playlist: Playlist?, promoted: PromotedContent? = nil
    ) {
        self.kind = kind
        self.createdAt = createdAt
        self.actor = actor
        self.uuid = uuid
        self.caption = caption
        self.track = track
        self.playlist = playlist
        self.promoted = promoted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        kind = try container.decode(Kind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        track = try container.decodeIfPresent(Track.self, forKey: .track)
        playlist = try container.decodeIfPresent(Playlist.self, forKey: .playlist)
        let decodedPromoted = (try? container.decodeIfPresent(PromotedContent.self, forKey: .promoted)) ?? nil
        let topLevelPromoter = (try? container.decodeIfPresent(User.self, forKey: .promoter)) ?? nil
        if let decodedPromoted, decodedPromoted.promoter == nil, let topLevelPromoter {
            promoted = PromotedContent(adURN: decodedPromoted.adURN, promoter: topLevelPromoter, tracking: decodedPromoted.tracking)
        } else if decodedPromoted == nil, kind == .trackPromoted || kind == .playlistPromoted {
            promoted = PromotedContent(adURN: nil, promoter: topLevelPromoter, tracking: [:])
        } else {
            promoted = decodedPromoted
        }
        if let user = try container.decodeIfPresent(User.self, forKey: .actor) {
            actor = user
        } else if let owner = topLevelPromoter ?? track?.user ?? playlist?.user {
            actor = owner
        } else {
            actor = try container.decode(User.self, forKey: .actor)
        }

        switch kind {
        case .track, .trackRepost, .trackPromoted:
            guard track != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .track, in: container,
                    debugDescription: "kind=\(kind.rawValue) but no track payload"
                )
            }
        case .playlist, .playlistRepost, .playlistPromoted:
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
        try container.encodeIfPresent(promoted, forKey: .promoted)
    }
}
