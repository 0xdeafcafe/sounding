import Foundation

struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkURL: URL?
    let waveformURL: URL?
    let permalinkURL: URL
    let duration: TimeInterval // in seconds
    /// SoundCloud omits this for tracks whose public count is hidden. Keep
    /// that distinction instead of rendering a made-up "0 plays".
    let playbackCount: Int?
    let likeCount: Int
    let repostCount: Int
    let userFavorite: Bool
    let userReposted: Bool
    let createdAt: Date
    let user: User
    let streamURL: URL?
    let transcodings: [Transcoding]
    let genre: String?
    let tags: [String]
    /// Present on owner/private-share responses. Absence means the endpoint
    /// did not disclose privacy; it must not be guessed from playability.
    let sharing: String?

    var isPrivate: Bool { sharing?.lowercased() == "private" }

    let stationURN: String?

    var urn: String { "soundcloud:tracks:\(id)" }

    var mixSource: Transcoding? {
        transcodings
            .filter { $0.codec != .opus }
            .max { $0.mixRank < $1.mixRank }
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var largeArtworkURL: URL? {
        guard let url = artworkURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t500x500"))
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, media, genre, sharing
        case artworkURL = "artwork_url"
        case waveformURL = "waveform_url"
        case permalinkURL = "permalink_url"
        case playbackCount = "playback_count"
        case likeCount = "likes_count"
        case repostCount = "reposts_count"
        case userFavorite = "user_favorite"
        case userReposted = "user_reposted"
        case createdAt = "created_at"
        case tagList = "tag_list"
        case stationURN = "station_urn"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(Int.self, forKey: .id)
        id = String(rawID)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        waveformURL = try container.decodeIfPresent(URL.self, forKey: .waveformURL)
        permalinkURL = try container.decode(URL.self, forKey: .permalinkURL)
        playbackCount = try container.decodeIfPresent(Int.self, forKey: .playbackCount)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        repostCount = try container.decodeIfPresent(Int.self, forKey: .repostCount) ?? 0
        userFavorite = try container.decodeIfPresent(Bool.self, forKey: .userFavorite) ?? false
        userReposted = try container.decodeIfPresent(Bool.self, forKey: .userReposted) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        user = try container.decode(User.self, forKey: .user)
        sharing = try container.decodeIfPresent(String.self, forKey: .sharing)

        let rawGenre = try? container.decodeIfPresent(String.self, forKey: .genre)
        genre = ((rawGenre ?? nil)?.isEmpty ?? true) ? nil : (rawGenre ?? nil)
        let rawTagList = (try? container.decodeIfPresent(String.self, forKey: .tagList)) ?? nil
        tags = TrackAbout.parseTagList(rawTagList ?? "")
        let rawStation = (try? container.decodeIfPresent(String.self, forKey: .stationURN)) ?? nil
        stationURN = (rawStation?.isEmpty ?? true) ? nil : rawStation

        let media = try container.decodeIfPresent(Media.self, forKey: .media)
        transcodings = (media?.transcodings ?? []).filter { !$0.isSnippet }

        let best = transcodings.max { $0.playbackRank < $1.playbackRank }
        streamURL = best?.url
        duration = TimeInterval(best?.duration ?? 0) / 1000

        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_TRANSCODINGS"] == "1",
           !transcodings.isEmpty {
            let list = transcodings
                .sorted { $0.playbackRank > $1.playbackRank }
                .map(\.debugSummary)
                .joined(separator: "\n    ")
            NSLog("[Track] %@ — %d transcodings, chose %@\n    %@",
                  title, transcodings.count, best?.debugSummary ?? "none", list)
        }
        #endif
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(id), forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try container.encodeIfPresent(waveformURL, forKey: .waveformURL)
        try container.encode(permalinkURL, forKey: .permalinkURL)
        try container.encodeIfPresent(playbackCount, forKey: .playbackCount)
        try container.encode(likeCount, forKey: .likeCount)
        try container.encode(repostCount, forKey: .repostCount)
        try container.encode(userFavorite, forKey: .userFavorite)
        try container.encode(userReposted, forKey: .userReposted)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(user, forKey: .user)
        try container.encodeIfPresent(sharing, forKey: .sharing)
        try container.encodeIfPresent(genre, forKey: .genre)
        if !tags.isEmpty {
            try container.encode(tags.joined(separator: " "), forKey: .tagList)
        }
        try container.encodeIfPresent(stationURN, forKey: .stationURN)
        try container.encode(Media(transcodings: transcodings), forKey: .media)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }

}

struct Transcoding: Codable, Hashable, Sendable {
    let url: URL
    let preset: String?
    let duration: Int?
    let quality: String?
    let snipped: Bool?
    let format: Format

    struct Format: Codable, Hashable, Sendable {
        let `protocol`: String?
        let mimeType: String?

        enum CodingKeys: String, CodingKey {
            case `protocol`
            case mimeType = "mime_type"
        }
    }

    enum Codec: Int, Comparable, Sendable {
        case unknown = 0
        case opus    = 1
        case mp3     = 2
        case aac     = 3
        case lossless = 4

        static func < (a: Codec, b: Codec) -> Bool { a.rawValue < b.rawValue }
    }

    var isProgressive: Bool { format.protocol == "progressive" }
    var isHQ: Bool { quality == "hq" }
    var isSnippet: Bool { snipped == true }

    var isAdaptive: Bool { preset?.hasPrefix("abr") == true }

    var codec: Codec {
        let hay = "\(preset ?? "") \(format.mimeType ?? "")".lowercased()
        if hay.contains("flac") || hay.contains("alac") { return .lossless }
        if hay.contains("opus") || hay.contains("ogg")  { return .opus }
        if hay.contains("aac") || hay.contains("mp4")   { return .aac }
        if hay.contains("mp3") || hay.contains("mpeg")  { return .mp3 }
        return .unknown
    }

    var bitrate: Int {
        if let preset,
           let match = preset.range(of: #"(\d{2,4})k"#, options: .regularExpression) {
            let digits = preset[match].dropLast()
            if let value = Int(digits) { return value }
        }
        return isHQ ? 256 : 128
    }

    private var rankBitrate: Int { min(bitrate, 999) }

    var playbackRank: Int {
        codec.rawValue * 10_000
            + rankBitrate * 10
            + (isProgressive ? 2 : 0)
            + (isAdaptive ? 0 : 1)
    }

    var mixRank: Int { playbackRank }

    var debugSummary: String {
        "\(preset ?? "?") \(quality ?? "?") \(format.protocol ?? "?") "
            + "\(format.mimeType ?? "?") ~\(bitrate)k rank=\(playbackRank)"
    }
}

struct Media: Codable, Hashable, Sendable {
    let transcodings: [Transcoding]
}

extension KeyedDecodingContainer {
    func decode(_ type: [String: Any].Type, forKey key: K) throws -> [String: Any] {
        let container = try nestedContainer(keyedBy: JSONCodingKeys.self, forKey: key)
        return try container.decode(type)
    }

    func decodeIfPresent(_ type: [String: Any].Type, forKey key: K) throws -> [String: Any]? {
        guard contains(key) else { return nil }
        guard try decodeNil(forKey: key) == false else { return nil }
        return try decode(type, forKey: key)
    }

    func decode(_ type: [String: [[String: Any]]].Type, forKey key: K) throws -> [String: [[String: Any]]]? {
        guard contains(key) else { return nil }
        let container = try nestedContainer(keyedBy: JSONCodingKeys.self, forKey: key)
        var result: [String: [[String: Any]]] = [:]
        for key in container.allKeys {
            if let array = try? container.decode([[String: Any]].self, forKey: key) {
                result[key.stringValue] = array
            }
        }
        return result
    }
}

extension KeyedDecodingContainer where K == JSONCodingKeys {
    func decode(_ type: [String: Any].Type) throws -> [String: Any] {
        var dictionary: [String: Any] = [:]
        for key in allKeys {
            if let bool = try? decode(Bool.self, forKey: key) {
                dictionary[key.stringValue] = bool
            } else if let int = try? decode(Int.self, forKey: key) {
                dictionary[key.stringValue] = int
            } else if let double = try? decode(Double.self, forKey: key) {
                dictionary[key.stringValue] = double
            } else if let string = try? decode(String.self, forKey: key) {
                dictionary[key.stringValue] = string
            } else if let nested = try? nestedContainer(keyedBy: JSONCodingKeys.self, forKey: key) {
                dictionary[key.stringValue] = try nested.decode([String: Any].self)
            } else if var array = try? nestedUnkeyedContainer(forKey: key) {
                dictionary[key.stringValue] = try array.decode([Any].self)
            }
        }
        return dictionary
    }

    func decode(_ type: [[String: Any]].Type, forKey key: K) throws -> [[String: Any]] {
        var array = try nestedUnkeyedContainer(forKey: key)
        return try array.decode([[String: Any]].self)
    }
}

extension UnkeyedDecodingContainer {
    mutating func decode(_ type: [Any].Type) throws -> [Any] {
        var array: [Any] = []
        while !isAtEnd {
            if let bool = try? decode(Bool.self) {
                array.append(bool)
            } else if let int = try? decode(Int.self) {
                array.append(int)
            } else if let double = try? decode(Double.self) {
                array.append(double)
            } else if let string = try? decode(String.self) {
                array.append(string)
            } else if let nested = try? nestedContainer(keyedBy: JSONCodingKeys.self) {
                array.append(try nested.decode([String: Any].self))
            } else if var nested = try? nestedUnkeyedContainer() {
                array.append(try nested.decode([Any].self))
            }
        }
        return array
    }

    mutating func decode(_ type: [[String: Any]].Type) throws -> [[String: Any]] {
        var array: [[String: Any]] = []
        while !isAtEnd {
            if let nested = try? nestedContainer(keyedBy: JSONCodingKeys.self) {
                array.append(try nested.decode([String: Any].self))
            }
        }
        return array
    }
}

struct JSONCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}

struct TrackAbout: Decodable {
    let genre: String?
    let tags: [String]
    let labelName: String?
    let releaseDate: Date?
    let isExplicit: Bool?
    let isrc: String?
    let publisherArtist: String?
    let publisherName: String?

    private enum CodingKeys: String, CodingKey {
        case genre
        case tagList = "tag_list"
        case labelName = "label_name"
        case releaseDate = "release_date"
        case publisherMetadata = "publisher_metadata"
    }

    private enum PublisherMetadataKeys: String, CodingKey {
        case explicit, isrc, artist, publisher
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        genre = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .genre))
        let rawTagList = (try? container.decodeIfPresent(String.self, forKey: .tagList)) ?? nil
        tags = Self.parseTagList(rawTagList ?? "")
        labelName = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .labelName))
        releaseDate = (try? container.decodeIfPresent(Date.self, forKey: .releaseDate)) ?? nil

        if let publisher = try? container.nestedContainer(keyedBy: PublisherMetadataKeys.self, forKey: .publisherMetadata) {
            isExplicit = (try? publisher.decodeIfPresent(Bool.self, forKey: .explicit)) ?? nil
            isrc = Self.nonEmpty(try? publisher.decodeIfPresent(String.self, forKey: .isrc))
            publisherArtist = Self.nonEmpty(try? publisher.decodeIfPresent(String.self, forKey: .artist))
            publisherName = Self.nonEmpty(try? publisher.decodeIfPresent(String.self, forKey: .publisher))
        } else {
            isExplicit = nil
            isrc = nil
            publisherArtist = nil
            publisherName = nil
        }
    }

    private static func nonEmpty(_ value: String??) -> String? {
        guard let value = value ?? nil, !value.isEmpty else { return nil }
        return value
    }

    static func parseTagList(_ raw: String) -> [String] {
        var tags: [String] = []
        var current = ""
        var inQuotes = false
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                if !inQuotes, !current.isEmpty {
                    tags.append(current)
                    current = ""
                }
            } else if char == " ", !inQuotes {
                if !current.isEmpty {
                    tags.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tags.append(current) }
        return tags
    }
}
