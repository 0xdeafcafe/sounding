import Foundation

enum KyleCrownPosition: Equatable, Sendable {
    case none
    case leading
    case trailing

    static func resolve(user: User?, context: String? = nil) -> KyleCrownPosition {
        let candidates = [context, user?.displayName, user?.username, user?.permalink]
            .compactMap { $0 }
        let matches = candidates.filter { $0.kyleNormalized.contains("kylestarkey") }
        guard let identity = matches.first(where: { $0.lowercased().contains("b2b") }) ?? matches.first else {
            return .none
        }

        let lower = identity.lowercased()
        guard let kyle = lower.range(of: "kyle starkey") ?? lower.range(of: "kylestarkey"),
              let b2b = lower.range(of: "b2b") else {
            return .leading
        }
        return b2b.lowerBound < kyle.lowerBound ? .trailing : .leading
    }
}

private extension String {
    var kyleNormalized: String { lowercased().filter(\.isLetter) }
}

struct User: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let username: String
    let permalink: String
    let permalinkURL: URL
    let avatarURL: URL?
    let profileVisuals: SoundCloudProfileVisuals?
    let city: String?
    let country: String?
    let fullName: String?
    let description: String?
    let website: URL?
    let websiteTitle: String?
    let trackCount: Int
    let playlistCount: Int
    let followersCount: Int
    let followingsCount: Int
    let publicFavoritesCount: Int?
    let verified: Bool?
    let consumerSubscriptions: [ConsumerSubscription]?

    let consumerSubscription: ConsumerSubscription?

    let creatorSubscriptions: [CreatorSubscription]?
    let creatorSubscription: CreatorSubscription?

    let rawSubscriptionPayload: [String: JSONValue]?

    var urn: String { "soundcloud:users:\(id)" }

    var displayName: String {
        if let fullName, !fullName.isEmpty { return fullName }
        return username
    }

    var largeAvatarURL: URL? {
        guard let url = avatarURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t500x500"))
    }

    var artSeed: UInt64 { UInt64(id) ?? 0x534F_554E }

    static func customAvatar(_ url: URL?) -> URL? {
        guard let url, !url.absoluteString.contains("default_avatar") else { return nil }
        return url
    }

    var profileCoverURL: URL? {
        profileVisuals?.visuals.first(where: { $0.visualURL != nil })?.visualURL
    }

    var isArtist: Bool { trackCount > 0 }

    var kindLabel: String { isArtist ? "Artist" : "Profile" }

    var formattedFollowers: String {
        CompactCount.string(followersCount)
    }

    var formattedTracks: String {
        CompactCount.string(trackCount)
    }

    enum CodingKeys: String, CodingKey {
        case id, username, permalink, city, country, description, website
        case websiteTitle = "website_title"
        case permalinkURL = "permalink_url"
        case avatarURL = "avatar_url"
        case profileVisuals = "visuals"
        case fullName = "full_name"
        case trackCount = "track_count"
        case playlistCount = "playlist_count"
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case publicFavoritesCount = "public_favorites_count"
        case verified
        case consumerSubscriptions = "consumer_subscriptions"
        case consumerSubscription = "consumer_subscription"
        case creatorSubscriptions = "creator_subscriptions"
        case creatorSubscription = "creator_subscription"
    }

    static let subscriptionCodingKeys: [CodingKeys] = [
        .consumerSubscriptions, .consumerSubscription,
        .creatorSubscriptions, .creatorSubscription,
    ]

    init(
        id: String,
        username: String,
        permalink: String,
        permalinkURL: URL,
        avatarURL: URL? = nil,
        profileVisuals: SoundCloudProfileVisuals? = nil,
        city: String? = nil,
        country: String? = nil,
        fullName: String? = nil,
        description: String? = nil,
        website: URL? = nil,
        websiteTitle: String? = nil,
        trackCount: Int = 0,
        playlistCount: Int = 0,
        followersCount: Int = 0,
        followingsCount: Int = 0,
        publicFavoritesCount: Int? = nil,
        verified: Bool? = nil,
        consumerSubscriptions: [ConsumerSubscription]? = nil,
        consumerSubscription: ConsumerSubscription? = nil,
        creatorSubscriptions: [CreatorSubscription]? = nil,
        creatorSubscription: CreatorSubscription? = nil,
        rawSubscriptionPayload: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.username = username
        self.permalink = permalink
        self.permalinkURL = permalinkURL
        self.avatarURL = User.customAvatar(avatarURL)
        self.profileVisuals = profileVisuals
        self.city = city
        self.country = country
        self.fullName = fullName
        self.description = description
        self.website = website
        self.websiteTitle = websiteTitle
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        self.followersCount = followersCount
        self.followingsCount = followingsCount
        self.publicFavoritesCount = publicFavoritesCount
        self.verified = verified
        self.consumerSubscriptions = consumerSubscriptions
        self.consumerSubscription = consumerSubscription
        self.creatorSubscriptions = creatorSubscriptions
        self.creatorSubscription = creatorSubscription
        self.rawSubscriptionPayload = rawSubscriptionPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(Int.self, forKey: .id)
        id = String(rawID)
        username = try container.decode(String.self, forKey: .username)
        permalink = try container.decode(String.self, forKey: .permalink)
        permalinkURL = try container.decode(URL.self, forKey: .permalinkURL)
        avatarURL = User.customAvatar(try container.decodeIfPresent(URL.self, forKey: .avatarURL))
        profileVisuals = try container.decodeIfPresent(SoundCloudProfileVisuals.self, forKey: .profileVisuals)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        website = (try? container.decodeIfPresent(URL.self, forKey: .website)) ?? nil
        websiteTitle = try container.decodeIfPresent(String.self, forKey: .websiteTitle)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        playlistCount = try container.decodeIfPresent(Int.self, forKey: .playlistCount) ?? 0
        followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount) ?? 0
        followingsCount = try container.decodeIfPresent(Int.self, forKey: .followingsCount) ?? 0
        publicFavoritesCount = try container.decodeIfPresent(Int.self, forKey: .publicFavoritesCount)
        verified = try? container.decodeIfPresent(Bool.self, forKey: .verified)
        consumerSubscriptions = try container.decodeIfPresent([ConsumerSubscription].self, forKey: .consumerSubscriptions)
        consumerSubscription = try container.decodeIfPresent(ConsumerSubscription.self, forKey: .consumerSubscription)
        creatorSubscriptions = try container.decodeIfPresent([CreatorSubscription].self, forKey: .creatorSubscriptions)
        creatorSubscription = try container.decodeIfPresent(CreatorSubscription.self, forKey: .creatorSubscription)

        var raw: [String: JSONValue] = [:]
        for key in User.subscriptionCodingKeys where container.contains(key) {
            if let value = try? container.decode(JSONValue.self, forKey: key) {
                raw[key.stringValue] = value
            }
        }
        rawSubscriptionPayload = raw.isEmpty ? nil : raw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(id), forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(permalink, forKey: .permalink)
        try container.encode(permalinkURL, forKey: .permalinkURL)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(profileVisuals, forKey: .profileVisuals)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(fullName, forKey: .fullName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(website, forKey: .website)
        try container.encodeIfPresent(websiteTitle, forKey: .websiteTitle)
        try container.encode(trackCount, forKey: .trackCount)
        try container.encode(playlistCount, forKey: .playlistCount)
        try container.encode(followersCount, forKey: .followersCount)
        try container.encode(followingsCount, forKey: .followingsCount)
        try container.encodeIfPresent(publicFavoritesCount, forKey: .publicFavoritesCount)
        try container.encodeIfPresent(verified, forKey: .verified)
        try container.encodeIfPresent(consumerSubscriptions, forKey: .consumerSubscriptions)
        try container.encodeIfPresent(consumerSubscription, forKey: .consumerSubscription)
        try container.encodeIfPresent(creatorSubscriptions, forKey: .creatorSubscriptions)
        try container.encodeIfPresent(creatorSubscription, forKey: .creatorSubscription)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: User, rhs: User) -> Bool {
        lhs.id == rhs.id
    }
}

struct SoundCloudWebProfile: Decodable, Hashable, Sendable {
    let url: URL
    let title: String?
    let service: String?

    private enum CodingKeys: String, CodingKey {
        case url, title, service, network
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        service = ((try? container.decodeIfPresent(String.self, forKey: .service)) ?? nil)
            ?? ((try? container.decodeIfPresent(String.self, forKey: .network)) ?? nil)
    }
}

struct SoundCloudWebProfiles: Decodable, Sendable {
    let profiles: [SoundCloudWebProfile]

    private enum CodingKeys: String, CodingKey {
        case collection
    }

    private struct Lenient: Decodable {
        let profile: SoundCloudWebProfile?

        init(from decoder: Decoder) throws {
            profile = try? SoundCloudWebProfile(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Lenient].self) {
            profiles = list.compactMap(\.profile)
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profiles = (try container.decodeIfPresent([Lenient].self, forKey: .collection) ?? []).compactMap(\.profile)
        }
    }
}

enum CompactCount {
    private static let units: [(size: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]

    static func string(_ count: Int) -> String {
        let value = Double(abs(count))
        let sign = count < 0 ? "-" : ""
        for (index, unit) in units.enumerated() where value >= unit.size {
            let scaled = (value / unit.size * 10).rounded() / 10
            if scaled >= 1000, index > 0 {
                let larger = units[index - 1]
                return sign + trimmed((value / larger.size * 10).rounded() / 10) + larger.suffix
            }
            return sign + trimmed(scaled) + unit.suffix
        }
        return "\(count)"
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct SoundCloudProfileVisuals: Codable, Hashable, Sendable {
    let visuals: [SoundCloudProfileVisual]
}

struct SoundCloudProfileVisual: Codable, Hashable, Sendable {
    let visualURL: URL?

    enum CodingKeys: String, CodingKey {
        case visualURL = "visual_url"
    }
}

struct ConsumerSubscription: Codable, Hashable, Sendable {
    let product: SubscriptionProductRef?
}

typealias CreatorSubscription = ConsumerSubscription

struct SubscriptionProductRef: Codable, Hashable, Sendable {
    let id: String?
}

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    private static let sensitiveKeySubstrings = [
        "token", "password", "secret", "signature", "cookie",
        "session", "email", "auth", "credential", "key",
    ]

    private static func isSensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeySubstrings.contains { lowered.contains($0) }
    }

    var diagnosticDescription: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return "\"\(value)\""
        case .array(let values):
            return "[" + values.map(\.diagnosticDescription).joined(separator: ", ") + "]"
        case .object(let values):
            let body = values.keys.sorted().map { key -> String in
                let rendered = JSONValue.isSensitive(key)
                    ? "<redacted>"
                    : (values[key]?.diagnosticDescription ?? "null")
                return "\(key): \(rendered)"
            }
            return "{" + body.joined(separator: ", ") + "}"
        }
    }
}

struct TrackEngagedUser: Codable, Hashable, Sendable {
    let user: User

    private enum CodingKeys: String, CodingKey {
        case user
    }

    init(user: User) {
        self.user = user
    }

    init(from decoder: Decoder) throws {
        if let direct = try? User(from: decoder) {
            user = direct
        } else {
            user = try decoder.container(keyedBy: CodingKeys.self).decode(User.self, forKey: .user)
        }
    }

    func encode(to encoder: Encoder) throws {
        try user.encode(to: encoder)
    }
}
