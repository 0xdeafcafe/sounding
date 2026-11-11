import Foundation

struct ContinueSession: Codable, Hashable, Sendable, Identifiable {
    static let queueLimit = 100

    var deviceID: String
    var deviceName: String
    var deviceClass: DeviceClass
    var account: String
    var sessionID: String
    var trackID: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var duration: TimeInterval
    var position: TimeInterval
    var queueTrackIDs: [String]
    var queueIndex: Int
    var collectionID: String?
    var sourceID: String?
    var sourceKind: String?
    var sourceTitle: String?
    var isAutoMix: Bool
    var isPlaying: Bool
    var updatedAtMillis: Int64
    var startedAtMillis: Int64?

    var id: String { deviceID }

    var updatedAt: Date { Date(timeIntervalSince1970: TimeInterval(updatedAtMillis) / 1000) }

    var startedAt: Date? { startedAtMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }

    var dismissalKey: String { "\(deviceID)|\(sessionID)" }

    init(
        deviceID: String,
        deviceName: String,
        deviceClass: DeviceClass,
        account: String,
        sessionID: String,
        trackID: String,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        duration: TimeInterval,
        position: TimeInterval,
        queueTrackIDs: [String],
        queueIndex: Int,
        collectionID: String? = nil,
        sourceID: String? = nil,
        sourceKind: String? = nil,
        sourceTitle: String? = nil,
        isAutoMix: Bool = false,
        isPlaying: Bool,
        updatedAt: Date,
        startedAt: Date? = nil
    ) {
        let window = Self.window(queueTrackIDs, index: queueIndex, current: trackID)
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceClass = deviceClass
        self.account = account
        self.sessionID = sessionID
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        self.position = position.isFinite ? max(0, position) : 0
        self.queueTrackIDs = window.ids
        self.queueIndex = window.index
        self.collectionID = collectionID
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.sourceTitle = sourceTitle
        self.isAutoMix = isAutoMix
        self.isPlaying = isPlaying
        self.updatedAtMillis = RecentPlay.millis(updatedAt)
        self.startedAtMillis = startedAt.map(RecentPlay.millis)
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "d", deviceName = "n", deviceClass = "c", account = "k", sessionID = "s"
        case trackID = "i", title = "t", artist = "a", artworkURL = "w", duration = "l", position = "p"
        case queueTrackIDs = "q", queueIndex = "x", collectionID = "o"
        case sourceID = "si", sourceKind = "sk", sourceTitle = "st"
        case isAutoMix = "m", isPlaying = "g", updatedAtMillis = "u", startedAtMillis = "b"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        trackID = try c.decode(String.self, forKey: .trackID)
        updatedAtMillis = try c.decode(Int64.self, forKey: .updatedAtMillis)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        deviceClass = (try? c.decodeIfPresent(DeviceClass.self, forKey: .deviceClass)) ?? .phone
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? String(updatedAtMillis)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        artworkURL = try? c.decodeIfPresent(URL.self, forKey: .artworkURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        position = try c.decodeIfPresent(TimeInterval.self, forKey: .position) ?? 0
        let ids = try c.decodeIfPresent([String].self, forKey: .queueTrackIDs) ?? []
        let index = try c.decodeIfPresent(Int.self, forKey: .queueIndex) ?? 0
        if ids.indices.contains(index), ids[index] == trackID {
            queueTrackIDs = ids
            queueIndex = index
        } else if let found = ids.firstIndex(of: trackID) {
            queueTrackIDs = ids
            queueIndex = found
        } else {
            queueTrackIDs = [trackID]
            queueIndex = 0
        }
        collectionID = try c.decodeIfPresent(String.self, forKey: .collectionID)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        isAutoMix = try c.decodeIfPresent(Bool.self, forKey: .isAutoMix) ?? false
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        startedAtMillis = try c.decodeIfPresent(Int64.self, forKey: .startedAtMillis)
    }

    func position(at now: Date) -> TimeInterval {
        var estimate = position
        if isPlaying {
            estimate += min(max(0, now.timeIntervalSince(updatedAt)), ContinueSessions.liveSlack)
        }
        if duration > 0 { estimate = min(estimate, duration) }
        return max(0, estimate)
    }

    func isFinished(at now: Date) -> Bool {
        guard duration > 0, queueIndex >= queueTrackIDs.count - 1 else { return false }
        return position(at: now) >= duration - 2
    }

    func isNewer(than other: ContinueSession) -> Bool {
        if updatedAtMillis != other.updatedAtMillis { return updatedAtMillis > other.updatedAtMillis }
        if deviceID != other.deviceID { return deviceID > other.deviceID }
        return sessionID > other.sessionID
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> ContinueSession? {
        try? JSONDecoder().decode(ContinueSession.self, from: data)
    }

    static func window(_ ids: [String], index: Int, current: String, limit: Int = queueLimit) -> (ids: [String], index: Int) {
        let resolved: Int
        if ids.indices.contains(index), ids[index] == current {
            resolved = index
        } else if let found = ids.firstIndex(of: current) {
            resolved = found
        } else {
            return ([current], 0)
        }
        guard ids.count > limit else { return (ids, resolved) }
        let behind = min(resolved, limit / 5)
        let start = min(resolved - behind, ids.count - limit)
        return (Array(ids[start..<(start + limit)]), resolved - start)
    }
}

enum ContinueSessions {
    static let limit = 8
    static let keepFor: TimeInterval = 7 * 24 * 60 * 60
    static let offerWindow: TimeInterval = 12 * 60 * 60
    static let liveSlack: TimeInterval = 35
    static let futureSkew: TimeInterval = 5 * 60

    static func merging(_ lists: [[ContinueSession]], now: Date, limit: Int = limit) -> [ContinueSession] {
        var newest: [String: ContinueSession] = [:]
        for session in lists.joined() where !session.deviceID.isEmpty && !session.trackID.isEmpty {
            guard now.timeIntervalSince(session.updatedAt) <= keepFor else { continue }
            if let existing = newest[session.deviceID], !session.isNewer(than: existing) { continue }
            newest[session.deviceID] = session
        }
        return Array(newest.values.sorted { $0.isNewer(than: $1) }.prefix(limit))
    }

    static func offer(
        in sessions: [ContinueSession],
        ownDeviceID: String,
        account: String,
        ownLatest: Date?,
        dismissed: Set<String>,
        now: Date
    ) -> ContinueSession? {
        sessions
            .filter { session in
                isOffered(session, ownDeviceID: ownDeviceID, account: account, ownLatest: ownLatest, dismissed: dismissed, now: now)
            }
            .max { $1.isNewer(than: $0) }
    }

    private static func isOffered(
        _ session: ContinueSession,
        ownDeviceID: String,
        account: String,
        ownLatest: Date?,
        dismissed: Set<String>,
        now: Date
    ) -> Bool {
        guard session.deviceID != ownDeviceID else { return false }
        guard session.account.isEmpty || session.account == account else { return false }
        guard !dismissed.contains(session.dismissalKey) else { return false }
        let age = now.timeIntervalSince(session.updatedAt)
        guard age <= offerWindow, -age <= futureSkew else { return false }
        if let ownLatest, session.updatedAt <= ownLatest { return false }
        return !session.isFinished(at: now)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
