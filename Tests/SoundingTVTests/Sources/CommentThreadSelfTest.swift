import Foundation
@testable import SoundingTV

#if DEBUG
enum CommentThreadSelfTest {
    private static func comment(
        id: Int, body: String, timestamp: Int?, createdAt: String,
        permalink: String, username: String? = nil
    ) -> String {
        let name = username ?? permalink
        let timestampField = timestamp.map { "\($0)" } ?? "null"
        return """
        {
            "id": \(id),
            "body": "\(body)",
            "timestamp": \(timestampField),
            "created_at": "\(createdAt)",
            "user": {
                "id": \(id * 100),
                "username": "\(name)",
                "permalink": "\(permalink)",
                "permalink_url": "https://soundcloud.com/\(permalink)"
            }
        }
        """
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func decode(_ elements: [String]) -> [Comment] {
        let json = "[\(elements.joined(separator: ","))]"
        return (try? decoder.decode([Comment].self, from: Data(json.utf8))) ?? []
    }

    static func run() -> ModelDecodeSelfTestReport {
        var report = ModelDecodeSelfTestReport()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("\(name) → ok")
            } else {
                report.failures.append(name)
            }
        }

        do {
            let comments = decode([
                comment(id: 1, body: "this drop", timestamp: 64000,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "alpha"),
                comment(id: 2, body: "@alpha so true", timestamp: 64000,
                        createdAt: "2025-01-04T10:01:00Z", permalink: "beta"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("reply: same timestamp + leading mention attaches",
                   set.timed.count == 1 && set.timed.first?.replies.map(\.id) == ["2"])
            expect("reply: nothing dropped", set.commentCount == 2)
        }

        do {
            let comments = decode([
                comment(id: 1, body: "root", timestamp: 10000,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "alpha"),
                comment(id: 2, body: "@alpha yes", timestamp: 10000,
                        createdAt: "2025-01-04T10:01:00Z", permalink: "beta"),
                comment(id: 3, body: "@beta agreed", timestamp: 10000,
                        createdAt: "2025-01-04T10:02:00Z", permalink: "gamma"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("depth cap: reply-to-reply lands on the thread root",
                   set.timed.count == 1 && set.timed.first?.replies.map(\.id) == ["2", "3"])
        }

        do {
            let comments = decode([
                comment(id: 1, body: "first", timestamp: 5000,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "alpha"),
                comment(id: 2, body: "@stranger who is this", timestamp: 5000,
                        createdAt: "2025-01-04T10:01:00Z", permalink: "beta"),
                comment(id: 3, body: "same moment no mention", timestamp: 5000,
                        createdAt: "2025-01-04T10:02:00Z", permalink: "gamma"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("no false threads: unmatched mention and plain co-timestamps stay roots",
                   set.timed.count == 3 && set.timed.allSatisfy { $0.replies.isEmpty })
        }

        do {
            let comments = decode([
                comment(id: 1, body: "mention across times @beta", timestamp: 90000,
                        createdAt: "2025-01-04T10:05:00Z", permalink: "alpha"),
                comment(id: 2, body: "earlier elsewhere", timestamp: 20000,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "beta"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("buckets: a mention never crosses timestamp buckets",
                   set.timed.count == 2 && set.timed.allSatisfy { $0.replies.isEmpty })
            expect("ordering: timed roots ascend by track position",
                   set.timed.map(\.id) == ["2", "1"])
        }

        do {
            let comments = decode([
                comment(id: 3, body: "newest general", timestamp: nil,
                        createdAt: "2025-01-06T10:00:00Z", permalink: "gamma"),
                comment(id: 2, body: "@alpha thanks!", timestamp: nil,
                        createdAt: "2025-01-05T10:00:00Z", permalink: "beta"),
                comment(id: 1, body: "great upload", timestamp: nil,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "alpha"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("untimed: replies attach within the pool",
                   set.untimed.first { $0.id == "1" }?.replies.map(\.id) == ["2"])
            expect("untimed: root order preserves the feed order",
                   set.untimed.map(\.id) == ["3", "1"])
        }

        do {
            let comments = decode([
                comment(id: 1, body: "love this", timestamp: 30000,
                        createdAt: "2025-01-04T10:00:00Z", permalink: "waveformwav", username: "waveform.wav"),
                comment(id: 2, body: "@waveform.wav same!", timestamp: 30000,
                        createdAt: "2025-01-04T10:01:00Z", permalink: "beta"),
            ])
            let set = CommentThreadBuilder.build(comments)
            expect("mention token: matches username with dots, trailing punctuation stripped",
                   set.timed.count == 1 && set.timed.first?.replies.map(\.id) == ["2"])
        }

        expect("token: leading mention parses", CommentThreadBuilder.mentionToken(in: "@some-user hi") == "some-user")
        expect("token: mid-body mention ignored", CommentThreadBuilder.mentionToken(in: "hey @some-user") == nil)
        expect("token: bare at-sign ignored", CommentThreadBuilder.mentionToken(in: "@ what") == nil)

        expect("clock: minutes", CommentFormat.clock(64) == "1:04")
        expect("clock: hours", CommentFormat.clock(3725) == "1:02:05")
        expect("clock: garbage clamps", CommentFormat.clock(.nan) == "0:00")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        expect("age: nil date stays nil", CommentFormat.age(of: nil, relativeTo: now) == nil)
        expect("age: minutes", CommentFormat.age(of: now.addingTimeInterval(-300), relativeTo: now) == "5m")
        expect("age: weeks", CommentFormat.age(of: now.addingTimeInterval(-14 * 86_400), relativeTo: now) == "2w")

        return report
    }
}
#endif
