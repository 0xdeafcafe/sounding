import Foundation

struct ScoutArtist: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var permalinkURL: URL?
    var avatarURL: URL?
    var isEnabled: Bool
    var isFollowed: Bool
    let addedAt: Date
}

struct ScoutPost: Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case track
        case playlist
    }

    let kind: Kind
    let itemID: String
    let artistID: String
    let artistName: String
    let title: String
    let duration: TimeInterval
    let postedAt: Date
    var credit: ScoutCredit? = nil

    var id: String { "\(kind.rawValue):\(itemID)" }
    var isSet: Bool { kind == .track && duration >= ScoutCopy.setThreshold }
}

struct ScoutCredit: Hashable, Codable, Sendable {
    var partners: [String]
    var postedBy: String
}

struct ScoutAlert: Hashable, Codable, Sendable {
    let postID: String
    let kind: ScoutPost.Kind
    let itemID: String
    let artistID: String
    let title: String
    let body: String
    let postedAt: Date
    var reason: String? = nil
}

enum ScoutCopy {
    static let setThreshold: TimeInterval = 30 * 60

    static func headline(for post: ScoutPost) -> String {
        if post.credit != nil { return "\(post.artistName) is on \(phrase(for: post))" }
        return "\(post.artistName) just posted \(phrase(for: post))"
    }

    static func reason(for credit: ScoutCredit) -> String {
        guard !credit.partners.isEmpty else { return "Posted by \(credit.postedBy)" }
        let names = ListFormatter.localizedString(byJoining: credit.partners)
        let uploader = ScoutSearchMatcher.normalized(credit.postedBy)
        if credit.partners.contains(where: { ScoutSearchMatcher.normalized($0) == uploader }) {
            return "b2b with \(names)"
        }
        return "b2b with \(names), posted by \(credit.postedBy)"
    }

    static func phrase(for post: ScoutPost) -> String {
        switch post.kind {
        case .playlist:
            return "a new release"
        case .track:
            guard post.isSet else { return "a new track" }
            let minutes = Int((post.duration / 60).rounded())
            let halfHours = (Double(minutes) / 30).rounded()
            if minutes >= 55, halfHours.truncatingRemainder(dividingBy: 2) == 0, abs(Double(minutes) - halfHours * 30) <= 10 {
                return "a \(Int(halfHours / 2))-hour set"
            }
            let rounded = Int((Double(minutes) / 5).rounded()) * 5
            return "a \(rounded)-minute set"
        }
    }

    static func alert(for post: ScoutPost) -> ScoutAlert {
        ScoutAlert(
            postID: post.id,
            kind: post.kind,
            itemID: post.itemID,
            artistID: post.artistID,
            title: headline(for: post),
            body: post.title,
            postedAt: post.postedAt,
            reason: post.credit.map(reason(for:))
        )
    }
}

struct ScoutLedger: Codable, Equatable, Sendable {
    var seenPostIDs: [String] = []
    var lastAlertAt: [String: Date] = [:]
    var lastArtistLookup: [String: Date] = [:]
    var lastArtistSearch: [String: Date] = [:]
    var requests: [Date] = []
    var lastFeedSeenAt: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seenPostIDs = try container.decodeIfPresent([String].self, forKey: .seenPostIDs) ?? []
        lastAlertAt = try container.decodeIfPresent([String: Date].self, forKey: .lastAlertAt) ?? [:]
        lastArtistLookup = try container.decodeIfPresent([String: Date].self, forKey: .lastArtistLookup) ?? [:]
        lastArtistSearch = try container.decodeIfPresent([String: Date].self, forKey: .lastArtistSearch) ?? [:]
        requests = try container.decodeIfPresent([Date].self, forKey: .requests) ?? []
        lastFeedSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastFeedSeenAt)
    }

    func requestCount(inHourEndingAt now: Date) -> Int {
        requests.lazy.filter { $0 <= now && now.timeIntervalSince($0) < 3600 }.count
    }

    mutating func prune(now: Date, scouts: [ScoutArtist]) {
        requests = requests.filter { now.timeIntervalSince($0) < 3600 }
        let ids = Set(scouts.map(\.id))
        lastAlertAt = lastAlertAt.filter { ids.contains($0.key) }
        lastArtistLookup = lastArtistLookup.filter { ids.contains($0.key) }
        lastArtistSearch = lastArtistSearch.filter { ids.contains($0.key) }
        if seenPostIDs.count > ScoutDetector.seenLimit {
            seenPostIDs = Array(seenPostIDs.suffix(ScoutDetector.seenLimit))
        }
    }
}

struct ScoutBudget: Sendable {
    var requestsPerHour = 6
    var minimumFeedInterval: TimeInterval = 20 * 60
    var artistLookupsPerCheck = 1
    var artistLookupInterval: TimeInterval = 6 * 60 * 60
    var searchesPerCheck = 1
    var searchInterval: TimeInterval = 12 * 60 * 60

    static let standard = ScoutBudget()
}

enum ScoutFetch: Hashable, Sendable {
    case feed
    case artist(String)
    case search(String)
}

enum ScoutPlanner {
    static func plan(scouts: [ScoutArtist], ledger: ScoutLedger, budget: ScoutBudget = .standard, now: Date) -> [ScoutFetch] {
        let enabled = scouts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return [] }
        var remaining = budget.requestsPerHour - ledger.requestCount(inHourEndingAt: now)
        guard remaining > 0 else { return [] }
        if let last = ledger.lastFeedSeenAt, now.timeIntervalSince(last) < budget.minimumFeedInterval { return [] }

        var plan: [ScoutFetch] = [.feed]
        remaining -= 1
        let due = enabled
            .filter { artist in
                guard !artist.isFollowed else { return false }
                guard let last = ledger.lastArtistLookup[artist.id] else { return true }
                return now.timeIntervalSince(last) >= budget.artistLookupInterval
            }
            .sorted { lhs, rhs in
                let left = ledger.lastArtistLookup[lhs.id] ?? .distantPast
                let right = ledger.lastArtistLookup[rhs.id] ?? .distantPast
                return left == right ? lhs.addedAt < rhs.addedAt : left < right
            }
        let lookups = due.prefix(max(0, min(remaining, budget.artistLookupsPerCheck)))
        for artist in lookups {
            plan.append(.artist(artist.id))
        }
        remaining -= lookups.count
        let searchable = enabled
            .filter { ScoutSearchMatcher.isSearchable($0.name) }
            .filter { artist in
                guard let last = ledger.lastArtistSearch[artist.id] else { return true }
                return now.timeIntervalSince(last) >= budget.searchInterval
            }
            .sorted { lhs, rhs in
                let left = ledger.lastArtistSearch[lhs.id] ?? .distantPast
                let right = ledger.lastArtistSearch[rhs.id] ?? .distantPast
                if left != right { return left < right }
                return lhs.addedAt == rhs.addedAt ? lhs.id < rhs.id : lhs.addedAt < rhs.addedAt
            }
        for artist in searchable.prefix(max(0, min(remaining, budget.searchesPerCheck))) {
            plan.append(.search(artist.id))
        }
        return plan
    }
}

enum ScoutDetector {
    static let maximumPostAge: TimeInterval = 72 * 60 * 60
    static let coalescingWindow: TimeInterval = 60 * 60
    static let seenLimit = 1000

    static func detect(_ posts: [ScoutPost], scouts: [ScoutArtist], ledger: inout ScoutLedger, now: Date) -> [ScoutAlert] {
        let enabled = Dictionary(scouts.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set(ledger.seenPostIDs)
        var candidates: [String: [ScoutPost]] = [:]

        for post in posts {
            guard let artist = enabled[post.artistID] else { continue }
            guard seen.insert(post.id).inserted else { continue }
            ledger.seenPostIDs.append(post.id)
            guard post.postedAt >= artist.addedAt,
                  now.timeIntervalSince(post.postedAt) <= maximumPostAge else { continue }
            candidates[post.artistID, default: []].append(post)
        }

        var alerts: [ScoutAlert] = []
        for artistID in candidates.keys.sorted() {
            guard let best = candidates[artistID]?.max(by: preference) else { continue }
            if let last = ledger.lastAlertAt[artistID], now.timeIntervalSince(last) < coalescingWindow { continue }
            ledger.lastAlertAt[artistID] = now
            alerts.append(ScoutCopy.alert(for: best))
        }
        if ledger.seenPostIDs.count > seenLimit {
            ledger.seenPostIDs = Array(ledger.seenPostIDs.suffix(seenLimit))
        }
        return alerts.sorted { $0.postedAt < $1.postedAt }
    }

    private static func preference(_ lhs: ScoutPost, _ rhs: ScoutPost) -> Bool {
        if lhs.isSet != rhs.isSet { return !lhs.isSet }
        if lhs.isSet, lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
        return lhs.postedAt < rhs.postedAt
    }
}

struct ScoutFetchResult: Sendable {
    var posts: [ScoutPost]
    var followedArtistIDs: Set<String> = []
    var candidates: [ScoutCandidate] = []
}

enum ScoutRunner {
    typealias Fetcher = @Sendable (ScoutFetch) async throws -> ScoutFetchResult

    struct Outcome: Sendable {
        var alerts: [ScoutAlert]
        var ledger: ScoutLedger
        var followedArtistIDs: Set<String>
        var requestsMade: Int
    }

    static func run(
        scouts: [ScoutArtist],
        ledger: ScoutLedger,
        budget: ScoutBudget = .standard,
        now: Date,
        fetch: Fetcher
    ) async -> Outcome {
        var ledger = ledger
        ledger.prune(now: now, scouts: scouts)
        let plan = ScoutPlanner.plan(scouts: scouts, ledger: ledger, budget: budget, now: now)
        var posts: [ScoutPost] = []
        var followed = Set<String>()
        var made = 0
        for step in plan {
            guard ledger.requestCount(inHourEndingAt: now) < budget.requestsPerHour else { break }
            ledger.requests.append(now)
            made += 1
            switch step {
            case .feed: ledger.lastFeedSeenAt = now
            case .artist(let id): ledger.lastArtistLookup[id] = now
            case .search(let id): ledger.lastArtistSearch[id] = now
            }
            do {
                let result = try await fetch(step)
                posts.append(contentsOf: result.posts)
                if case .search(let id) = step, let artist = scouts.first(where: { $0.id == id }) {
                    posts.append(contentsOf: ScoutSearchMatcher.posts(from: result.candidates, for: artist))
                }
                followed.formUnion(result.followedArtistIDs)
            } catch {
                break
            }
        }
        let updated = scouts.map { artist -> ScoutArtist in
            var copy = artist
            if followed.contains(artist.id) { copy.isFollowed = true }
            return copy
        }
        let alerts = ScoutDetector.detect(posts, scouts: updated, ledger: &ledger, now: now)
        return Outcome(alerts: alerts, ledger: ledger, followedArtistIDs: followed, requestsMade: made)
    }
}

struct ScoutCandidate: Hashable, Sendable {
    let itemID: String
    let title: String
    let description: String?
    let uploaderID: String
    let uploaderName: String
    let duration: TimeInterval
    let postedAt: Date
}

enum ScoutSearchMatcher {
    struct Word: Equatable {
        let key: String
        let text: String
    }

    static let strongConnectors: Set<String> = ["b2b", "b2b2b", "b3b", "btb", "back2back"]
    static let weakConnectors: Set<String> = ["vs", "x", "&", "+", "and", "with"]
    static let blocked: [[String]] = [["tribute"], ["cover"], ["karaoke"], ["type", "beat"], ["in", "the", "style", "of"], ["reupload"], ["re", "upload"]]
    static let ignoredNames: Set<String> = ["dj", "mc", "live", "mix", "set", "radio", "music", "records", "various artists", "unknown"]
    static let separators = CharacterSet(charactersIn: "-|@()[]{}:–—/,·•\"“”«»!?")

    static func words(_ value: String) -> [Word] {
        var out: [Word] = []
        for piece in value.split(whereSeparator: \.isWhitespace) {
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                let key = current.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "’", with: "")
                if !key.isEmpty { out.append(Word(key: key, text: current)) }
                current = ""
            }
            for character in piece {
                if character == "&" || character == "+" {
                    flush()
                    out.append(Word(key: String(character), text: String(character)))
                } else if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "." {
                    if character == "." { continue }
                    current.append(character)
                } else {
                    flush()
                }
            }
            flush()
        }
        return out
    }

    static func normalized(_ value: String) -> String {
        words(value).map(\.key).joined(separator: " ")
    }

    static func isSearchable(_ name: String) -> Bool {
        let key = normalized(name)
        return key.count >= 3 && !ignoredNames.contains(key)
    }

    static func posts(from candidates: [ScoutCandidate], for artist: ScoutArtist) -> [ScoutPost] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.itemID).inserted,
                  candidate.uploaderID != artist.id,
                  let credit = match(candidate, artistName: artist.name) else { return nil }
            return ScoutPost(
                kind: .track,
                itemID: candidate.itemID,
                artistID: artist.id,
                artistName: artist.name,
                title: candidate.title,
                duration: candidate.duration,
                postedAt: candidate.postedAt,
                credit: credit
            )
        }
    }

    static func match(_ candidate: ScoutCandidate, artistName: String) -> ScoutCredit? {
        let name = words(artistName).map(\.key)
        guard isSearchable(artistName), !name.isEmpty,
              candidate.duration >= ScoutCopy.setThreshold,
              normalized(candidate.uploaderName) != name.joined(separator: " ") else { return nil }
        let titleKeys = words(candidate.title).map(\.key)
        if blocked.contains(where: { range(of: $0, in: titleKeys) != nil }) { return nil }

        var mentioned = false
        for segment in segments(candidate.title) {
            switch relation(in: segment, name: name) {
            case .b2b(let partners): return ScoutCredit(partners: partners, postedBy: candidate.uploaderName)
            case .mention: mentioned = true
            case .none: continue
            }
        }
        if mentioned, name.count > 1 || name[0].count >= 5 {
            return ScoutCredit(partners: [], postedBy: candidate.uploaderName)
        }
        for line in (candidate.description ?? "").split(whereSeparator: \.isNewline).prefix(8) {
            for segment in segments(String(line)) {
                if case .b2b(let partners) = relation(in: segment, name: name, strongOnly: true) {
                    return ScoutCredit(partners: partners, postedBy: candidate.uploaderName)
                }
            }
        }
        return nil
    }

    private enum Relation {
        case none
        case mention
        case b2b([String])
    }

    private static func segments(_ text: String) -> [[Word]] {
        text.components(separatedBy: separators).map(words).filter { !$0.isEmpty }
    }

    private enum Element {
        case words([Word])
        case connector(strong: Bool)
        case target
    }

    static let stopWords: Set<String> = ["at", "live", "in", "for", "on", "presents", "pres", "from", "recorded", "full", "set", "mix", "dj"]
    static let placeholderPartners: Set<String> = ["friends", "guests", "guest", "more", "others", "special guest", "special guests"]

    private static func relation(in segment: [Word], name: [String], strongOnly: Bool = false) -> Relation {
        let keys = segment.map(\.key)
        guard let target = range(of: name, in: keys) else { return .none }
        var elements: [Element] = []
        var current: [Word] = []
        var ignoring = false
        func flush() {
            if !current.isEmpty { elements.append(.words(current)) }
            current = []
        }
        func appendConnector(strong: Bool) {
            if case .connector(let previous) = elements.last {
                elements[elements.count - 1] = .connector(strong: previous || strong)
            } else {
                elements.append(.connector(strong: strong))
            }
        }
        var index = 0
        while index < segment.count {
            if index == target.lowerBound {
                flush()
                ignoring = false
                elements.append(.target)
                index = target.upperBound
                continue
            }
            let key = keys[index]
            if key == "back", index + 2 < keys.count, keys[index + 1] == "to", keys[index + 2] == "back" {
                flush()
                ignoring = false
                appendConnector(strong: true)
                index += 3
                continue
            }
            if strongConnectors.contains(key) || weakConnectors.contains(key) {
                flush()
                ignoring = false
                appendConnector(strong: strongConnectors.contains(key))
            } else if stopWords.contains(key) {
                flush()
                ignoring = true
            } else if !ignoring {
                current.append(segment[index])
            }
            index += 1
        }
        flush()

        guard let anchor = elements.firstIndex(where: { if case .target = $0 { return true } else { return false } }) else { return .none }
        var partners: [String] = []
        var strong = false
        for direction in [1, -1] {
            var cursor = anchor
            while true {
                let link = cursor + direction
                let next = cursor + 2 * direction
                guard elements.indices.contains(link), elements.indices.contains(next),
                      case .connector(let isStrong) = elements[link],
                      case .words(let group) = elements[next] else { break }
                strong = strong || isStrong
                if (1...4).contains(group.count) {
                    let display = group.map(\.text).joined(separator: " ")
                    if !placeholderPartners.contains(group.map(\.key).joined(separator: " ")) {
                        partners.append(display)
                    }
                }
                cursor = next
            }
        }
        guard !partners.isEmpty else { return .mention }
        if strong || !strongOnly { return .b2b(partners) }
        return .mention
    }

    private static func range(of phrase: [String], in keys: [String]) -> Range<Int>? {
        guard !phrase.isEmpty, keys.count >= phrase.count else { return nil }
        for start in 0...(keys.count - phrase.count) where Array(keys[start..<(start + phrase.count)]) == phrase {
            return start..<(start + phrase.count)
        }
        return nil
    }
}
