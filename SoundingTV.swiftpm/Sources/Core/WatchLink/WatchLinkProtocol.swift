import Foundation

enum WatchLinkKey {
    static let kind = "k"
    static let payload = "p"
    static let nowPlaying = "nowPlaying"
    static let djState = "djState"
    static let downloads = "downloads"
    static let authState = "authState"
    static let settings = "settings"
    static let queue = "queue"
    static let continueOffer = "continueOffer"
    static let devicePresence = "devicePresence"
    static let offlineManifest = "offlineManifest"
    static let offlineInventory = "offlineInventory"
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
    case jump
    case volume
    case continueFrom
    case continueDismiss
    case offlineFile
    case offlineRemove
    case playReport
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
    case extend
    case heartRate
}

enum WatchQueueAction: String, Codable, Sendable {
    case addToEnd
    case playNext
}

struct WatchCommand: Codable, Sendable {
    var kind: WatchLinkKind
    var transport: WatchTransportAction?
    var dj: WatchDJAction?
    var queue: WatchQueueAction?
    var output: DeviceClass?
    var seekSeconds: TimeInterval?
    var trackId: String?
    var collectionId: String?
    var shuffled: Bool?
    var heartRate: Double?
    var queueIndex: Int?
    var artistId: String?
    var outputId: String?
    var volume: Double?
    var continueId: String?

    init(
        kind: WatchLinkKind,
        transport: WatchTransportAction? = nil,
        dj: WatchDJAction? = nil,
        queue: WatchQueueAction? = nil,
        output: DeviceClass? = nil,
        seekSeconds: TimeInterval? = nil,
        trackId: String? = nil,
        collectionId: String? = nil,
        shuffled: Bool? = nil,
        heartRate: Double? = nil,
        queueIndex: Int? = nil,
        artistId: String? = nil,
        outputId: String? = nil,
        volume: Double? = nil,
        continueId: String? = nil
    ) {
        self.kind = kind
        self.transport = transport
        self.dj = dj
        self.queue = queue
        self.output = output
        self.seekSeconds = seekSeconds
        self.trackId = trackId
        self.collectionId = collectionId
        self.shuffled = shuffled
        self.heartRate = heartRate
        self.queueIndex = queueIndex
        self.artistId = artistId
        self.outputId = outputId
        self.volume = volume
        self.continueId = continueId
    }
}

struct WatchOutputOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    static let thisPhoneID = "this-device"
    static let thisWatchID = "this-watch"

    var id: String
    var name: String
    var deviceClass: DeviceClass
    var isAvailable: Bool = true
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
    var outputId: String? = nil
    var outputName: String? = nil
    var outputs: [WatchOutputOption]? = nil
    var volume: Double? = nil

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

    var isRemoteOutput: Bool {
        if let outputId { return outputId != WatchOutputOption.thisPhoneID }
        return output != .phone
    }

    var displayOutputName: String { outputName ?? output.displayName }

    var outputOptions: [WatchOutputOption] {
        if let outputs, !outputs.isEmpty { return outputs }
        return [
            WatchOutputOption(id: WatchOutputOption.thisPhoneID, name: DeviceClass.phone.displayName, deviceClass: .phone),
            WatchOutputOption(id: "class.tv", name: DeviceClass.tv.displayName, deviceClass: .tv),
        ]
    }

    func isSelected(_ option: WatchOutputOption) -> Bool {
        if let outputId { return option.id == outputId }
        return option.deviceClass == output
    }

    var clampedVolume: Double? {
        guard let volume, volume.isFinite else { return nil }
        return min(1, max(0, volume))
    }

    func projectedPosition(at date: Date, since received: Date) -> TimeInterval {
        guard isPlaying, durationSeconds > 0 else { return positionSeconds }
        let elapsed = max(0, date.timeIntervalSince(received))
        return min(durationSeconds, positionSeconds + elapsed)
    }
}

struct WatchContinueOffer: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var deviceName: String
    var deviceClass: DeviceClass
    var title: String
    var artist: String
    var artworkURL: URL?
    var positionSeconds: TimeInterval
    var durationSeconds: TimeInterval
    var isPlaying: Bool
    var updatedAtMillis: Int64

    var progress: Double? {
        guard durationSeconds > 0 else { return nil }
        return min(1, max(0, positionSeconds / durationSeconds))
    }
}

struct WatchDevicePresence: Codable, Equatable, Sendable {
    static let limit = 4

    var entries: [DevicePresenceEntry]

    static let empty = WatchDevicePresence(entries: [])

    func visible(at now: Date, trustsLive: Bool) -> [DevicePresenceEntry] {
        DevicePresence.ordered(entries.compactMap { $0.evaluated(at: now, trustsLive: trustsLive) })
    }
}

struct WatchQueueItem: Codable, Equatable, Sendable, Identifiable {
    var index: Int
    var trackId: String
    var title: String
    var artist: String
    var artworkURL: URL?

    var id: Int { index }
}

struct WatchQueueSnapshot: Codable, Equatable, Sendable {
    static let limit = 20

    var items: [WatchQueueItem]
    var updatedAtMillis: Int64
    var sourceTitle: String? = nil

    static let empty = WatchQueueSnapshot(items: [], updatedAtMillis: 0)
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
    var live: Data? = nil

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
    var replacesLineage: String?
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

enum WatchVolumeThrottle {
    static let interval: TimeInterval = 0.15
    static let holdLimit: TimeInterval = 2

    static func settles(pending: Double, reported: Double?, since setAt: Date, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(setAt) >= holdLimit { return true }
        guard let reported else { return false }
        return abs(reported - pending) < 0.02
    }
}
