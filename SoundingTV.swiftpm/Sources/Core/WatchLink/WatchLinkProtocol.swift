import Foundation

enum WatchLinkKey {
    static let kind = "k"
    static let payload = "p"
    static let nowPlaying = "nowPlaying"
    static let djState = "djState"
    static let downloads = "downloads"
    static let authState = "authState"
    static let settings = "settings"
    static let polyphony = "polyphony"
}

enum WatchLinkKind: String, Codable, Sendable {
    case snapshotRequest
    case sessionRequest
    case sessionOffer
    case sessionUnavailable
    case transport
    case seek
    case play
    case queue
    case dj
    case output
    case polyphony
}

enum WatchTransportAction: String, Codable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
}

enum WatchDJAction: String, Codable, Sendable {
    case enable
    case disable
    case autoEnable
    case autoDisable
    case mixNow
}

enum WatchQueueAction: String, Codable, Sendable {
    case addToEnd
    case playNext
}

enum WatchPolyphonyAction: String, Codable, Sendable {
    case lead
    case leave
}

enum WatchPolyphonyMode: String, Codable, Equatable, Sendable {
    case idle
    case startingLeader
    case leading
    case connecting
    case speaker
    case failed
}

struct WatchPolyphonyState: Codable, Equatable, Sendable {
    var mode: WatchPolyphonyMode
    var leaderName: String?
    var joinCode: String?
    var speakerCount: Int
    var message: String?
    var updatedAtMillis: Int64

    static let idle = WatchPolyphonyState(
        mode: .idle,
        leaderName: nil,
        joinCode: nil,
        speakerCount: 0,
        message: nil,
        updatedAtMillis: 0
    )
}

struct WatchCommand: Codable, Sendable {
    var kind: WatchLinkKind
    var transport: WatchTransportAction?
    var dj: WatchDJAction?
    var queue: WatchQueueAction?
    var output: DeviceClass?
    var polyphony: WatchPolyphonyAction?
    var seekSeconds: TimeInterval?
    var trackId: String?
    var collectionId: String?
    var shuffled: Bool?

    init(
        kind: WatchLinkKind,
        transport: WatchTransportAction? = nil,
        dj: WatchDJAction? = nil,
        queue: WatchQueueAction? = nil,
        output: DeviceClass? = nil,
        polyphony: WatchPolyphonyAction? = nil,
        seekSeconds: TimeInterval? = nil,
        trackId: String? = nil,
        collectionId: String? = nil,
        shuffled: Bool? = nil
    ) {
        self.kind = kind
        self.transport = transport
        self.dj = dj
        self.queue = queue
        self.output = output
        self.polyphony = polyphony
        self.seekSeconds = seekSeconds
        self.trackId = trackId
        self.collectionId = collectionId
        self.shuffled = shuffled
    }
}

struct WatchNowPlaying: Codable, Equatable, Sendable {
    var trackId: String?
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
    var positionSeconds: TimeInterval
    var durationSeconds: TimeInterval
    var output: DeviceClass
    var queueCount: Int
    var updatedAtMillis: Int64

    static let idle = WatchNowPlaying(
        trackId: nil,
        title: "",
        artist: "",
        artworkURL: nil,
        isPlaying: false,
        positionSeconds: 0,
        durationSeconds: 0,
        output: .phone,
        queueCount: 0,
        updatedAtMillis: 0
    )

    var hasTrack: Bool { trackId != nil }

    func projectedPosition(at date: Date, since received: Date) -> TimeInterval {
        guard isPlaying, durationSeconds > 0 else { return positionSeconds }
        let elapsed = max(0, date.timeIntervalSince(received))
        return min(durationSeconds, positionSeconds + elapsed)
    }
}

struct WatchDJState: Codable, Equatable, Sendable {
    var isEngineLive: Bool
    var isAutoEnabled: Bool
    var nextTitle: String?
    var nextArtist: String?
    var nextArtworkURL: URL?
    var mixInSeconds: TimeInterval?
    var reasoning: String?
    var updatedAtMillis: Int64

    static let off = WatchDJState(
        isEngineLive: false,
        isAutoEnabled: false,
        nextTitle: nil,
        nextArtist: nil,
        nextArtworkURL: nil,
        mixInSeconds: nil,
        reasoning: nil,
        updatedAtMillis: 0
    )

    func projectedMixIn(at date: Date, since received: Date) -> TimeInterval? {
        guard let mixInSeconds else { return nil }
        return max(0, mixInSeconds - date.timeIntervalSince(received))
    }
}

struct WatchDownloadItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var bytes: Int64
}

struct WatchDownloadInventory: Codable, Equatable, Sendable {
    var items: [WatchDownloadItem]
    var totalBytes: Int64
    var updatedAtMillis: Int64

    static let empty = WatchDownloadInventory(items: [], totalBytes: 0, updatedAtMillis: 0)
}

struct WatchAuthState: Codable, Equatable, Sendable {
    var isSignedIn: Bool
    var displayName: String?
    var avatarURL: URL?
    var updatedAtMillis: Int64

    static let unknown = WatchAuthState(
        isSignedIn: false,
        displayName: nil,
        avatarURL: nil,
        updatedAtMillis: 0
    )
}

struct WatchManagedSetting: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var value: String
    var source: DeviceClass
}

struct WatchSettingsSnapshot: Codable, Equatable, Sendable {
    var items: [WatchManagedSetting]
    var updatedAtMillis: Int64

    static let empty = WatchSettingsSnapshot(items: [], updatedAtMillis: 0)
}

struct WatchSessionOffer: Codable, Sendable {
    var oauthToken: String
    var refreshToken: String?
    var clientId: String?
    var expiresAt: Date?
}

enum WatchLinkCodec {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func message<T: Encodable>(_ kind: WatchLinkKind, _ value: T) -> [String: Any] {
        var payload: [String: Any] = [WatchLinkKey.kind: kind.rawValue]
        if let data = encode(value) {
            payload[WatchLinkKey.payload] = data
        }
        return payload
    }

    static func kind(of message: [String: Any]) -> WatchLinkKind? {
        guard let raw = message[WatchLinkKey.kind] as? String else { return nil }
        return WatchLinkKind(rawValue: raw)
    }

    static func payload<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[WatchLinkKey.payload] as? Data else { return nil }
        return decode(type, from: data)
    }

    static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
