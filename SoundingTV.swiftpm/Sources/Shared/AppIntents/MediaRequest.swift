import Foundation

struct MediaRequest: Equatable, Sendable {
    enum Kind: String, Sendable {
        case any
        case track
        case artist
        case playlist
        case set
        case likes
        case station
    }

    enum Order: Sendable {
        case relevance
        case newest
    }

    var kind: Kind = .any
    var query: String?
    var artist: String?
    var mine = false
    var order: Order = .relevance
    var shuffle = false

    init(
        kind: Kind = .any,
        query: String? = nil,
        artist: String? = nil,
        mine: Bool = false,
        order: Order = .relevance,
        shuffle: Bool = false
    ) {
        self.kind = kind
        self.query = query.flatMap { MediaText.normalized($0).isEmpty ? nil : $0 }
        self.artist = artist.flatMap { MediaText.normalized($0).isEmpty ? nil : $0 }
        self.mine = mine
        self.order = order
        self.shuffle = shuffle
    }

    static func parse(_ phrase: String, kind hint: Kind = .any) -> MediaRequest {
        var words = MediaText.normalized(phrase).split(separator: " ").map(String.init)
        var shuffle = false

        var strippedVerb = false
        while let verb = Self.leadingVerbs.first(where: { words.count > $0.count && Array(words.prefix($0.count)) == $0 }) {
            if verb == ["shuffle"] { shuffle = true }
            words.removeFirst(verb.count)
            strippedVerb = true
        }
        while strippedVerb, let first = words.first, ["me", "some"].contains(first), words.count > 1 {
            words.removeFirst()
        }
        if words.count >= 2, ["on", "in", "from", "using"].contains(words[words.count - 2]), words.last == "sounding" {
            words.removeLast(2)
        }
        if words.last == "shuffled" {
            shuffle = true
            words.removeLast()
        }
        if words.count > 2, words.suffix(2) == ["on", "shuffle"] {
            shuffle = true
            words.removeLast(2)
        }

        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return MediaRequest(kind: hint, shuffle: shuffle) }

        if Self.likesPhrases.contains(text) || Self.matches(text, Self.likesPattern) {
            return MediaRequest(kind: .likes, mine: true, shuffle: shuffle)
        }
        if Self.matches(text, Self.lastLikedSetPattern) {
            return MediaRequest(kind: .set, mine: true, order: .newest, shuffle: shuffle)
        }
        if Self.nowPlayingStationPhrases.contains(text) {
            return MediaRequest(kind: .station, shuffle: shuffle)
        }
        if let seed = Self.stationSeed(in: words) {
            return MediaRequest(kind: .station, query: seed, shuffle: shuffle)
        }

        var kind = hint
        var mine = false
        if words.first == "my" {
            mine = true
            words.removeFirst()
        }
        if words.first == "the", words.count > 1 { words.removeFirst() }
        if let leading = words.first, let leadingKind = Self.leadingKindWords[leading], words.count > 1 {
            kind = leadingKind
            words.removeFirst()
        } else if let trailing = words.last, let trailingKind = Self.trailingKindWords[trailing], words.count > 1 {
            kind = trailingKind
            words.removeLast()
            if trailingKind == .set, words.last == "dj", words.count > 1 { words.removeLast() }
        }

        var artist: String?
        if kind != .artist, let split = words.lastIndex(of: "by"), split > 0, split < words.count - 1 {
            artist = words[(split + 1)...].joined(separator: " ")
            words = Array(words[..<split])
        }

        return MediaRequest(
            kind: kind,
            query: words.joined(separator: " "),
            artist: artist,
            mine: mine,
            shuffle: shuffle
        )
    }

    private static let leadingVerbs: [[String]] = [
        ["please"], ["play"], ["shuffle"], ["put", "on"], ["listen", "to"], ["queue", "up"], ["start"],
    ]

    private static let leadingKindWords: [String: Kind] = [
        "playlist": .playlist,
        "album": .playlist,
        "artist": .artist,
    ]

    private static let trailingKindWords: [String: Kind] = [
        "playlist": .playlist,
        "album": .playlist,
        "set": .set,
        "song": .track,
        "track": .track,
    ]

    private static let likesPhrases: Set<String> = [
        "likes", "my likes", "liked", "my liked", "my favourites", "my favorites", "favourites", "favorites",
        "my library", "library", "my music", "my collection", "my stuff",
    ]

    private static let likesPattern = #"^(my |all my )?(liked|loved|favou?rite) (songs|tracks|music|stuff)$|^(songs|tracks|music|stuff|something|things) i (like|liked|love|loved)$|^(my |all my )?likes playlist$"#

    private static let lastLikedSetPattern = #"^(the |my )?(last|latest|newest|most recent|recent|last liked|latest liked|newest liked|most recently liked|recently liked) (dj )?(set|mix)( i liked)?$|^(the |my )?(dj )?(set|mix) i (just )?liked( last| most recently| recently)?$|^(the |my )?last (dj )?(set|mix) i liked$"#

    private static let nowPlayingStationPhrases: Set<String> = [
        "something like this", "more like this", "music like this", "songs like this", "tracks like this",
        "stuff like this", "something similar", "something similar to this", "more of this", "similar music",
        "similar songs", "similar tracks", "a station", "radio", "a radio station", "this station",
        "a station based on this", "a station from this", "more music like this", "more songs like this",
    ]

    private static func stationSeed(in words: [String]) -> String? {
        let prefixes: [[String]] = [
            ["something", "like"], ["more", "like"], ["music", "like"], ["songs", "like"], ["tracks", "like"],
            ["something", "similar", "to"], ["a", "station", "based", "on"], ["a", "station", "from"],
            ["radio", "based", "on"], ["a", "station", "like"],
        ]
        for prefix in prefixes where words.count > prefix.count && Array(words.prefix(prefix.count)) == prefix {
            let seed = words.dropFirst(prefix.count).joined(separator: " ")
            return seed == "this" ? nil : seed
        }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum MediaText {
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var output = ""
        output.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                output.append(" ")
                lastWasSpace = true
            }
        }
        if output.hasSuffix(" ") { output.removeLast() }
        return output
    }

    static func score(_ candidate: String, query: String) -> Int {
        let q = normalized(query)
        let c = normalized(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if c == q { return 100 }
        if c.hasPrefix(q + " ") { return 85 }
        if (" " + c + " ").contains(" " + q + " ") { return 70 }
        if c.hasPrefix(q) { return 60 }
        if c.contains(q) { return 50 }
        let queryTokens = Set(q.split(separator: " ").filter { $0.count > 1 }.map(String.init))
        guard !queryTokens.isEmpty else { return 0 }
        let candidateTokens = Set(c.split(separator: " ").map(String.init))
        let shared = queryTokens.intersection(candidateTokens).count
        if shared == queryTokens.count { return 40 }
        if Double(shared) / Double(queryTokens.count) >= 0.6 { return 20 }
        return 0
    }
}

enum MediaTarget: Hashable, Sendable {
    case likes
    case track(String)
    case playlist(String)
    case artist(String)
    case station(seedTrackID: String)

    static let likesID = "likes"

    var identifier: String {
        switch self {
        case .likes: return Self.likesID
        case .track(let id): return "track:\(id)"
        case .playlist(let id): return id == Self.likesID ? Self.likesID : "playlist:\(id)"
        case .artist(let id): return "artist:\(id)"
        case .station(let id): return "station:\(id)"
        }
    }

    init?(identifier: String) {
        if identifier == Self.likesID {
            self = .likes
            return
        }
        guard let colon = identifier.firstIndex(of: ":") else { return nil }
        let id = String(identifier[identifier.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        switch identifier[..<colon] {
        case "track": self = .track(id)
        case "playlist": self = .playlist(id)
        case "artist": self = .artist(id)
        case "station": self = .station(seedTrackID: id)
        default: return nil
        }
    }
}

struct MediaResolution: Equatable, Sendable {
    enum Source: String, Sendable {
        case likes
        case history
        case playlists
        case setlists
        case following
        case nowPlaying
        case search
    }

    var target: MediaTarget
    var title: String
    var subtitle: String = ""
    var source: Source
    var shuffle = false
}

enum MediaRequestError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notFound
    case nothingPlaying
    case noLikes
    case noLikedSets

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound: return "Couldn't find that in your library or on SoundCloud."
        case .nothingPlaying: return "Nothing's playing in Sounding right now."
        case .noLikes: return "You haven't liked anything on SoundCloud yet."
        case .noLikedSets: return "You haven't liked any sets yet."
        }
    }
}

struct MediaRequestResolver: Sendable {
    static let strongMatch = 70
    static let likesScanLimit = 500
    static let remoteSearchLimit = 10

    var local: any SoundingLocalCatalog
    var remote: any SoundingRemoteCatalog
    var remoteBudget: Int
    var remoteAllowed: @Sendable () async -> Bool

    init(
        local: any SoundingLocalCatalog = DeviceLocalCatalog(),
        remote: any SoundingRemoteCatalog = SoundCloudRemoteCatalog(),
        remoteBudget: Int = 1,
        remoteAllowed: @escaping @Sendable () async -> Bool = MediaRequestResolver.liveRemoteAllowed
    ) {
        self.local = local
        self.remote = remote
        self.remoteBudget = remoteBudget
        self.remoteAllowed = remoteAllowed
    }

    static let liveRemoteAllowed: @Sendable () async -> Bool = {
        await MainActor.run { SoundCloudGateway.shared.trafficSafety == .ready }
    }

    func resolve(_ request: MediaRequest) async throws -> MediaResolution {
        var resolution = try await resolveTarget(request)
        resolution.shuffle = request.shuffle
        return resolution
    }

    private func resolveTarget(_ request: MediaRequest) async throws -> MediaResolution {
        switch request.kind {
        case .likes:
            return MediaResolution(target: .likes, title: "Likes", source: .likes)
        case .station:
            return try await resolveStation(request)
        case .set where request.query == nil:
            return try await lastLikedSet()
        default:
            break
        }
        guard request.query != nil || request.artist != nil else {
            if request.mine || request.kind == .any {
                return MediaResolution(target: .likes, title: "Likes", source: .likes)
            }
            throw MediaRequestError.notFound
        }

        var budget = remoteBudget
        let localMatches = await localCandidates(for: request)
        if let best = localMatches.first, best.score >= Self.strongMatch {
            return best.resolution
        }
        if !request.mine, budget > 0, await remoteAllowed() {
            budget -= 1
            if let found = try? await remoteCandidates(for: request), !found.isEmpty {
                let ranked = Self.rank(localMatches, found)
                if let best = ranked.first { return best.resolution }
            }
        }
        if let best = localMatches.first, best.score > 0 { return best.resolution }
        throw MediaRequestError.notFound
    }

    // MARK: Special requests

    func lastLikedSet() async throws -> MediaResolution {
        let likes = await local.recentLikedTracks(limit: Self.likesScanLimit)
        guard !likes.isEmpty else { throw MediaRequestError.noLikes }
        guard let set = likes.first(where: Self.isSet) else { throw MediaRequestError.noLikedSets }
        return MediaResolution(target: .track(set.id), title: set.title, subtitle: set.user.displayName, source: .likes)
    }

    private func resolveStation(_ request: MediaRequest) async throws -> MediaResolution {
        if request.query != nil || request.artist != nil {
            var seedRequest = request
            seedRequest.kind = .track
            let seed = try await resolveTarget(seedRequest)
            guard case .track(let id) = seed.target else { throw MediaRequestError.notFound }
            return MediaResolution(target: .station(seedTrackID: id), title: seed.title, subtitle: seed.subtitle, source: seed.source)
        }
        if let snapshot = await local.snapshot(), let nowPlaying = snapshot.nowPlaying, nowPlaying.item.kind == .track {
            return MediaResolution(
                target: .station(seedTrackID: nowPlaying.item.id),
                title: nowPlaying.item.title,
                subtitle: nowPlaying.item.subtitle,
                source: .nowPlaying
            )
        }
        throw MediaRequestError.nothingPlaying
    }

    // MARK: Candidates

    struct Candidate: Sendable {
        var resolution: MediaResolution
        var score: Int
        var order: Int
    }

    func localCandidates(for request: MediaRequest) async -> [Candidate] {
        var candidates: [Candidate] = []
        let kind = request.kind
        let wantsTracks = [.any, .track, .set].contains(kind)
        let wantsPlaylists = [.any, .playlist].contains(kind)
        let wantsArtists = [.any, .artist].contains(kind)

        func add(_ resolution: MediaResolution, score: Int) {
            guard score > 0 else { return }
            candidates.append(Candidate(resolution: resolution, score: score, order: candidates.count))
        }

        if wantsTracks {
            let likes: [Track]
            if let query = request.query {
                likes = await local.searchLikedTracks(query, limit: 25)
            } else {
                likes = await local.recentLikedTracks(limit: Self.likesScanLimit)
            }
            for track in likes where kind != .set || Self.isSet(track) {
                add(
                    MediaResolution(target: .track(track.id), title: track.title, subtitle: track.user.displayName, source: .likes),
                    score: Self.trackScore(title: track.title, artist: track.user.displayName, request: request)
                )
            }

            if let snapshot = await local.snapshot() {
                for item in Self.historyItems(snapshot) where item.kind == .track && (kind != .set || item.isMix || (item.duration ?? 0) >= CollectionKind.longFormThresholdSeconds) {
                    add(
                        MediaResolution(target: .track(item.id), title: item.title, subtitle: item.subtitle, source: .history),
                        score: Self.trackScore(title: item.title, artist: item.subtitle, request: request) - 1
                    )
                }
            }

            if let query = request.query, request.artist == nil {
                for setlist in await local.savedSetlists() {
                    let title = SetlistText.normalized(setlist.trackTitle)
                    add(
                        MediaResolution(target: .track(setlist.trackId), title: title, source: .setlists),
                        score: MediaText.score(title, query: query) - 2
                    )
                }
            }
        }

        if wantsPlaylists, let query = request.query, request.artist == nil {
            for playlist in await local.cachedPlaylists() {
                add(
                    MediaResolution(target: .playlist(playlist.id), title: playlist.title, subtitle: playlist.user.displayName, source: .playlists),
                    score: MediaText.score(playlist.title, query: query) + (kind == .playlist ? 1 : 0)
                )
            }
            if let snapshot = await local.snapshot() {
                for item in Self.historyItems(snapshot) where item.kind == .playlist {
                    add(
                        MediaResolution(target: .playlist(item.id), title: item.title, subtitle: item.subtitle, source: .history),
                        score: MediaText.score(item.title, query: query)
                    )
                }
            }
        }

        if wantsArtists, let name = kind == .artist ? request.query : (request.artist == nil ? request.query : nil) {
            var seen = Set<String>()
            let liked = await local.recentLikedTracks(limit: Self.likesScanLimit).map(\.user)
            let followed = await local.followedArtists()
            for (user, source) in liked.map({ ($0, MediaResolution.Source.likes) }) + followed.map({ ($0, .following) })
            where seen.insert(user.id).inserted {
                let score = max(MediaText.score(user.displayName, query: name), MediaText.score(user.username, query: name))
                let exactOnly = kind == .artist ? score : (score == 100 ? 100 : 0)
                add(
                    MediaResolution(target: .artist(user.id), title: user.displayName, subtitle: user.username, source: source),
                    score: exactOnly
                )
            }
        }

        return Self.rank(candidates, [])
    }

    func remoteCandidates(for request: MediaRequest) async throws -> [Candidate] {
        let query = [request.query, request.artist].compactMap { $0 }.joined(separator: " ")
        var found: [Candidate] = []
        switch request.kind {
        case .artist:
            let artists = try await remote.searchArtists(query, limit: Self.remoteSearchLimit)
            for (index, artist) in artists.enumerated() {
                let score = max(MediaText.score(artist.name, query: query), MediaText.score(artist.username, query: query))
                found.append(Candidate(
                    resolution: MediaResolution(target: .artist(artist.id), title: artist.name, subtitle: artist.username, source: .search),
                    score: max(score, index == 0 ? 1 : 0),
                    order: 1_000 + index
                ))
            }
        case .playlist:
            let playlists = try await remote.searchPlaylists(query, limit: Self.remoteSearchLimit)
            for (index, playlist) in playlists.enumerated() {
                found.append(Candidate(
                    resolution: MediaResolution(target: .playlist(playlist.id), title: playlist.title, subtitle: playlist.ownerName, source: .search),
                    score: max(MediaText.score(playlist.title, query: request.query ?? query), index == 0 ? 1 : 0),
                    order: 1_000 + index
                ))
            }
        default:
            let tracks = try await remote.searchTracks(query, limit: Self.remoteSearchLimit)
            for (index, track) in tracks.enumerated() {
                if request.kind == .set, let duration = track.durationSeconds, duration < CollectionKind.longFormThresholdSeconds { continue }
                let score = Self.trackScore(title: track.title, artist: track.artistName, request: request)
                found.append(Candidate(
                    resolution: MediaResolution(target: .track(track.id), title: track.title, subtitle: track.artistName, source: .search),
                    score: max(score - 5, index == 0 ? 1 : 0),
                    order: 1_000 + index
                ))
            }
        }
        return found
    }

    // MARK: Helpers

    static func rank(_ first: [Candidate], _ second: [Candidate]) -> [Candidate] {
        var seen = Set<MediaTarget>()
        return (first + second)
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .filter { seen.insert($0.resolution.target).inserted }
    }

    static func trackScore(title: String, artist: String, request: MediaRequest) -> Int {
        let titleScore = request.query.map { MediaText.score(title, query: $0) }
        let artistScore = request.artist.map { MediaText.score(artist, query: $0) }
        switch (titleScore, artistScore) {
        case let (title?, artist?):
            return artist >= 40 ? title : 0
        case let (title?, nil):
            guard let query = request.query, !artist.isEmpty else { return title }
            let combined = max(
                MediaText.score("\(artist) \(title)", query: query),
                MediaText.score("\(title) \(artist)", query: query)
            )
            return max(title, combined - 5)
        case let (nil, artist?):
            return artist >= strongMatch ? artist - 10 : 0
        case (nil, nil):
            return 0
        }
    }

    static func isSet(_ track: Track) -> Bool {
        CollectionKind.classify(trackDurationSeconds: track.duration) == .set
    }

    static func historyItems(_ snapshot: SoundingSnapshot) -> [SoundingSnapshot.Item] {
        var items: [SoundingSnapshot.Item] = []
        if let nowPlaying = snapshot.nowPlaying { items.append(nowPlaying.item) }
        if let lastMix = snapshot.lastMix { items.append(lastMix.item) }
        items.append(contentsOf: snapshot.recents)
        var seen = Set<String>()
        return items.filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }
    }
}

#if os(iOS) || os(tvOS)
import Intents

extension MediaRequest {
    init?(search: INMediaSearch?, shuffle: Bool) {
        guard let search else { return nil }
        let kind = Self.kind(for: search.mediaType)
        let artistName = search.artistName.flatMap { MediaText.normalized($0).isEmpty ? nil : $0 }
        let name = search.mediaName ?? search.albumName
        let mine = search.reference == .my
        let order: Order = search.sortOrder == .newest ? .newest : .relevance

        if let name, !MediaText.normalized(name).isEmpty {
            let parsed = MediaRequest.parse(name, kind: kind)
            switch parsed.kind {
            case .likes, .station:
                self = parsed
                self.shuffle = shuffle || parsed.shuffle
                return
            case .set where parsed.query == nil:
                self = parsed
                self.shuffle = shuffle || parsed.shuffle
                return
            default:
                self.init(
                    kind: kind == .any ? parsed.kind : kind,
                    query: kind == .artist ? (artistName ?? parsed.query) : parsed.query,
                    artist: kind == .artist ? nil : (parsed.artist ?? artistName),
                    mine: mine || parsed.mine,
                    order: order,
                    shuffle: shuffle || parsed.shuffle
                )
                return
            }
        }

        if search.reference == .currentlyPlaying || kind == .station {
            self.init(kind: .station, shuffle: shuffle)
            return
        }
        if let artistName {
            self.init(kind: .artist, query: artistName, shuffle: shuffle)
            return
        }
        if let genre = search.genreNames?.first ?? search.moodNames?.first {
            self.init(kind: .track, query: genre, shuffle: shuffle)
            return
        }
        if mine || search.mediaType == .music || kind == .track {
            self.init(kind: .likes, mine: true, shuffle: shuffle)
            return
        }
        return nil
    }

    private static func kind(for type: INMediaItemType) -> Kind {
        switch type {
        case .song: return .track
        case .artist: return .artist
        case .album, .playlist: return .playlist
        case .station, .musicStation, .radioStation, .algorithmicRadioStation: return .station
        default: return .any
        }
    }
}

extension MediaResolution {
    var mediaItemType: INMediaItemType {
        switch target {
        case .likes, .playlist: return .playlist
        case .track: return .song
        case .artist: return .artist
        case .station: return .station
        }
    }
}
#endif
