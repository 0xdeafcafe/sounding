import Foundation
import CryptoKit

struct TrackLink: Codable, Hashable, Sendable, Identifiable {
    let trackId: String
    var title: String
    var artist: String
    var durationMillis: Int64
    var isrc: String?
    var fileHash: String?
    var rekordboxTrackId: String?
    var updatedAtMillis: Int64
    var writerId: String

    var id: String { trackId }

    init(
        trackId: String,
        title: String,
        artist: String,
        durationMillis: Int64,
        isrc: String? = nil,
        fileHash: String? = nil,
        rekordboxTrackId: String? = nil,
        updatedAtMillis: Int64 = CueTime.nowMillis(),
        writerId: String = ""
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.durationMillis = durationMillis
        self.isrc = isrc
        self.fileHash = fileHash
        self.rekordboxTrackId = rekordboxTrackId
        self.updatedAtMillis = updatedAtMillis
        self.writerId = writerId
    }

    static func remoteWins(local: TrackLink?, remote: TrackLink) -> Bool {
        guard let local else { return true }
        if local == remote { return false }
        if remote.updatedAtMillis != local.updatedAtMillis { return remote.updatedAtMillis > local.updatedAtMillis }
        return remote.writerId > local.writerId
    }
}

struct TrackLinkFile: Hashable, Sendable {
    let trackId: String
    let bookmark: Data
    let path: String
}

enum TrackFileHash {
    static let edgeBytes = 1 << 20

    static func hash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var hasher = SHA256()
        var sizeBytes = size.littleEndian
        withUnsafeBytes(of: &sizeBytes) { hasher.update(bufferPointer: $0) }
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: edgeBytes) { hasher.update(data: head) }
        if size > UInt64(edgeBytes) {
            try? handle.seek(toOffset: size - UInt64(min(UInt64(edgeBytes), size)))
            if let tail = try? handle.read(upToCount: edgeBytes) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct MatchCandidate: Hashable, Sendable, Identifiable {
    let trackId: String
    let title: String
    let artist: String
    let durationSeconds: TimeInterval
    let isrc: String?

    var id: String { trackId }

    init(trackId: String, title: String, artist: String, durationSeconds: TimeInterval, isrc: String? = nil) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.isrc = isrc
    }
}

struct MatchQuery: Hashable, Sendable {
    let title: String
    let artist: String
    let durationSeconds: TimeInterval
    let isrc: String?
}

enum MatchOutcome: Hashable, Sendable {
    case matched(String)
    case ambiguous([String])
    case missing

    var matchedTrackId: String? {
        if case .matched(let id) = self { return id }
        return nil
    }
}

enum TrackMatcher {

    static let durationTolerance: TimeInterval = 2

    struct Variant: Hashable, Sendable {
        let title: String
        let artist: String
    }

    struct Index: Sendable {
        let byISRC: [String: [MatchCandidate]]
        let byTitle: [String: [(MatchCandidate, Variant)]]

        init(_ candidates: [MatchCandidate]) {
            var isrc: [String: [MatchCandidate]] = [:]
            var title: [String: [(MatchCandidate, Variant)]] = [:]
            for candidate in candidates {
                if let code = candidate.isrc.flatMap(TrackMatcher.normaliseISRC) {
                    isrc[code, default: []].append(candidate)
                }
                for variant in TrackMatcher.variants(title: candidate.title, artist: candidate.artist) {
                    title[variant.title, default: []].append((candidate, variant))
                }
            }
            byISRC = isrc
            byTitle = title
        }
    }

    static func match(_ query: MatchQuery, in index: Index) -> MatchOutcome {
        if let code = query.isrc.flatMap(normaliseISRC), let hits = index.byISRC[code], !hits.isEmpty {
            let ids = Array(Set(hits.map(\.trackId))).sorted()
            return ids.count == 1 ? .matched(ids[0]) : .ambiguous(ids)
        }
        var ids = Set<String>()
        for variant in variants(title: query.title, artist: query.artist) where !variant.title.isEmpty {
            for (candidate, candidateVariant) in index.byTitle[variant.title] ?? [] {
                guard artistsMatch(candidateVariant.artist, variant.artist) else { continue }
                if query.durationSeconds > 0, candidate.durationSeconds > 0,
                   abs(candidate.durationSeconds - query.durationSeconds) > durationTolerance { continue }
                ids.insert(candidate.trackId)
            }
        }
        let sorted = ids.sorted()
        switch sorted.count {
        case 0:  return .missing
        case 1:  return .matched(sorted[0])
        default: return .ambiguous(sorted)
        }
    }

    static func match(_ query: MatchQuery, candidates: [MatchCandidate]) -> MatchOutcome {
        match(query, in: Index(candidates))
    }

    static func normaliseISRC(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.count == 12 ? cleaned : nil
    }

    static func variants(title: String, artist: String) -> [Variant] {
        var out = [Variant(title: normalise(title), artist: normalise(artist))]
        for separator in [" - ", " – ", " — "] {
            guard let range = title.range(of: separator) else { continue }
            let left = normalise(String(title[..<range.lowerBound]))
            let right = normalise(String(title[range.upperBound...]))
            if !left.isEmpty, !right.isEmpty { out.append(Variant(title: right, artist: left)) }
            break
        }
        return out
    }

    static func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return true }
        if lhs == rhs { return true }
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        return left.isSubset(of: right) || right.isSubset(of: left)
    }

    private static let droppedPhrases = [
        "original mix", "original version", "extended mix", "radio edit", "official audio", "free download",
    ]

    static func normalise(_ raw: String) -> String {
        var text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB"))
            .lowercased()
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = text.range(of: marker) {
                let tail = text[range.upperBound...]
                if let close = tail.firstIndex(where: { $0 == ")" || $0 == "]" }) {
                    text.removeSubrange(range.lowerBound..<close)
                } else {
                    text.removeSubrange(range.lowerBound..<text.endIndex)
                }
            }
        }
        for phrase in droppedPhrases {
            text = text.replacingOccurrences(of: "(\(phrase))", with: " ")
                .replacingOccurrences(of: "[\(phrase)]", with: " ")
        }
        text = text.replacingOccurrences(of: "&", with: " and ")
        let kept = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
