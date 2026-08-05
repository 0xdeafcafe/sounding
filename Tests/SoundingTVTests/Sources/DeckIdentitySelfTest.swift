import Foundation
@testable import SoundingTV

#if DEBUG
enum DeckIdentitySelfTest {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func comment(
        id: Int,
        body: String,
        timestamp: Int,
        createdAt: String,
        userID: Int,
        user: String
    ) -> Comment {
        let json = """
        {
          "id": \(id),
          "body": "\(body)",
          "timestamp": \(timestamp),
          "created_at": "\(createdAt)",
          "user": {
            "id": \(userID),
            "username": "\(user)",
            "permalink": "\(user)",
            "permalink_url": "https://soundcloud.com/\(user)"
          }
        }
        """
        // Test fixtures are static and intentionally fail loudly if their
        // shape stops matching the SoundCloud model.
        return try! decoder.decode(Comment.self, from: Data(json.utf8))
    }

    static func run() -> ModelDecodeSelfTestReport {
        var report = ModelDecodeSelfTestReport()
        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("On Deck: \(name) → ok")
            } else {
                report.failures.append("On Deck: \(name)")
            }
        }

        let request = comment(
            id: 1, body: "track id?", timestamp: 64_000,
            createdAt: "2026-08-04T10:00:00Z", userID: 10, user: "alice"
        )
        let answer = comment(
            id: 2, body: "@alice Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        let valid = DeckIdentityResolver.commentIdentities(comments: [answer, request])
        expect("request followed by tagged ID is accepted",
               valid.count == 1 && valid.first?.label == "Underworld — Rez"
                   && valid.first?.commentID == "2")

        let nearbyID = comment(
            id: 3, body: "Underworld — Rez", timestamp: 65_000,
            createdAt: "2026-08-04T10:01:00Z", userID: 30, user: "carol"
        )
        expect("nearby ID without an exchange is rejected",
               DeckIdentityResolver.commentIdentities(comments: [nearbyID]).isEmpty)

        let unrelated = comment(
            id: 4, body: "what a drop", timestamp: 65_000,
            createdAt: "2026-08-04T10:01:00Z", userID: 10, user: "alice"
        )
        expect("later chatter does not hide the earlier request",
               DeckIdentityResolver.commentIdentities(comments: [request, unrelated, answer]).count == 1)

        let sameAuthorAnswer = comment(
            id: 5, body: "@alice Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 10, user: "alice"
        )
        expect("self-answer is rejected",
               DeckIdentityResolver.commentIdentities(comments: [request, sameAuthorAnswer]).isEmpty)

        let farAnswer = comment(
            id: 6, body: "@alice Underworld — Rez", timestamp: 100_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        expect("answer outside the track-time window is rejected",
               DeckIdentityResolver.commentIdentities(comments: [request, farAnswer]).isEmpty)

        let wrongTag = comment(
            id: 7, body: "@carol Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        expect("answer must tag the requester",
               DeckIdentityResolver.commentIdentities(comments: [request, wrongTag]).isEmpty)

        return report
    }
}
#endif
