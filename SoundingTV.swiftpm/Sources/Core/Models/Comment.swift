import Foundation

struct Comment: Identifiable, Codable, Hashable {
    let id: String
    let body: String
    let timestampMillis: Int?
    let createdAt: Date?
    let user: User

    var timeInTrack: TimeInterval? {
        timestampMillis.map { TimeInterval($0) / 1000 }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case timestampMillis = "timestamp"
        case createdAt = "created_at"
        case user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numeric = try? container.decode(Int.self, forKey: .id) {
            id = String(numeric)
        } else {
            id = try container.decode(String.self, forKey: .id)
        }

        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        timestampMillis = try container.decodeIfPresent(Int.self, forKey: .timestampMillis)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)

        if let decodedUser = try? container.decode(User.self, forKey: .user) {
            user = decodedUser
        } else {
            user = Comment.placeholderUser
        }
    }

    private static let placeholderUser: User = {
        let fallbackURL = URL(string: "https://soundcloud.com") ?? URL(fileURLWithPath: "/")
        let json = Data("""
        {"id":0,"username":"Unknown","permalink":"unknown","permalink_url":"\(fallbackURL.absoluteString)"}
        """.utf8)
        return (try? JSONDecoder().decode(User.self, from: json))
            ?? User(id: "0", username: "Unknown", permalink: "unknown", permalinkURL: fallbackURL)
    }()

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(timestampMillis, forKey: .timestampMillis)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encode(user, forKey: .user)
    }
}

extension Comment {
    var searchQuery: String? {
        var text = body

        text = text.replacingOccurrences(
            of: "@[\\w.-]+", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\b\\d{1,2}:\\d{2}(:\\d{2})?\\b", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "https?://\\S+", with: " ", options: .regularExpression
        )
        text = text.unicodeScalars
            .filter { !$0.properties.isEmojiPresentation && !$0.properties.isEmoji || $0.isASCII }
            .reduce(into: "") { $0.unicodeScalars.append($1) }

        text = text
            .replacingOccurrences(of: "[?!]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count >= 3 else { return nil }
        return text
    }
}
