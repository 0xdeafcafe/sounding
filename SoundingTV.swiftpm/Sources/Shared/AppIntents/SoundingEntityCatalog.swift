import Foundation

protocol SoundingEntityCatalog: Sendable {
    func tracks(ids: [String]) async throws -> [TrackEntity]
    func searchTracks(matching query: String) async throws -> [TrackEntity]
    func suggestedTracks() async throws -> [TrackEntity]

    func artists(ids: [String]) async throws -> [ArtistEntity]
    func searchArtists(matching query: String) async throws -> [ArtistEntity]
    func suggestedArtists() async throws -> [ArtistEntity]

    func playlists(ids: [String]) async throws -> [PlaylistEntity]
    func searchPlaylists(matching query: String) async throws -> [PlaylistEntity]
    func suggestedPlaylists() async throws -> [PlaylistEntity]

    func setlists(ids: [String]) async throws -> [SetlistEntity]
    func searchSetlists(matching query: String) async throws -> [SetlistEntity]
    func suggestedSetlists() async throws -> [SetlistEntity]
}

protocol SoundingRemoteCatalog: Sendable {
    func tracks(ids: [String]) async throws -> [TrackEntity]
    func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity]
    func artists(ids: [String]) async throws -> [ArtistEntity]
    func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity]
    func playlists(ids: [String]) async throws -> [PlaylistEntity]
    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity]
    func myPlaylists(limit: Int) async throws -> [PlaylistEntity]
}

protocol SoundingLocalCatalog: Sendable {
    func snapshot() async -> SoundingSnapshot?
    func likedTracks(ids: [String]) async -> [Track]
    func searchLikedTracks(_ query: String, limit: Int) async -> [Track]
    func recentLikedTracks(limit: Int) async -> [Track]
    func savedSetlists() async -> [GeneratedSetlist]
    func likesCount() async -> Int
    func cachedPlaylists() async -> [Playlist]
    func followedArtists() async -> [User]
}

extension SoundingLocalCatalog {
    func likesCount() async -> Int { 0 }
    func cachedPlaylists() async -> [Playlist] { [] }
    func followedArtists() async -> [User] { [] }
}

struct LiveSoundingEntityCatalog: SoundingEntityCatalog {
    static let searchLimit = 20
    static let localSearchLimit = 8
    static let suggestionLimit = 20
    static let remoteTrackHydrationLimit = 50
    static let remoteHydrationLimit = 5

    var remote: any SoundingRemoteCatalog
    var local: any SoundingLocalCatalog

    init(
        remote: any SoundingRemoteCatalog = SoundCloudRemoteCatalog(),
        local: any SoundingLocalCatalog = DeviceLocalCatalog()
    ) {
        self.remote = remote
        self.local = local
    }

    // MARK: Tracks

    var resolver: MediaRequestResolver {
        MediaRequestResolver(local: local, remote: remote, remoteBudget: 0, remoteAllowed: { false })
    }

    func tracks(ids: [String]) async throws -> [TrackEntity] {
        guard !ids.isEmpty else { return [] }
        var found: [String: TrackEntity] = [:]
        if let snapshot = await local.snapshot() {
            for item in Self.snapshotItems(snapshot) where ids.contains(item.id) {
                if let entity = TrackEntity(item) { found[item.id] = entity }
            }
        }
        for track in await local.likedTracks(ids: ids.filter { found[$0] == nil }) {
            found[track.id] = TrackEntity(track)
        }

        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            do {
                for entity in try await remote.tracks(ids: Array(missing.prefix(Self.remoteTrackHydrationLimit))) {
                    found[entity.id] = entity
                }
            } catch {
                if found.isEmpty { throw error }
            }
        }
        return Self.ordered(ids, from: found)
    }

    func searchTracks(matching query: String) async throws -> [TrackEntity] {
        let request = MediaRequest.parse(query)
        if request.kind == .set, request.order == .newest {
            guard let resolution = try? await resolver.lastLikedSet(),
                  case .track(let id) = resolution.target else { return [] }
            return try await tracks(ids: [id])
        }
        if request.kind == .station {
            guard let resolution = try? await resolver.resolve(request),
                  case .station(let id) = resolution.target else { return [] }
            return try await tracks(ids: [id])
        }
        let liked = await local.searchLikedTracks(query, limit: Self.localSearchLimit).map(TrackEntity.init)
        if liked.contains(where: { MediaText.score($0.title, query: query) == 100 }) {
            return liked
        }
        do {
            let remote = try await remote.searchTracks(query, limit: Self.searchLimit)
            return Self.merged(liked, remote)
        } catch {
            if liked.isEmpty { throw error }
            return liked
        }
    }

    func suggestedTracks() async throws -> [TrackEntity] {
        var result: [TrackEntity] = []
        if let snapshot = await local.snapshot() {
            result = Self.snapshotItems(snapshot).compactMap(TrackEntity.init)
        }
        let liked = await local.recentLikedTracks(limit: Self.suggestionLimit).map(TrackEntity.init)
        return Array(Self.merged(result, liked).prefix(Self.suggestionLimit))
    }

    // MARK: Artists

    func artists(ids: [String]) async throws -> [ArtistEntity] {
        guard !ids.isEmpty else { return [] }
        var found: [String: ArtistEntity] = [:]
        for user in await local.recentLikedTracks(limit: 200).map(\.user) where ids.contains(user.id) {
            found[user.id] = ArtistEntity(user)
        }
        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            do {
                for entity in try await remote.artists(ids: Array(missing.prefix(Self.remoteHydrationLimit))) {
                    found[entity.id] = entity
                }
            } catch {
                if found.isEmpty { throw error }
            }
        }
        return Self.ordered(ids, from: found)
    }

    func searchArtists(matching query: String) async throws -> [ArtistEntity] {
        let folded = Self.fold(query)
        let liked = Self.uniqueArtists(from: await local.recentLikedTracks(limit: 200))
            .filter { Self.fold($0.name).contains(folded) || Self.fold($0.username).contains(folded) }
            .prefix(Self.localSearchLimit)
        if liked.contains(where: { MediaText.score($0.name, query: query) == 100 || MediaText.score($0.username, query: query) == 100 }) {
            return Array(liked)
        }
        do {
            let remote = try await remote.searchArtists(query, limit: Self.searchLimit)
            return Self.merged(Array(liked), remote)
        } catch {
            if liked.isEmpty { throw error }
            return Array(liked)
        }
    }

    func suggestedArtists() async throws -> [ArtistEntity] {
        Array(Self.uniqueArtists(from: await local.recentLikedTracks(limit: 100)).prefix(Self.suggestionLimit))
    }

    // MARK: Playlists

    func playlists(ids: [String]) async throws -> [PlaylistEntity] {
        guard !ids.isEmpty else { return [] }
        var found: [String: PlaylistEntity] = [:]
        if ids.contains(MediaTarget.likesID) {
            found[MediaTarget.likesID] = PlaylistEntity.likes(trackCount: await local.likesCount())
        }
        for playlist in await local.cachedPlaylists() where ids.contains(playlist.id) {
            found[playlist.id] = PlaylistEntity(playlist)
        }
        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            do {
                for entity in try await remote.playlists(ids: Array(missing.prefix(Self.remoteHydrationLimit))) {
                    found[entity.id] = entity
                }
            } catch {
                if found.isEmpty { throw error }
            }
        }
        return Self.ordered(ids, from: found)
    }

    func searchPlaylists(matching query: String) async throws -> [PlaylistEntity] {
        if MediaRequest.parse(query).kind == .likes {
            return [PlaylistEntity.likes(trackCount: await local.likesCount())]
        }
        let folded = Self.fold(query)
        var mine = await local.cachedPlaylists().map(PlaylistEntity.init)
        if mine.isEmpty {
            mine = (try? await remote.myPlaylists(limit: 50)) ?? []
        }
        mine = mine.filter { Self.fold($0.title).contains(folded) }
        if mine.contains(where: { MediaText.score($0.title, query: query) == 100 }) {
            return mine
        }
        do {
            let remote = try await remote.searchPlaylists(query, limit: Self.searchLimit)
            return Self.merged(mine, remote)
        } catch {
            if mine.isEmpty { throw error }
            return mine
        }
    }

    func suggestedPlaylists() async throws -> [PlaylistEntity] {
        let likes = PlaylistEntity.likes(trackCount: await local.likesCount())
        var playlists = await local.cachedPlaylists().map(PlaylistEntity.init)
        if playlists.isEmpty {
            playlists = (try? await remote.myPlaylists(limit: Self.suggestionLimit)) ?? []
        }
        return Array(Self.merged([likes], playlists).prefix(Self.suggestionLimit))
    }

    // MARK: Setlists

    func setlists(ids: [String]) async throws -> [SetlistEntity] {
        let saved = await local.savedSetlists()
        let found = Dictionary(
            saved.filter { ids.contains($0.trackId) }.map { ($0.trackId, SetlistEntity($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.ordered(ids, from: found)
    }

    func searchSetlists(matching query: String) async throws -> [SetlistEntity] {
        let folded = Self.fold(query)
        let entities = await local.savedSetlists().map(SetlistEntity.init)
        let titled = entities.filter { Self.fold($0.title).contains(folded) }
        let byEntry = entities.filter { entity in
            entity.entryLabels.contains { Self.fold($0).contains(folded) }
        }
        return Self.merged(titled, byEntry)
    }

    func suggestedSetlists() async throws -> [SetlistEntity] {
        Array(await local.savedSetlists().map(SetlistEntity.init).prefix(Self.suggestionLimit))
    }

    // MARK: Helpers

    static func snapshotItems(_ snapshot: SoundingSnapshot) -> [SoundingSnapshot.Item] {
        var items: [SoundingSnapshot.Item] = []
        if let nowPlaying = snapshot.nowPlaying { items.append(nowPlaying.item) }
        if let lastMix = snapshot.lastMix { items.append(lastMix.item) }
        items.append(contentsOf: snapshot.recents)
        var seen = Set<String>()
        return items.filter { $0.kind == .track && seen.insert($0.id).inserted }
    }

    static func uniqueArtists(from tracks: [Track]) -> [ArtistEntity] {
        var seen = Set<String>()
        return tracks.compactMap { track in
            seen.insert(track.user.id).inserted ? ArtistEntity(track.user) : nil
        }
    }

    static func ordered<Entity>(_ ids: [String], from found: [String: Entity]) -> [Entity] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return found[id]
        }
    }

    static func merged<Entity: Identifiable>(_ first: [Entity], _ second: [Entity]) -> [Entity] where Entity.ID == String {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

// MARK: - Live sources

struct SoundCloudRemoteCatalog: SoundingRemoteCatalog {
    @MainActor
    func tracks(ids: [String]) async throws -> [TrackEntity] {
        try await SoundCloudRequestEnvironment.systemInitiated {
            try await SoundCloudAPI.shared.getTracks(ids: ids).map(TrackEntity.init)
        }
    }

    @MainActor
    func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity] {
        try await SoundCloudAPI.shared.searchTracks(query: query, limit: limit).collection.map(TrackEntity.init)
    }

    @MainActor
    func artists(ids: [String]) async throws -> [ArtistEntity] {
        var result: [ArtistEntity] = []
        var lastError: Error?
        for id in ids {
            do {
                let user = try await SoundCloudRequestEnvironment.systemInitiated {
                    try await SoundCloudAPI.shared.getUser(id: id)
                }
                result.append(ArtistEntity(user))
            } catch {
                lastError = error
                if Self.isTrafficLimit(error) { break }
            }
        }
        if result.isEmpty, let lastError { throw lastError }
        return result
    }

    @MainActor
    func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity] {
        try await SoundCloudAPI.shared.searchUsers(query: query, limit: limit).collection.map(ArtistEntity.init)
    }

    @MainActor
    func playlists(ids: [String]) async throws -> [PlaylistEntity] {
        var result: [PlaylistEntity] = []
        var lastError: Error?
        for id in ids {
            do {
                let playlist = try await SoundCloudRequestEnvironment.systemInitiated {
                    try await SoundCloudAPI.shared.getPlaylist(id: id)
                }
                result.append(PlaylistEntity(playlist))
            } catch {
                lastError = error
                if Self.isTrafficLimit(error) { break }
            }
        }
        if result.isEmpty, let lastError { throw lastError }
        return result
    }

    @MainActor
    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity] {
        try await SoundCloudAPI.shared.searchPlaylists(query: query, limit: limit).collection.map(PlaylistEntity.init)
    }

    static func isTrafficLimit(_ error: Error) -> Bool {
        switch error {
        case APIError.rateLimited, APIError.temporarilyBlocked: return true
        default: return error is SoundCloudGatewayError
        }
    }

    @MainActor
    func myPlaylists(limit: Int) async throws -> [PlaylistEntity] {
        guard let user = await SoundCloudAPI.credentials?.waitForCurrentUser() else { return [] }
        return try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: limit).collection.map(PlaylistEntity.init)
    }
}

struct DeviceLocalCatalog: SoundingLocalCatalog {
    var library: LibraryCache = .shared

    @MainActor
    func snapshot() async -> SoundingSnapshot? {
        let published = SoundingSnapshotPublisher.shared.current
        if !published.isEmpty { return published }
        return SoundingSnapshotStore.load()
    }

    @MainActor
    func likedTracks(ids: [String]) async -> [Track] {
        guard !ids.isEmpty, LikesSyncEngine.isEnabled else { return [] }
        return Self.decode(await library.loadLikes(ids: ids))
    }

    @MainActor
    func searchLikedTracks(_ query: String, limit: Int) async -> [Track] {
        guard LikesSyncEngine.isEnabled else { return [] }
        return Self.decode(await library.searchLikes(query: query, limit: limit))
    }

    @MainActor
    func recentLikedTracks(limit: Int) async -> [Track] {
        guard LikesSyncEngine.isEnabled else { return [] }
        return Self.decode(await library.loadAllLikes(limit: limit))
    }

    @MainActor
    func savedSetlists() async -> [GeneratedSetlist] {
        let store = SetlistIntelligenceStore.shared
        await store.waitUntilLoaded()
        return store.savedSetlists
    }

    @MainActor
    func likesCount() async -> Int {
        guard LikesSyncEngine.isEnabled else { return 0 }
        return await library.likesCount()
    }

    func cachedPlaylists() async -> [Playlist] {
        let library = library
        return await Task.detached(priority: .userInitiated) {
            Self.decodeSections(Self.playlistSections, from: library, as: Playlist.self)
        }.value
    }

    func followedArtists() async -> [User] {
        let library = library
        return await Task.detached(priority: .userInitiated) {
            Self.decodeSections(Self.followingSections, from: library, as: User.self)
        }.value
    }

    private static let playlistSections = ["playlists", "Playlists", "OwnedPlaylists", "LikedPlaylists"]
    private static let followingSections = ["following", "Following", "Artists"]

    private nonisolated static func decodeSections<Item: Decodable & Identifiable>(
        _ sections: [String],
        from library: LibraryCache,
        as type: Item.Type
    ) -> [Item] where Item.ID == String {
        let decoder = LikesSyncEngine.makeDecoder()
        var seen = Set<String>()
        var items: [Item] = []
        for section in sections {
            for row in library.loadSection(section, limit: 500) {
                guard let item = try? decoder.decode(Item.self, from: row.payload),
                      seen.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        return items
    }

    private static func decode(_ rows: [LibraryCache.Row]) -> [Track] {
        let decoder = LikesSyncEngine.makeDecoder()
        return rows.compactMap { try? decoder.decode(Track.self, from: $0.payload) }
    }
}
