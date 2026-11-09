import Foundation

struct CommentThread: Identifiable, Equatable {
    let root: Comment
    let replies: [Comment]

    var id: String { root.id }
    var timeInTrack: TimeInterval? { root.timeInTrack }
}

struct CommentThreadSet: Equatable {
    var timed: [CommentThread] = []
    var untimed: [CommentThread] = []

    var isEmpty: Bool { timed.isEmpty && untimed.isEmpty }

    var commentCount: Int {
        (timed + untimed).reduce(0) { $0 + 1 + $1.replies.count }
    }
}

enum CommentThreadBuilder {

    static func build(_ comments: [Comment]) -> CommentThreadSet {
        let indexed = comments.enumerated().map { (comment: $1, index: $0) }
        let timedGroups = Dictionary(grouping: indexed.filter { $0.comment.timestampMillis != nil }) {
            $0.comment.timestampMillis ?? 0
        }
        let untimedPool = indexed.filter { $0.comment.timestampMillis == nil }

        var timed: [CommentThread] = []
        for group in timedGroups.values {
            timed.append(contentsOf: threads(in: group))
        }
        timed.sort { lhs, rhs in
            let lt = lhs.timeInTrack ?? 0
            let rt = rhs.timeInTrack ?? 0
            if lt != rt { return lt < rt }
            return lhs.root.id < rhs.root.id
        }

        return CommentThreadSet(timed: timed, untimed: threads(in: untimedPool))
    }

    static func mentionToken(in body: String) -> String? {
        CommentMentionParser.mentionToken(in: body)
    }

    private static func threads(in group: [(comment: Comment, index: Int)]) -> [CommentThread] {
        guard group.count > 1 else {
            return group.map { CommentThread(root: $0.comment, replies: []) }
        }

        let ordered = group.sorted { lhs, rhs in
            switch (lhs.comment.createdAt, rhs.comment.createdAt) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.index < rhs.index
            }
        }

        var rootEntries: [(comment: Comment, index: Int)] = []
        var repliesByRootId: [String: [Comment]] = [:]
        var rootIdByCommentId: [String: String] = [:]
        var lastCommentIdByUserKey: [String: String] = [:]

        for entry in ordered {
            let comment = entry.comment
            var attachedRootId: String?
            if let token = mentionToken(in: comment.body),
               let parentId = lastCommentIdByUserKey[token],
               parentId != comment.id,
               let rootId = rootIdByCommentId[parentId] {
                attachedRootId = rootId
            }

            if let attachedRootId {
                repliesByRootId[attachedRootId, default: []].append(comment)
                rootIdByCommentId[comment.id] = attachedRootId
            } else {
                rootEntries.append(entry)
                rootIdByCommentId[comment.id] = comment.id
            }

            for key in userKeys(for: comment.user) {
                lastCommentIdByUserKey[key] = comment.id
            }
        }

        return rootEntries
            .sorted { $0.index < $1.index }
            .map { CommentThread(root: $0.comment, replies: repliesByRootId[$0.comment.id] ?? []) }
    }

    private static func userKeys(for user: User) -> [String] {
        var keys = [user.permalink.lowercased()]
        let username = user.username.lowercased()
        if username != keys[0] {
            keys.append(username)
        }
        return keys
    }
}

enum CommentFormat {
    static func clock(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN, time > 0 else { return "0:00" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    static func age(of date: Date?, relativeTo now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        if days < 35 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}

#if DEBUG
enum CommentDemo {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_COMMENTS_DEMO"] == "1"
    }

    static func comments() -> [Comment] {
        let json = """
        [
          {"id": 1, "body": "that intro is EVERYTHING \\ud83d\\ude2d", "timestamp": 8000,
           "created_at": "2025-01-04T10:00:00Z",
           "user": {"id": 101, "username": "latelistener", "permalink": "latelistener",
                    "permalink_url": "https://soundcloud.com/latelistener",
                    "avatar_url": null, "full_name": null,
                    "track_count": 12, "playlist_count": 1, "followers_count": 3200, "followings_count": 80}},
          {"id": 2, "body": "@nighttapes who's the vocalist here??", "timestamp": 42000,
           "created_at": "2025-01-04T10:02:00Z",
           "user": {"id": 102, "username": "reverbchild", "permalink": "reverbchild",
                    "permalink_url": "https://soundcloud.com/reverbchild",
                    "avatar_url": null, "full_name": null,
                    "track_count": 4, "playlist_count": 0, "followers_count": 88, "followings_count": 210}},
          {"id": 3, "body": "1:04 THIS DROP", "timestamp": 64000, "created_at": "2025-01-04T10:05:00Z",
           "user": {"id": 103, "username": "waveform.wav", "permalink": "waveformwav",
                    "permalink_url": "https://soundcloud.com/waveformwav",
                    "avatar_url": null, "full_name": null,
                    "track_count": 30, "playlist_count": 2, "followers_count": 990, "followings_count": 40}},
          {"id": 9, "body": "@waveformwav THIS. exactly this.", "timestamp": 64000,
           "created_at": "2025-01-04T10:06:00Z",
           "user": {"id": 109, "username": "nightdrive", "permalink": "nightdrive",
                    "permalink_url": "https://soundcloud.com/nightdrive",
                    "avatar_url": null, "full_name": null,
                    "track_count": 2, "playlist_count": 0, "followers_count": 61, "followings_count": 90}},
          {"id": 4, "body": "same \\ud83d\\udd25\\ud83d\\udd25\\ud83d\\udd25", "timestamp": 66000,
           "created_at": "2025-01-04T10:05:20Z",
           "user": {"id": 104, "username": "lowend_theory", "permalink": "lowendtheory",
                    "permalink_url": "https://soundcloud.com/lowendtheory",
                    "avatar_url": null, "full_name": null,
                    "track_count": 8, "playlist_count": 0, "followers_count": 1500, "followings_count": 12}},
          {"id": 5, "body": "68 seconds in is unreal", "timestamp": 68000,
           "created_at": "2025-01-04T10:05:40Z",
           "user": {"id": 105, "username": "glassbeam", "permalink": "glassbeam",
                    "permalink_url": "https://soundcloud.com/glassbeam",
                    "avatar_url": null, "full_name": null,
                    "track_count": 3, "playlist_count": 0, "followers_count": 44, "followings_count": 12}},
          {"id": 6, "body": "This has been on repeat all week, thank you for the upload!",
           "timestamp": 150000, "created_at": "2025-01-05T09:00:00Z",
           "user": {"id": 106, "username": "harbourlistener", "permalink": "harbourlistener",
                    "permalink_url": "https://soundcloud.com/harbourlistener",
                    "avatar_url": null, "full_name": null,
                    "track_count": 60, "playlist_count": 6, "followers_count": 12000, "followings_count": 3}},
          {"id": 7, "body": "id anyone? 3:15", "timestamp": 195000, "created_at": "2025-01-05T09:20:00Z",
           "user": {"id": 107, "username": "cratedigger", "permalink": "cratedigger",
                    "permalink_url": "https://soundcloud.com/cratedigger",
                    "avatar_url": null, "full_name": null,
                    "track_count": 1, "playlist_count": 0, "followers_count": 5, "followings_count": 400}},
          {"id": 8, "body": "Absolute classic, one of the best sets this year.",
           "created_at": "2025-01-06T11:00:00Z",
           "user": {"id": 108, "username": "nighttapes", "permalink": "nighttapes",
                    "permalink_url": "https://soundcloud.com/nighttapes",
                    "avatar_url": null, "full_name": "Night Tapes",
                    "track_count": 50, "playlist_count": 4, "followers_count": 250000, "followings_count": 100}}
        ]
        """
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        decoder.dateDecodingStrategy = .formatted(formatter)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? decoder.decode([Comment].self, from: data)) ?? []
    }
}
#endif
