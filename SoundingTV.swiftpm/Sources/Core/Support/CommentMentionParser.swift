import Foundation

enum CommentMentionParser {
    static func mentionToken(in body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "@" else { return nil }
        var token = trimmed.dropFirst().prefix { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == "."
        }
        while token.last == "." || token.last == "-" {
            token = token.dropLast()
        }
        guard !token.isEmpty else { return nil }
        return token.lowercased()
    }
}
