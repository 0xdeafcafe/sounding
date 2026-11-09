import Foundation

enum LibraryNames {
    private static let quotePairs: [(String, String)] = [
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
        ("\u{00AB}", "\""), ("\u{00BB}", "\""), ("\u{2033}", "\""), ("`", "'"),
    ]

    private static let creditSeparators: Set<String> = [
        "feat", "feat.", "ft", "ft.", "featuring", "with", "vs", "vs.", "x", "and", "b2b", "presents", "pres.", "meets",
    ]

    private static let featureMarkers = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", "(feat", "[feat", "(ft.", "(ft ", "[ft"]

    private static let albumSuffixWords: Set<String> = [
        "deluxe", "edition", "remaster", "remastered", "expanded", "special", "anniversary", "bonus", "explicit",
        "clean", "version", "single", "ep", "lp", "album", "reissue", "collector's", "collectors",
    ]

    private static let accountNoise: Set<String> = ["official", "music", "officialmusic", "dj", "records", "uk", "us"]

    static func fold(_ raw: String) -> String {
        var text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB"))
            .lowercased()
        for (from, to) in quotePairs { text = text.replacingOccurrences(of: from, with: to) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ raw: String) -> [String] {
        let text = fold(raw)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " and ")
            .replacingOccurrences(of: "'", with: "")
        let kept = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").map(String.init)
    }

    static func key(_ raw: String) -> String {
        var parts = words(raw)
        if parts.count > 1, parts.first == "the" { parts.removeFirst() }
        return parts.joined(separator: " ")
    }

    static func compactKey(_ raw: String) -> String {
        key(raw).replacingOccurrences(of: " ", with: "")
    }

    static func accountKey(_ raw: String) -> String {
        var parts = words(raw)
        if parts.count > 1, parts.first == "the" { parts.removeFirst() }
        while parts.count > 1, let last = parts.last, accountNoise.contains(last) { parts.removeLast() }
        return parts.joined()
    }

    static func primaryArtist(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var cut: String.Index?
        for marker in featureMarkers {
            guard let range = text.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            if cut.map({ range.lowerBound < $0 }) ?? true { cut = range.lowerBound }
        }
        if let cut { text = String(text[..<cut]) }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,")))
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    static func artistKey(_ raw: String) -> String {
        let primary = key(primaryArtist(raw))
        return primary.isEmpty ? fold(raw) : primary
    }

    static func credits(_ raw: String) -> [String] {
        var text = fold(raw)
        for mark in [",", "/", "(", ")", "[", "]", "&", "+", "\u{00D7}", ";"] {
            text = text.replacingOccurrences(of: mark, with: " | ")
        }
        var groups: [[String]] = [[]]
        for word in text.split(separator: " ").map(String.init) {
            if word == "|" || creditSeparators.contains(word) {
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
            } else {
                groups[groups.count - 1].append(word)
            }
        }
        var seen = Set<String>()
        var out: [String] = []
        for group in groups {
            let credit = key(group.joined(separator: " "))
            guard !credit.isEmpty, seen.insert(credit).inserted else { continue }
            out.append(credit)
        }
        return out
    }

    static func creditKeys(_ raw: String) -> Set<String> {
        Set(credits(raw)).union([artistKey(raw)])
    }

    static func albumTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lowered = text.lowercased()
            for suffix in [" - single", " - ep", " - lp", " - album", " – single", " – ep", " ep", " lp"] where lowered.hasSuffix(suffix) {
                let stripped = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    text = stripped
                    changed = true
                }
                break
            }
            if changed { continue }
            guard let last = text.last, last == ")" || last == "]" else { continue }
            let open: Character = last == ")" ? "(" : "["
            guard let start = text.lastIndex(of: open) else { continue }
            let inner = words(String(text[text.index(after: start)..<text.index(before: text.endIndex)]))
            guard !inner.isEmpty, inner.contains(where: { albumSuffixWords.contains($0) || Int($0) != nil && $0.count == 4 }),
                  inner.allSatisfy({ albumSuffixWords.contains($0) || Int($0) != nil || $0.first?.isNumber == true || $0.count <= 3 || $0 == "track" || $0 == "tracks" }) else { continue }
            let stripped = String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                text = stripped
                changed = true
            }
        }
        return text
    }

    static func albumKey(_ raw: String) -> String {
        key(albumTitle(raw))
    }

    static func trackKey(_ raw: String) -> String {
        TrackMatcher.normalise(raw)
    }

    static func matches(_ name: String, query: String) -> Bool {
        let needle = fold(query)
        guard !needle.isEmpty else { return true }
        if fold(name).contains(needle) { return true }
        let compactNeedle = compactKey(query)
        return !compactNeedle.isEmpty && compactKey(name).contains(compactNeedle)
    }
}

struct LibraryArtistCandidate: Sendable {
    let user: User
    var isFollowed = false
    var likedTrackCount = 0
    var likedAlbumCount = 0
}

struct LibraryLocalAlbumProfile: Sendable {
    let id: String
    let title: String
    let artistKeys: Set<String>
    let trackCount: Int
}

enum LibraryIdentityMatcher {
    static let artistThreshold = 0.75
    static let artistMargin = 0.15
    static let albumThreshold = 0.85
    static let trackDurationTolerance: TimeInterval = 3

    struct CandidateIndex: Sendable {
        let byKey: [String: [LibraryArtistCandidate]]

        init(_ candidates: [LibraryArtistCandidate]) {
            var byKey: [String: [LibraryArtistCandidate]] = [:]
            for candidate in candidates {
                for key in LibraryIdentityMatcher.nameKeys(of: candidate.user) {
                    byKey[key, default: []].append(candidate)
                }
            }
            self.byKey = byKey.mapValues { list in
                var seen = Set<String>()
                return list.filter { seen.insert($0.user.id).inserted }
            }
        }

        func candidates(for name: String) -> [LibraryArtistCandidate] {
            var seen = Set<String>()
            var out: [LibraryArtistCandidate] = []
            for key in LibraryIdentityMatcher.lookupKeys(for: name) {
                for candidate in byKey[key] ?? [] where seen.insert(candidate.user.id).inserted {
                    out.append(candidate)
                }
            }
            return out
        }
    }

    static func nameKeys(of user: User) -> Set<String> {
        var keys = Set<String>()
        for name in [user.displayName, user.username, user.fullName ?? "", user.permalink] where !name.isEmpty {
            keys.insert(LibraryNames.compactKey(name))
            keys.insert(LibraryNames.accountKey(name))
        }
        keys.remove("")
        return keys
    }

    static func lookupKeys(for name: String) -> [String] {
        let primary = LibraryNames.primaryArtist(name)
        return Array(Set([LibraryNames.compactKey(primary), LibraryNames.accountKey(primary)]).subtracting([""]))
    }

    static func nameScore(local name: String, user: User) -> Double {
        let primary = LibraryNames.primaryArtist(name)
        let localKey = LibraryNames.key(primary)
        guard !localKey.isEmpty else { return 0 }
        if [user.displayName, user.username, user.fullName ?? ""].contains(where: { !$0.isEmpty && LibraryNames.key($0) == localKey }) {
            return 0.6
        }
        let compact = LibraryNames.compactKey(primary)
        if [user.displayName, user.username, user.permalink].contains(where: { LibraryNames.compactKey($0) == compact }) {
            return 0.55
        }
        let account = LibraryNames.accountKey(primary)
        if [user.displayName, user.username, user.permalink].contains(where: { LibraryNames.accountKey($0) == account }) {
            return 0.5
        }
        return 0
    }

    static func artistScore(local name: String, candidate: LibraryArtistCandidate, sharedTracks: Int) -> Double {
        let name = nameScore(local: name, user: candidate.user)
        guard name > 0 else { return 0 }
        var score = name
        if candidate.isFollowed { score += 0.2 }
        score += min(0.15, 0.05 * Double(candidate.likedTrackCount))
        if candidate.likedAlbumCount > 0 { score += 0.1 }
        score += min(0.25, 0.1 * Double(sharedTracks))
        if candidate.user.verified == true { score += 0.05 }
        return min(score, 1)
    }

    static func bestArtist(
        local name: String,
        in index: CandidateIndex,
        sharedTracks: [String: Int]
    ) -> (user: User, confidence: Double)? {
        let scored = index.candidates(for: name)
            .map { ($0.user, artistScore(local: name, candidate: $0, sharedTracks: sharedTracks[$0.user.id] ?? 0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= artistThreshold else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < artistMargin { return nil }
        return (best.0, best.1)
    }

    static func rankedCandidates(for name: String, among users: [User]) -> [User] {
        let needle = LibraryNames.compactKey(LibraryNames.primaryArtist(name))
        func rank(_ user: User) -> Int {
            let score = nameScore(local: name, user: user)
            if score > 0 { return Int(score * 100) }
            let names = [user.displayName, user.username, user.permalink].map(LibraryNames.compactKey)
            if !needle.isEmpty, names.contains(where: { $0.contains(needle) || (!$0.isEmpty && needle.contains($0)) }) { return 20 }
            return 0
        }
        return users
            .map { ($0, rank($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.displayName.localizedStandardCompare(rhs.0.displayName) == .orderedAscending
            }
            .map(\.0)
    }

    static func albumScore(_ local: LibraryLocalAlbumProfile, playlist: Playlist, linkedUserIDs: Set<String>) -> Double {
        guard LibraryNames.albumKey(local.title) == LibraryNames.albumKey(playlist.title),
              !LibraryNames.albumKey(local.title).isEmpty else { return 0 }
        var score = 0.5
        if linkedUserIDs.contains(playlist.user.id) {
            score += 0.3
        } else if !local.artistKeys.isDisjoint(with: LibraryNames.creditKeys(playlist.user.displayName))
                    || !local.artistKeys.isDisjoint(with: [LibraryNames.key(playlist.user.username)])
                    || local.artistKeys.map({ $0.replacingOccurrences(of: " ", with: "") }).contains(LibraryNames.accountKey(playlist.user.username)) {
            score += 0.25
        } else {
            return 0
        }
        let count = playlist.trackCount
        if count > 0, count == local.trackCount {
            score += 0.2
        } else if count > 0, abs(count - local.trackCount) <= 2 {
            score += 0.1
        }
        return min(score, 1)
    }

    static func bestAlbum(_ local: LibraryLocalAlbumProfile, among playlists: [Playlist], linkedUserIDs: Set<String>) -> (playlist: Playlist, confidence: Double)? {
        let scored = playlists
            .map { ($0, albumScore(local, playlist: $0, linkedUserIDs: linkedUserIDs)) }
            .filter { $0.1 >= albumThreshold }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        if scored.count > 1, scored[1].1 >= best.1 - 0.05, scored[1].0.id != best.0.id { return nil }
        return (best.0, best.1)
    }

    struct TrackIndex: Sendable {
        let byTitle: [String: [Track]]

        init(_ tracks: [Track]) {
            var byTitle: [String: [Track]] = [:]
            var seen = Set<String>()
            for track in tracks where !track.isLocal && seen.insert(track.id).inserted {
                var keys = Set([LibraryNames.trackKey(track.title)])
                for variant in TrackMatcher.variants(title: track.title, artist: track.user.displayName) {
                    keys.insert(variant.title)
                }
                for key in keys where !key.isEmpty {
                    byTitle[key, default: []].append(track)
                }
            }
            self.byTitle = byTitle
        }
    }

    static func bestTrack(for local: Track, in index: TrackIndex, linkedUserIDs: Set<String>) -> Track? {
        let key = LibraryNames.trackKey(local.title)
        guard !key.isEmpty, let candidates = index.byTitle[key] else { return nil }
        let localArtist = local.user.displayName
        let localCredits = LibraryNames.creditKeys(localArtist)
        let localNormalised = TrackMatcher.normalise(localArtist)
        var hits: [String: Track] = [:]
        for candidate in candidates {
            if local.duration > 0, candidate.duration > 0, abs(local.duration - candidate.duration) > trackDurationTolerance { continue }
            let byLink = linkedUserIDs.contains(candidate.user.id)
            let titleArtist = TrackMatcher.variants(title: candidate.title, artist: candidate.user.displayName)
                .contains { $0.title == key && TrackMatcher.artistsMatch($0.artist, localNormalised) }
            let byCredit = !localCredits.isDisjoint(with: LibraryNames.creditKeys(candidate.user.displayName))
                || localCredits.contains(LibraryNames.accountKey(candidate.user.username))
            let byName = !localNormalised.isEmpty && titleArtist
            guard byLink || byCredit || byName else { continue }
            if local.duration <= 0 || candidate.duration <= 0, !(byLink || byCredit) { continue }
            hits[candidate.id] = candidate
        }
        return hits.count == 1 ? hits.values.first : nil
    }
}
