import Foundation
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#endif

enum DeckIdentitySource: String, Codable, Sendable {
    case descriptionTracklist
    case listenerComment

    var displayName: String {
        switch self {
        case .descriptionTracklist: return "Uploader track list"
        case .listenerComment:      return "Listener comment"
        }
    }
}

struct DeckIdentity: Equatable, Sendable {
    let label: String
    let searchQuery: String
    let source: DeckIdentitySource
    let evidence: String
    let confidence: Double
    let startsAt: TimeInterval?
    let commentID: String?

    init(
        label: String,
        searchQuery: String,
        source: DeckIdentitySource,
        evidence: String,
        confidence: Double,
        startsAt: TimeInterval?,
        commentID: String? = nil
    ) {
        self.label = label
        self.searchQuery = searchQuery
        self.source = source
        self.evidence = evidence
        self.confidence = confidence
        self.startsAt = startsAt
        self.commentID = commentID
    }
}

/// Best-effort identification of the record playing inside a long mix. It
/// deliberately presents provenance and confidence: descriptions are strong
/// evidence, while listener comments are useful hints rather than metadata.
enum DeckIdentityResolver {
    private struct TracklistEntry {
        let time: TimeInterval
        let label: String
        let evidence: String
    }

    private struct IdentificationExchange {
        let request: Comment
        let answer: Comment
        let position: TimeInterval
    }

    static func resolve(track: Track, comments: [Comment], at position: TimeInterval) -> DeckIdentity? {
        guard isLikelyMix(track) else { return nil }

        let entries = tracklistEntries(in: track.description ?? "")
        if let entry = entries.last(where: { $0.time <= position + 2 }) {
            return DeckIdentity(
                label: entry.label,
                searchQuery: searchText(entry.label),
                source: .descriptionTracklist,
                evidence: entry.evidence,
                confidence: 0.94,
                startsAt: entry.time
            )
        }

        return commentIdentities(comments: comments)
            .filter { identity in
                guard let startsAt = identity.startsAt else { return false }
                return abs(startsAt - position) <= 30
            }
            .max { lhs, rhs in
                abs((lhs.startsAt ?? 0) - position) > abs((rhs.startsAt ?? 0) - position)
            }
    }

    /// Listener text becomes set-list metadata only when it is an answer to a
    /// track-ID request. Timestamp proximity by itself is never evidence.
    static func commentIdentities(comments: [Comment]) -> [DeckIdentity] {
        identificationExchanges(comments: comments).compactMap { exchange in
            guard isIdentificationRequest(exchange.request.body) else { return nil }
            let label = answerLabel(exchange.answer.body)
            guard looksLikeIdentificationAnswer(label) else { return nil }
            return identity(label: label, exchange: exchange, semantic: false)
        }
    }

    @MainActor
    static func semanticCommentIdentities(comments: [Comment]) async -> [DeckIdentity] {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return [] }
        let allExchanges = identificationExchanges(comments: comments)
        let deterministicAnswerIDs = Set(allExchanges.compactMap { exchange in
            let label = answerLabel(exchange.answer.body)
            return isIdentificationRequest(exchange.request.body) && looksLikeIdentificationAnswer(label)
                ? exchange.answer.id : nil
        })
        let exchanges = allExchanges
            .filter { !deterministicAnswerIDs.contains($0.answer.id) }
            .prefix(24)
        guard !exchanges.isEmpty else { return [] }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            Decide whether a SoundCloud comment reply answers a request for the identity of the track playing in a DJ set. The reply must actually provide a track identity, normally artist and title; thanks, reactions, guesses without a name, and unrelated chat are NO. Never invent or expand a title. Reply with exactly NO, or YES followed by a tab and the track label copied from the reply.
            """
        )
        var identities: [DeckIdentity] = []
        for exchange in exchanges {
            guard !Task.isCancelled else { break }
            let prompt = "Request: \(exchange.request.body)\nReply: \(exchange.answer.body)"
            guard let response = try? await session.respond(to: prompt) else { continue }
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.uppercased().hasPrefix("YES") else { continue }
            let proposed = String(raw.dropFirst(3))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ":-–—\t")))
            let label = cleanedLabel(proposed.isEmpty ? answerLabel(exchange.answer.body) : proposed)
            guard label.count >= 3, label.count <= 120, !isGenericReaction(label) else { continue }
            identities.append(identity(label: label, exchange: exchange, semantic: true))
        }
        return identities
        #else
        return []
        #endif
    }

    static func identificationRequestCount(comments: [Comment], at position: TimeInterval) -> Int {
        comments.filter { comment in
            guard let time = comment.timeInTrack, abs(time - position) <= 30 else { return false }
            return isIdentificationRequest(comment.body)
        }.count
    }

    /// Exact moments where listeners ask for an ID are high-value Shazam
    /// probes, even though the request text is intentionally not metadata.
    static func identificationRequestPositions(comments: [Comment]) -> [TimeInterval] {
        var positions: [TimeInterval] = []
        for comment in comments {
            guard let time = comment.timeInTrack, time >= 0,
                  isIdentificationRequest(comment.body) else { continue }
            if !positions.contains(where: { abs($0 - time) < 5 }) { positions.append(time) }
        }
        return positions.sorted()
    }

    static func descriptionIdentities(for track: Track) -> [DeckIdentity] {
        tracklistEntries(in: track.description ?? "").map { entry in
            DeckIdentity(
                label: entry.label,
                searchQuery: searchText(entry.label),
                source: .descriptionTracklist,
                evidence: entry.evidence,
                confidence: 0.94,
                startsAt: entry.time
            )
        }
    }

    static func isLikelyMix(_ track: Track) -> Bool {
        if CollectionKind.classify(trackDurationSeconds: track.duration) == .set { return true }
        let text = "\(track.title) \(track.description ?? "")"
        return text.range(
            of: #"(?i)\b(dj\s*set|mixtape|mix\s*session|guest\s*mix|radio\s*show|tracklist)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func tracklistEntries(in description: String) -> [TracklistEntry] {
        let pattern = #"(?m)^\s*[\[(]?(\d{1,2}:\d{2}(?::\d{2})?)[\])]?\s*(?:[-–—|.:]\s*)?(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(description.startIndex..<description.endIndex, in: description)
        return regex.matches(in: description, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let timeRange = Range(match.range(at: 1), in: description),
                  let labelRange = Range(match.range(at: 2), in: description),
                  let time = parseTimestamp(String(description[timeRange])) else { return nil }
            let original = String(description[Range(match.range, in: description) ?? labelRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = cleanedLabel(String(description[labelRange]))
            guard label.count >= 3 else { return nil }
            return TracklistEntry(time: time, label: label, evidence: original)
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func cleanedLabel(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:free\s+download|download)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^[#\d.\s]+(?=[A-Za-z])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "-–—|")))
    }

    private static func searchText(_ label: String) -> String {
        label
            .replacingOccurrences(of: #"\s*\[[^\]]*(?:label|release|out now)[^\]]*\]\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func identificationExchanges(comments: [Comment]) -> [IdentificationExchange] {
        let indexed = comments.enumerated().map { (comment: $1, index: $0) }
        let ordered = indexed.sorted { lhs, rhs in
            switch (lhs.comment.createdAt, rhs.comment.createdAt) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.index < rhs.index
            }
        }

        var exchanges: [IdentificationExchange] = []
        for (answerOffset, answerEntry) in ordered.enumerated() {
            let answer = answerEntry.comment
            guard let mention = CommentMentionParser.mentionToken(in: answer.body),
                  let answerTime = answer.timeInTrack else { continue }
            let candidates = ordered[..<answerOffset].reversed().map(\.comment).filter { candidate in
                guard candidate.id != answer.id,
                      candidate.user.id != answer.user.id,
                      let requestTime = candidate.timeInTrack,
                      abs(requestTime - answerTime) <= 30 else { return false }
                return userKeys(for: candidate.user).contains(mention)
            }
            // Prefer an explicit ID request even if that listener added another
            // comment before somebody answered. The latest linked comment is a
            // semantic fallback for less formulaic requests such as “need this”.
            let request = candidates.first(where: { isIdentificationRequest($0.body) })
                ?? candidates.first
            guard let request, let position = request.timeInTrack else { continue }
            exchanges.append(IdentificationExchange(request: request, answer: answer, position: position))
        }
        return exchanges
    }

    private static func answerLabel(_ body: String) -> String {
        cleanedLabel(body.replacingOccurrences(of: #"^@[\w.-]+\s*[:,\-–—]?\s*"#, with: "", options: .regularExpression))
    }

    private static func looksLikeIdentificationAnswer(_ label: String) -> Bool {
        guard label.count >= 5, label.count <= 120,
              !isIdentificationRequest(label), !isGenericReaction(label) else { return false }
        if label.range(of: #"\s[-–—]\s"#, options: .regularExpression) != nil { return true }
        if label.range(of: #"(?i)\b.+\s+by\s+.+\b"#, options: .regularExpression) != nil { return true }
        if label.range(of: #"(?i)\b(remix|edit|bootleg|mashup|vip|dub|rework)\b"#, options: .regularExpression) != nil,
           label.split(whereSeparator: \Character.isWhitespace).count >= 2 { return true }
        return false
    }

    private static func identity(
        label: String,
        exchange: IdentificationExchange,
        semantic: Bool
    ) -> DeckIdentity {
        DeckIdentity(
            label: label,
            searchQuery: searchText(label),
            source: .listenerComment,
            evidence: "ID request #\(exchange.request.id) answered by \(exchange.answer.user.displayName): “\(exchange.answer.body)” (answer #\(exchange.answer.id))",
            confidence: semantic ? 0.72 : 0.86,
            startsAt: exchange.position,
            commentID: exchange.answer.id
        )
    }

    private static func userKeys(for user: User) -> Set<String> {
        [user.permalink.lowercased(), user.username.lowercased()]
    }

    private static func isIdentificationRequest(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(\b(track|tune|song)\s*(id|name)\b|\bid\s*\??\s*$|what('s| is)\s+(this|the)\s+(track|song|tune)|anyone\s+know)"#,
            options: .regularExpression
        ) != nil
    }

    private static func isGenericReaction(_ text: String) -> Bool {
        text.range(
            of: #"(?i)^\s*(fire|wow|nice|sick|love\s+this|tune|banger|drop|yes|yess+|amazing|insane)[!\s🔥❤️]*$"#,
            options: .regularExpression
        ) != nil
    }
}
