import Combine
import Foundation

struct StationSeed: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case personal
        case track
        case artist
        case soundCloud
    }

    var kind: Kind
    var id: String
    var title: String
    var basedOn: String?
    var artworkURL: URL?
    var track: Track?
    var artist: User?
    var system: SystemPlaylist?
    var seedStationURNs: [String] = []

    static let personalID = "sounding:stations:your-station"

    static func trackStationURN(_ track: Track) -> String {
        if let urn = track.stationURN, !urn.isEmpty { return urn }
        return "soundcloud:system-playlists:track-stations:\(track.id)"
    }

    static func artistStationURN(_ user: User) -> String {
        "soundcloud:system-playlists:artist-stations:\(user.id)"
    }

    static func track(_ track: Track) -> StationSeed {
        StationSeed(
            kind: .track,
            id: trackStationURN(track),
            title: "\(track.title) Station",
            basedOn: track.user.displayName,
            artworkURL: track.largeArtworkURL ?? track.artworkURL ?? track.user.largeAvatarURL,
            track: track,
            artist: track.user
        )
    }

    static func artist(_ user: User) -> StationSeed {
        StationSeed(
            kind: .artist,
            id: artistStationURN(user),
            title: "\(user.displayName) Station",
            basedOn: user.displayName,
            artworkURL: user.largeAvatarURL ?? user.avatarURL,
            artist: user
        )
    }

    static func soundCloud(_ station: SystemPlaylist) -> StationSeed {
        let short = station.shortTitle.flatMap { $0.isEmpty ? nil : $0 }
        let detail = [station.shortDescription, station.description]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return StationSeed(
            kind: .soundCloud,
            id: station.id,
            title: short ?? station.title,
            basedOn: detail,
            artworkURL: station.artworkURL,
            system: station
        )
    }

    static func personal(seeds: [Track]) -> StationSeed? {
        guard let lead = seeds.first else { return nil }
        return StationSeed(
            kind: .personal,
            id: personalID,
            title: "Your Station",
            basedOn: "your likes and plays",
            artworkURL: lead.largeArtworkURL ?? lead.artworkURL,
            track: lead,
            seedStationURNs: seeds.map(trackStationURN)
        )
    }

    var subtitle: String? {
        switch kind {
        case .personal:
            return "Based on your likes and plays"
        case .soundCloud:
            return basedOn
        case .track, .artist:
            return basedOn.map { "Based on \($0)" }
        }
    }

    var nowPlayingCaption: String {
        guard let subtitle, !subtitle.isEmpty else { return "Station" }
        return "Station \u{00B7} \(subtitle)"
    }

    var queueSource: PlaybackQueueSource {
        PlaybackQueueSource(id: id, kind: .station, title: title)
    }

    var artIdentity: String { id }

    var goToArtist: User? { artist ?? track?.user }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: StationSeed, rhs: StationSeed) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.artworkURL == rhs.artworkURL && lhs.basedOn == rhs.basedOn
    }
}

@MainActor
final class StationLibrary: ObservableObject {
    static let shared = StationLibrary()

    @Published private(set) var recents: [StationSeed] = []

    private static let limit = 20
    private static let keyPrefix = "stations.recent.v1."

    private let defaults: UserDefaults
    private var accountKey: String
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accountKey = Self.key(for: SoundCloudAPI.credentials?.currentUser?.id)
        recents = Self.read(defaults, key: accountKey)
        SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.switchAccount(to: id) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forget() }
            .store(in: &cancellables)
    }

    func record(_ seed: StationSeed) {
        var list = recents.filter { $0.id != seed.id }
        list.insert(seed, at: 0)
        recents = Array(list.prefix(Self.limit))
        save()
    }

    func remove(_ seed: StationSeed) {
        recents.removeAll { $0.id == seed.id }
        save()
    }

    func record(_ station: SystemPlaylist) {
        record(.soundCloud(station))
    }

    func caption(for source: PlaybackQueueSource?) -> String? {
        guard let source, source.kind == .station else { return nil }
        if let id = source.id, let seed = recents.first(where: { $0.id == id }) {
            return seed.nowPlayingCaption
        }
        if let seed = recents.first(where: { $0.title == source.title }) {
            return seed.nowPlayingCaption
        }
        let suffix = " Station"
        if source.title.hasSuffix(suffix), source.title.count > suffix.count {
            return "Station \u{00B7} Based on \(source.title.dropLast(suffix.count))"
        }
        return source.title.isEmpty ? "Station" : "Station \u{00B7} \(source.title)"
    }

    private func switchAccount(to id: String?) {
        accountKey = Self.key(for: id)
        recents = Self.read(defaults, key: accountKey)
    }

    private func forget() {
        defaults.removeObject(forKey: accountKey)
        recents = []
    }

    private func save() {
        let encoder = LikesSyncEngine.makeEncoder()
        guard let data = try? encoder.encode(recents) else { return }
        defaults.set(data, forKey: accountKey)
    }

    private static func key(for accountID: String?) -> String {
        keyPrefix + (accountID ?? "guest")
    }

    private static func read(_ defaults: UserDefaults, key: String) -> [StationSeed] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? LikesSyncEngine.makeDecoder().decode([StationSeed].self, from: data)) ?? []
    }
}

enum StationQueue {
    static let queueLimit = 50
    private static let personalPerSeed = 20

    @MainActor
    static func load(_ station: SystemPlaylist, limit: Int = queueLimit) async throws -> [Track] {
        PlaybackQueueSourceDirectory.note(station)
        #if DEBUG
        if VisualFixtures.isEnabled { return Array(VisualFixtures.tracks.prefix(12)) }
        #endif
        return try await load(StationSeed.soundCloud(station), limit: limit)
    }

    @MainActor
    static func load(_ seed: StationSeed, limit: Int = queueLimit) async throws -> [Track] {
        switch seed.kind {
        case .soundCloud:
            if let station = seed.system, !station.trackIDs.isEmpty {
                return try await SoundCloudAPI.shared.getSystemPlaylistTracks(station, limit: limit)
            }
            return try await stationTracks(urn: seed.id, limit: limit) ?? []
        case .track, .artist:
            if let tracks = try await stationTracks(urn: seed.id, limit: limit), !tracks.isEmpty {
                return tracks
            }
            return try await fallback(seed, limit: limit)
        case .personal:
            return try await personal(seed, limit: limit)
        }
    }

    @MainActor
    private static func stationTracks(urn: String, limit: Int) async throws -> [Track]? {
        let api = SoundCloudAPI.shared
        do {
            let station = try await api.getSystemPlaylist(urn: urn)
            let tracks = try await api.getSystemPlaylistTracks(station, limit: limit)
            if !tracks.isEmpty { return tracks }
        } catch {
            guard allowsFallback(after: error) else { throw error }
        }
        do {
            let official = try await api.getOfficialStation(urn: urn)
            return try await api.getTracks(ids: official.trackIDs, limit: limit)
        } catch {
            guard allowsFallback(after: error) else { throw error }
            return nil
        }
    }

    static func stopsTraffic(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        switch error {
        case .rateLimited, .temporarilyBlocked, .unauthorized: return true
        default: return false
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? APIError {
            switch error {
            case .rateLimited, .temporarilyBlocked:
                return error.errorDescription ?? "SoundCloud is limiting requests. Try again later."
            case .unauthorized:
                return "Sign in to SoundCloud to play stations."
            default:
                break
            }
        }
        return "Couldn\u{2019}t start this station. Check your connection and try again."
    }

    private static func allowsFallback(after error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        switch error {
        case .notFound, .forbidden, .decodingError, .invalidURL: return true
        case .serverError(let code): return (400..<500).contains(code)
        default: return false
        }
    }

    @MainActor
    private static func fallback(_ seed: StationSeed, limit: Int) async throws -> [Track] {
        let api = SoundCloudAPI.shared
        if seed.kind == .track, let track = seed.track {
            let related = try await api.getRelatedTracks(trackID: track.id, limit: limit).collection
            return unique([track] + related, limit: limit)
        }
        guard let artist = seed.artist else { return [] }
        let top = try await api.getUserTopTracks(userId: artist.id, limit: 10).collection
        guard let lead = top.first else { return [] }
        let related = (try? await api.getRelatedTracks(trackID: lead.id, limit: limit).collection) ?? []
        return unique(interleave([Array(top.prefix(5)), related]), limit: limit)
    }

    @MainActor
    private static func personal(_ seed: StationSeed, limit: Int) async throws -> [Track] {
        var lists: [[Track]] = []
        var stop: Error?
        for urn in seed.seedStationURNs.prefix(3) {
            do {
                lists.append(try await stationTracks(urn: urn, limit: personalPerSeed) ?? [])
            } catch {
                if stopsTraffic(error) {
                    stop = error
                    break
                }
            }
        }
        let merged = unique(interleave(lists), limit: limit)
        if merged.isEmpty, let stop { throw stop }
        return merged
    }

    static func interleave(_ lists: [[Track]]) -> [Track] {
        var out: [Track] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                out.append(list[index])
            }
        }
        return out
    }

    private static func unique(_ tracks: [Track], limit: Int) -> [Track] {
        var seen = Set<String>()
        var out: [Track] = []
        for track in tracks where seen.insert(track.id).inserted {
            out.append(track)
            if out.count == limit { break }
        }
        return out
    }
}

@MainActor
enum StationPlayer {
    @discardableResult
    static func start(_ seed: StationSeed, restart: Bool = false) async -> String? {
        #if DEBUG
        if VisualFixtures.isEnabled {
            StationLibrary.shared.record(seed)
            return nil
        }
        #endif
        let tracks: [Track]
        do {
            tracks = try await StationQueue.load(seed)
        } catch {
            return StationQueue.message(for: error)
        }
        let playable = tracks.filter { IntentPlayback.source.isPlayable($0) }
        guard let first = playable.first else {
            return "This station has nothing to play right now."
        }
        PlaybackQueueSourceDirectory.note(seed.queueSource)
        StationLibrary.shared.record(seed)
        if restart { PlayerService.shared.isShuffleEnabled = false }
        return await IntentPlayback.sink.play(first, in: playable, collectionId: seed.id)
    }

    @discardableResult
    static func start(track: Track) async -> String? {
        await start(.track(track), restart: true)
    }

    @discardableResult
    static func start(artist: User) async -> String? {
        await start(.artist(artist), restart: true)
    }
}

@MainActor
final class StationsModel: ObservableObject {
    static let shared = StationsModel()

    @Published private(set) var yourStation: StationSeed?
    @Published private(set) var recents: [StationSeed] = []
    @Published private(set) var liked: [StationSeed] = []
    @Published private(set) var forYou: [StationSeed] = []
    @Published private(set) var artists: [StationSeed] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var startingID: String?
    @Published var failure: String?

    static let likedSection = "Stations"
    static let officialLikedSection = "stations.liked"
    private static let likedRefreshInterval: TimeInterval = 6 * 60 * 60
    private static let relatedRefreshInterval: TimeInterval = 24 * 60 * 60
    private static let shelfLimit = 20
    private static let artistLimit = 24
    private static let forYouLimit = 12
    private static let likesScanned = 300

    private var rebuildTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var relatedSeedID: String?
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    var isEmpty: Bool {
        yourStation == nil && recents.isEmpty && liked.isEmpty && forYou.isEmpty && artists.isEmpty
    }

    var showsLoading: Bool { !hasLoaded && isEmpty }

    init() {
        StationLibrary.shared.$recents
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.recents = value }
            .store(in: &cancellables)
        RecentlyPlayed.shared.$items
            .map { $0.prefix(12).map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        let engine = LibrarySyncEngine.shared
        let watched: Set<LibraryCollection> = [.likes, .followings]
        engine.$revision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard !engine.lastChanged.isDisjoint(with: watched) else { return }
                self?.scheduleRebuild()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reset() }
            .store(in: &cancellables)
    }

    func load() async {
        if !hasLoaded {
            await rebuild()
            hasLoaded = true
        } else {
            scheduleRebuild()
        }
        refreshRemoteIfStale()
    }

    func reload() async {
        await rebuild()
        hasLoaded = true
    }

    func play(_ seed: StationSeed, restart: Bool = false) {
        guard startingID == nil else { return }
        startingID = seed.id
        Task {
            let message = await StationPlayer.start(seed, restart: restart)
            startingID = nil
            if let message { failure = message }
        }
    }

    func forgetRecent(_ seed: StationSeed) {
        StationLibrary.shared.remove(seed)
    }

    private func reset() {
        generation += 1
        yourStation = nil
        liked = []
        forYou = []
        artists = []
        hasLoaded = false
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        generation += 1
        let token = generation
        #if DEBUG
        if VisualFixtures.isEnabled {
            applyFixtures()
            return
        }
        #endif
        let likes = await LibraryDB.tracks(.likes, offset: 0, limit: Self.likesScanned).tracks
            .filter { !$0.isLocal }
        let following = await LibraryDB.people(.followings)
        let likedStations = await Self.cachedLikedStations()
        guard token == generation, !Task.isCancelled else { return }
        let recentTracks = RecentlyPlayed.shared.tracks.filter { !$0.isLocal }

        let followed = following
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.followedAt, rhs.element.followedAt) {
                case let (l?, r?): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element.user)
            .prefix(Self.shelfLimit)
        let followedIDs = Set(followed.map(\.id))

        var personalSeeds: [Track] = []
        for track in Array(likes.prefix(2)) + Array(recentTracks.prefix(2)) where !personalSeeds.contains(where: { $0.id == track.id }) {
            personalSeeds.append(track)
            if personalSeeds.count == 3 { break }
        }

        var trackSeeds: [StationSeed] = []
        var seenArtists = Set<String>()
        for track in recentTracks where seenArtists.insert(track.user.id).inserted {
            trackSeeds.append(.track(track))
            if trackSeeds.count == 6 { break }
        }

        var counts: [String: (user: User, count: Int, first: Int)] = [:]
        for (index, track) in likes.enumerated() {
            let user = track.user
            if let existing = counts[user.id] {
                counts[user.id] = (existing.user, existing.count + 1, existing.first)
            } else {
                counts[user.id] = (user, 1, index)
            }
        }
        let topArtists = counts.values
            .filter { $0.count >= 2 && !followedIDs.contains($0.user.id) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(6)
            .map { StationSeed.artist($0.user) }

        let mixed = Self.interleave(trackSeeds, Array(topArtists))
        var seen = Set<String>()
        let forYou = Array(mixed.filter { seen.insert($0.id).inserted }.prefix(Self.forYouLimit))

        let related = Self.storedRelated(account: SoundCloudAPI.credentials?.currentUser?.id)
        var artistSeen = Set(forYou.map(\.id))
        let artistSeeds = (Array(followed) + related)
            .map(StationSeed.artist)
            .filter { artistSeen.insert($0.id).inserted }
            .prefix(Self.artistLimit)

        relatedSeedID = counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .first?.user.id ?? followed.first?.id
        yourStation = StationSeed.personal(seeds: personalSeeds)
        self.forYou = forYou
        artists = Array(artistSeeds)
        liked = likedStations
    }

    private static func interleave(_ a: [StationSeed], _ b: [StationSeed]) -> [StationSeed] {
        var out: [StationSeed] = []
        for index in 0..<max(a.count, b.count) {
            if index < a.count { out.append(a[index]) }
            if index < b.count { out.append(b[index]) }
        }
        return out
    }

    private static func cachedLikedStations() async -> [StationSeed] {
        let official = officialLikedSection
        let section = likedSection
        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            let fromOfficial = LibraryCache.shared.loadSection(official)
                .compactMap { try? decoder.decode(StationSeed.self, from: $0.payload) }
            let fromLibrary = LibraryCache.shared.loadSection(section)
                .compactMap { try? decoder.decode(SystemPlaylist.self, from: $0.payload) }
                .map(StationSeed.soundCloud)
            var seen = Set<String>()
            return (fromOfficial + fromLibrary).filter { seen.insert($0.id).inserted }
        }.value
    }

    private static func relatedKey(_ account: String) -> String { "stations.related.\(account)" }

    private static func storedRelated(account: String?) -> [User] {
        guard let account, let data = UserDefaults.standard.data(forKey: relatedKey(account)) else { return [] }
        return (try? LikesSyncEngine.makeDecoder().decode([User].self, from: data)) ?? []
    }

    private static func isTrafficPaused() -> Bool {
        guard let paused = SoundCloudGateway.shared.backgroundWorkPausedUntil else { return false }
        return paused > Date()
    }

    private static func isDue(_ key: String, every interval: TimeInterval) -> Bool {
        guard let checked = UserDefaults.standard.object(forKey: key) as? Date else { return true }
        return Date().timeIntervalSince(checked) >= interval
    }

    private func refreshRemoteIfStale() {
        guard refreshTask == nil,
              SoundCloudCredentialSource.shared.hasConfirmedAccount,
              let account = SoundCloudAPI.credentials?.currentUser?.id,
              !Self.isTrafficPaused() else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let stopped = await self.refreshLiked(account: account)
            if !stopped, !Self.isTrafficPaused() {
                await self.refreshRelated(account: account)
            }
            self.refreshTask = nil
        }
    }

    private func refreshLiked(account: String) async -> Bool {
        let checkedKey = "stations.liked.checkedAt.\(account)"
        guard Self.isDue(checkedKey, every: Self.likedRefreshInterval) else { return false }
        UserDefaults.standard.set(Date(), forKey: checkedKey)
        do {
            let stations = try await SoundCloudAPI.shared.getLikedStations(limit: 50)
            let encoder = LikesSyncEngine.makeEncoder()
            let rows = stations.compactMap { official -> LibraryCache.WriteRow? in
                var seed = StationSeed.soundCloud(official.station)
                if seed.artworkURL == nil { seed.artworkURL = official.leadArtworkURL }
                guard let payload = try? encoder.encode(seed) else { return nil }
                return LibraryCache.WriteRow(id: seed.id, payload: payload)
            }
            await LibraryCache.shared.replaceSection(Self.officialLikedSection, rows: rows)
            guard SoundCloudAPI.credentials?.currentUser?.id == account else { return false }
            liked = await Self.cachedLikedStations()
            return false
        } catch {
            Log.ui.info("Stations: liked stations unavailable (\(DiscoverySourceFailure.withoutQueryValues(String(describing: error)), privacy: .public))")
            return StationQueue.stopsTraffic(error)
        }
    }

    private func refreshRelated(account: String) async {
        let checkedKey = "stations.related.checkedAt.\(account)"
        guard let seedID = relatedSeedID, Self.isDue(checkedKey, every: Self.relatedRefreshInterval) else { return }
        UserDefaults.standard.set(Date(), forKey: checkedKey)
        do {
            let users = try await SoundCloudAPI.shared.getRelatedArtists(userID: seedID, limit: 12)
            guard SoundCloudAPI.credentials?.currentUser?.id == account else { return }
            if let data = try? LikesSyncEngine.makeEncoder().encode(users) {
                UserDefaults.standard.set(data, forKey: Self.relatedKey(account))
            }
            scheduleRebuild()
        } catch {
            Log.ui.info("Stations: related artists unavailable (\(DiscoverySourceFailure.withoutQueryValues(String(describing: error)), privacy: .public))")
        }
    }

    #if DEBUG
    private func applyFixtures() {
        let tracks = VisualFixtures.tracks.filter { !$0.isLocal }
        yourStation = StationSeed.personal(seeds: Array(tracks.prefix(3)))
        forYou = Self.interleave(
            tracks.dropFirst(3).prefix(6).map(StationSeed.track),
            VisualFixtures.artists.prefix(4).map(StationSeed.artist)
        )
        artists = VisualFixtures.artists.map(StationSeed.artist)
        liked = []
    }
    #endif
}
