import Foundation

struct RecentPlay: Codable, Hashable, Sendable, Identifiable {
    var trackID: String
    var playedAtMillis: Int64
    var title: String
    var artist: String
    var artworkURL: URL?
    var duration: TimeInterval?
    var isLocal: Bool

    var id: String { trackID }

    var playedAt: Date { Date(timeIntervalSince1970: TimeInterval(playedAtMillis) / 1000) }

    init(
        trackID: String,
        playedAt: Date,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        isLocal: Bool = false
    ) {
        self.trackID = trackID
        self.playedAtMillis = Self.millis(playedAt)
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.isLocal = isLocal
    }

    init(track: Track, playedAt: Date) {
        self.init(
            trackID: track.id,
            playedAt: playedAt,
            title: track.title,
            artist: track.publisher?.artist ?? track.user.displayName,
            artworkURL: track.artworkURL,
            duration: track.duration,
            isLocal: track.isLocal || LocalTrackFile.isLocalTrackID(track.id)
        )
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "i", playedAtMillis = "t", title = "n", artist = "a", artworkURL = "w", duration = "d", isLocal = "l"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(String.self, forKey: .trackID)
        playedAtMillis = try c.decode(Int64.self, forKey: .playedAtMillis)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        artworkURL = try? c.decodeIfPresent(URL.self, forKey: .artworkURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? LocalTrackFile.isLocalTrackID(trackID)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    func isNewer(than other: RecentPlay) -> Bool {
        if playedAtMillis != other.playedAtMillis { return playedAtMillis > other.playedAtMillis }
        if trackID != other.trackID { return trackID > other.trackID }
        if title != other.title { return title > other.title }
        return artist > other.artist
    }
}

enum RecentPlays {
    static let limit = 40

    static func merging(_ lists: [[RecentPlay]], limit: Int = limit) -> [RecentPlay] {
        var newest: [String: RecentPlay] = [:]
        for play in lists.joined() {
            if let existing = newest[play.trackID], !play.isNewer(than: existing) { continue }
            newest[play.trackID] = play
        }
        return Array(newest.values.sorted { $0.isNewer(than: $1) }.prefix(max(0, limit)))
    }

    static func recording(_ play: RecentPlay, into list: [RecentPlay], limit: Int = limit) -> [RecentPlay] {
        merging([[play], list], limit: limit)
    }

    static func fromSoundCloud(_ items: [PlayHistoryItem]) -> [RecentPlay] {
        items.map { RecentPlay(track: $0.track, playedAt: $0.playedAt) }
    }
}

enum PlayQualification {
    static let minimumListen: TimeInterval = 30
    static let completionShare = 0.9

    static func threshold(duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 1 else { return minimumListen }
        return min(minimumListen, duration * completionShare)
    }

    static func repeatWindow(duration: TimeInterval) -> TimeInterval {
        let length = duration.isFinite ? max(0, duration) : 0
        return max(minimumListen, length * 0.5)
    }

    static func isRepeat(of previous: Date?, at now: Date, duration: TimeInterval) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous) < repeatWindow(duration: duration)
    }
}

struct PendingPlayReport: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var trackID: String
    var playedAtMillis: Int64
    var attempts: Int

    init(id: String = UUID().uuidString, trackID: String, playedAt: Date, attempts: Int = 0) {
        self.id = id
        self.trackID = trackID
        self.playedAtMillis = RecentPlay.millis(playedAt)
        self.attempts = attempts
    }

    var playedAt: Date { Date(timeIntervalSince1970: TimeInterval(playedAtMillis) / 1000) }
}

enum PlayReportOutbox {
    static let capacity = 50
    static let maximumAge: TimeInterval = 3 * 24 * 60 * 60
    static let maximumAttempts = 3

    static func enqueue(_ report: PendingPlayReport, into queue: [PendingPlayReport], now: Date) -> [PendingPlayReport] {
        guard !LocalTrackFile.isLocalTrackID(report.trackID),
              !queue.contains(where: { $0.id == report.id }) else { return pruned(queue, now: now) }
        return pruned(queue + [report], now: now)
    }

    static func pruned(_ queue: [PendingPlayReport], now: Date) -> [PendingPlayReport] {
        let kept = queue.filter {
            $0.attempts < maximumAttempts && now.timeIntervalSince($0.playedAt) <= maximumAge
        }
        return Array(kept.suffix(capacity))
    }
}
