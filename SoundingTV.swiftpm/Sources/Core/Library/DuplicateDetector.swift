import Foundation

struct DuplicateCandidate: Identifiable, Hashable, Sendable {
    enum Source: Int, Comparable, Sendable {
        case preview = 0
        case stream = 1
        case downloaded = 2
        case localFile = 3
        case localLossless = 4

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }

        var isLocal: Bool { self == .localFile || self == .localLossless }
    }

    let id: String
    let title: String
    let artist: String
    var alternateArtists: [String] = []
    let duration: TimeInterval
    let source: Source
    var bitrate: Int = 0
    var format: String?
    var bpm: Double?
    var key: CamelotKey?
    var hasCues = false
    var filePath: String?
    var contentHash: String?

    var hasAnalysis: Bool { bpm != nil || key != nil }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    enum Confidence: Int, Comparable, Sendable {
        case possible = 0
        case likely = 1
        case sameFile = 2

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let members: [DuplicateCandidate]
    let confidence: Confidence
    let score: Double

    init(members: [DuplicateCandidate], confidence: Confidence, score: Double) {
        let ranked = DuplicateDetector.ranked(members)
        self.members = ranked
        self.id = DuplicateDetector.signature(ranked.map(\.id))
        self.confidence = confidence
        self.score = score
    }

    var keeper: DuplicateCandidate { members[0] }
    var keeperID: String { members[0].id }
    var memberIDs: Set<String> { Set(members.map(\.id)) }

    func markingCues(_ ids: Set<String>) -> DuplicateGroup {
        let marked = members.map { member -> DuplicateCandidate in
            var copy = member
            copy.hasCues = copy.hasCues || ids.contains(member.id)
            return copy
        }
        return DuplicateGroup(members: marked, confidence: confidence, score: score)
    }

    func restricted(to ids: Set<String>) -> DuplicateGroup? {
        let kept = members.filter { ids.contains($0.id) }
        guard kept.count > 1 else { return nil }
        return DuplicateGroup(members: kept, confidence: confidence, score: score)
    }
}

struct DuplicateIdentity: Hashable, Sendable {
    let title: String
    let version: String
    let primaryArtists: Set<String>
    let allArtists: Set<String>
    let namesArtistInTitle: Bool

    var bucket: String { "\(title)|\(version)" }
}

enum DuplicateDetector {
    static let durationTolerance: TimeInterval = 2
    static let likelyScore = 0.8

    private static let dashSeparators = [" - ", " – ", " — ", " -- ", " | ", " // "]
    private static let featureMarkers = [" feat. ", " feat ", " ft. ", " ft ", " featuring "]
    private static let featureWords: Set<String> = ["feat", "ft", "featuring", "with"]

    private static let noiseWords: Set<String> = [
        "original", "mix", "version", "free", "download", "dl", "out", "now", "premiere", "official", "audio",
        "video", "hq", "hd", "explicit", "clean", "remaster", "remastered", "buy", "click", "for", "forthcoming",
        "soon", "exclusive", "full", "track", "lyric", "lyrics", "visualizer", "visualiser", "wav", "mp3",
        "320", "320kbps", "kbps", "fdl", "repost", "supported", "by", "ep", "lp", "single",
    ]

    private static let versionWords: Set<String> = [
        "extended", "radio", "edit", "remix", "rmx", "dub", "vip", "live", "rework", "bootleg", "flip", "refix",
        "reprise", "instrumental", "acapella", "acappella", "club", "reedit", "remode", "cover", "demo",
        "acoustic", "rerub", "mashup", "sped", "slowed", "nightcore", "stripped", "orchestral", "interpretation",
        "remixed", "dubmix", "short", "intro", "outro", "redux", "version",
    ]

    private static let versionFillers: Set<String> = ["mix", "version", "the", "a", "s"]

    static func groups(in input: [DuplicateCandidate]) -> [DuplicateGroup] {
        var seen = Set<String>()
        let candidates = input.filter { seen.insert($0.id).inserted }
        guard candidates.count > 1 else { return [] }

        var parent = Array(candidates.indices)
        var edgeScore = [Double](repeating: 0, count: candidates.count)
        var exact = [Bool](repeating: false, count: candidates.count)

        func find(_ index: Int) -> Int {
            var node = index
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }

        func union(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            if left != right { parent[right] = left }
        }

        func link(_ lhs: Int, _ rhs: Int, score: Double, sameFile: Bool) {
            union(lhs, rhs)
            for index in [lhs, rhs] {
                edgeScore[index] = max(edgeScore[index], score)
                if sameFile { exact[index] = true }
            }
        }

        var byFile: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            if let path = candidate.filePath, !path.isEmpty { byFile["path:\(path)", default: []].append(index) }
            if let hash = candidate.contentHash, !hash.isEmpty { byFile["hash:\(hash)", default: []].append(index) }
        }
        for indices in byFile.values where indices.count > 1 {
            for other in indices.dropFirst() { link(indices[0], other, score: 1, sameFile: true) }
        }

        var identities: [DuplicateIdentity] = []
        identities.reserveCapacity(candidates.count)
        var buckets: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            let identity = self.identity(of: candidate)
            identities.append(identity)
            guard !identity.title.isEmpty else { continue }
            buckets[identity.bucket, default: []].append(index)
        }

        for indices in buckets.values where indices.count > 1 {
            for (offset, lhs) in indices.enumerated() {
                for rhs in indices[(offset + 1)...] {
                    guard let score = pairScore(candidates[lhs], identities[lhs], candidates[rhs], identities[rhs]) else { continue }
                    link(lhs, rhs, score: score, sameFile: false)
                }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for index in candidates.indices {
            clusters[find(index), default: []].append(index)
        }

        return clusters.values
            .filter { $0.count > 1 }
            .map { indices in
                let members = indices.map { candidates[$0] }
                let allExact = indices.allSatisfy { exact[$0] }
                let score = indices.map { edgeScore[$0] }.min() ?? 0
                let confidence: DuplicateGroup.Confidence = allExact ? .sameFile : (score >= likelyScore ? .likely : .possible)
                return DuplicateGroup(members: members, confidence: confidence, score: allExact ? 1 : score)
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                let left = lhs.keeper.title.localizedLowercase
                let right = rhs.keeper.title.localizedLowercase
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
    }

    static func pairScore(
        _ lhs: DuplicateCandidate, _ lhsIdentity: DuplicateIdentity,
        _ rhs: DuplicateCandidate, _ rhsIdentity: DuplicateIdentity
    ) -> Double? {
        guard lhsIdentity.bucket == rhsIdentity.bucket, !lhsIdentity.title.isEmpty else { return nil }
        guard artistsMatch(lhsIdentity, rhsIdentity) else { return nil }

        var score = 0.6
        if lhs.duration > 0, rhs.duration > 0 {
            let gap = abs(lhs.duration - rhs.duration)
            guard gap <= durationTolerance else { return nil }
            score += gap <= 1 ? 0.25 : 0.15
        }
        if let left = lhs.bpm, let right = rhs.bpm, left > 0, right > 0 {
            guard tempiMatch(left, right) else { return nil }
            score += 0.1
        }
        if let left = lhs.key, let right = rhs.key {
            score += left == right ? 0.05 : -0.2
        }
        return min(score, 0.99)
    }

    static func artistsMatch(_ lhs: DuplicateIdentity, _ rhs: DuplicateIdentity) -> Bool {
        if !lhs.primaryArtists.isDisjoint(with: rhs.primaryArtists) { return true }
        if !lhs.namesArtistInTitle, !lhs.primaryArtists.isDisjoint(with: rhs.allArtists) { return true }
        if !rhs.namesArtistInTitle, !rhs.primaryArtists.isDisjoint(with: lhs.allArtists) { return true }
        return false
    }

    static func tempiMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let ratio = lhs / rhs
        return abs(ratio - 1) <= 0.02 || abs(ratio - 2) <= 0.04 || abs(ratio - 0.5) <= 0.01
    }

    static func ranked(_ members: [DuplicateCandidate]) -> [DuplicateCandidate] {
        members.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source > rhs.source }
            if lhs.bitrate != rhs.bitrate { return lhs.bitrate > rhs.bitrate }
            let left = (lhs.hasCues ? 2 : 0) + (lhs.hasAnalysis ? 1 : 0)
            let right = (rhs.hasCues ? 2 : 0) + (rhs.hasAnalysis ? 1 : 0)
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    static func signature(_ ids: [String]) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func identity(of candidate: DuplicateCandidate) -> DuplicateIdentity {
        let parsed = parse(title: candidate.title, artist: candidate.artist, alternates: candidate.alternateArtists)
        let fieldCredits = artistKeys(candidate.artist)
        let primary: Set<String>
        if let prefix = parsed.artist {
            primary = artistKeys(prefix)
        } else {
            primary = fieldCredits
        }
        var all = primary.union(fieldCredits)
        for alternate in candidate.alternateArtists { all.formUnion(artistKeys(alternate)) }
        return DuplicateIdentity(
            title: parsed.title,
            version: parsed.version,
            primaryArtists: primary,
            allArtists: all,
            namesArtistInTitle: parsed.artist != nil
        )
    }

    static func artistKeys(_ raw: String) -> Set<String> {
        var keys = Set<String>()
        for credit in LibraryNames.creditKeys(raw) {
            let compact = credit.replacingOccurrences(of: " ", with: "")
            if !compact.isEmpty { keys.insert(compact) }
        }
        let account = LibraryNames.accountKey(raw)
        if !account.isEmpty { keys.insert(account) }
        return keys
    }

    struct ParsedTitle: Hashable, Sendable {
        let artist: String?
        let title: String
        let version: String
    }

    static func parse(title raw: String, artist: String = "", alternates: [String] = []) -> ParsedTitle {
        var text = LibraryNames.fold(raw)
        var inners: [String] = []

        text = extractBrackets(from: text, into: &inners)
        text = stripLeadingNoise(text)

        let knownArtists = artistKeys(artist).union(alternates.flatMap { artistKeys($0) })
        var artistPrefix: String?
        var splitting = true
        while splitting {
            splitting = false
            guard let split = firstSplit(text) else { break }
            let (left, right) = split
            let rightWords = LibraryNames.words(right)
            let leftWords = LibraryNames.words(left)
            if isNoise(rightWords) {
                text = left
                splitting = true
            } else if isNoise(leftWords) {
                text = right
                splitting = true
            } else if artistPrefix == nil, !artistKeys(left).isDisjoint(with: knownArtists) {
                artistPrefix = left
                text = right
                splitting = true
            } else if isVersion(rightWords), rightWords.count <= 6 {
                inners.append(right)
                text = left
                splitting = true
            } else if artistPrefix == nil {
                artistPrefix = left
                text = right
                splitting = true
            }
        }

        text = cutFeatures(text)

        var kept: [String] = []
        var versions: [String] = []
        for inner in inners {
            let words = LibraryNames.words(inner)
            guard let first = words.first else { continue }
            if featureWords.contains(first) { continue }
            if isNoise(words) { continue }
            if isVersion(words) {
                let key = words.filter { !versionFillers.contains($0) }.joined(separator: " ")
                if !key.isEmpty { versions.append(key) }
                continue
            }
            kept.append(words.joined(separator: " "))
        }

        let core = LibraryNames.key(([text] + kept).joined(separator: " "))
        let prefix = artistPrefix.map { cutFeatures($0).trimmingCharacters(in: .whitespaces) }
        return ParsedTitle(
            artist: prefix.flatMap { $0.isEmpty ? nil : $0 },
            title: core,
            version: versions.sorted().joined(separator: " + ")
        )
    }

    static func isNoise(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        return words.allSatisfy { noiseWords.contains($0) || isYear($0) }
    }

    static func isVersion(_ words: [String]) -> Bool {
        words.contains { versionWords.contains($0) || $0 == "mix" }
            && !words.filter({ !versionFillers.contains($0) }).isEmpty
    }

    private static func isYear(_ word: String) -> Bool {
        word.count == 4 && Int(word).map { (1900...2100).contains($0) } == true
    }

    private static func extractBrackets(from raw: String, into inners: inout [String]) -> String {
        var text = raw
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs {
                guard let start = text.firstIndex(of: open) else { continue }
                let after = text.index(after: start)
                if let end = text[after...].firstIndex(of: close) {
                    inners.append(String(text[after..<end]))
                    text.replaceSubrange(start...end, with: " ")
                } else {
                    inners.append(String(text[after...]))
                    text.removeSubrange(start..<text.endIndex)
                }
                changed = true
            }
        }
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func stripLeadingNoise(_ raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return raw }
        let left = LibraryNames.words(String(raw[..<colon]))
        guard isNoise(left) else { return raw }
        return String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func firstSplit(_ text: String) -> (String, String)? {
        var best: Range<String.Index>?
        for separator in dashSeparators {
            guard let range = text.range(of: separator) else { continue }
            if best.map({ range.lowerBound < $0.lowerBound }) ?? true { best = range }
        }
        guard let best else { return nil }
        let left = String(text[..<best.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(text[best.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    private static func cutFeatures(_ raw: String) -> String {
        var text = raw
        var cut: String.Index?
        for marker in featureMarkers {
            guard let range = text.range(of: marker) else { continue }
            if cut.map({ range.lowerBound < $0 }) ?? true { cut = range.lowerBound }
        }
        if let cut { text = String(text[..<cut]) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
