import Foundation

extension Notification.Name {
    static let likesIndexDidChange = Notification.Name("likesIndexDidChange")
}

@MainActor
final class LikesSyncEngine: ObservableObject {
    static let shared = LikesSyncEngine()

    @Published private(set) var indexedCount = 0
    @Published private(set) var isSyncing = false

    private let cache = LibraryCache.shared
    private let api = SoundCloudAPI.shared

    private var activated = false
    private var runner: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private static let pageLimit = 100
    private static let interPageDelay: Duration = .milliseconds(500)
    private static let activationDelay: Duration = .seconds(4)
    private static let tickInterval: Duration = .seconds(15 * 60)
    private static let topUpInterval: TimeInterval = 15 * 60
    private static let fullWalkInterval: TimeInterval = 24 * 60 * 60
    private static let retryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(32)]

    private enum StateKey {
        static let nextHref = "likes.nextHref"
        static let generation = "likes.generation"
        static let completedAt = "likes.completedAt"
        static let toppedUpAt = "likes.toppedUpAt"
    }

    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LIKES_INDEX"] == "0" { return false }
        #endif
        return true
    }

    func activate() {
        LibraryMetadataSyncEngine.shared.activate()
        guard Self.isEnabled, !activated else { return }
        activated = true

        observers.append(NotificationCenter.default.addObserver(
            forName: .trackLikeChanged, object: nil, queue: .main
        ) { [weak self] note in
            let track = note.userInfo?[SoundCloudAPI.likeNotificationTrackKey] as? Track
            let liked = note.userInfo?[SoundCloudAPI.likeNotificationLikedKey] as? Bool
            Task { @MainActor in await self?.applyLikeChange(track: track, liked: liked) }
        })

        ticker = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            while !Task.isCancelled {
                await MainActor.run { self?.kick() }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }

        Task { indexedCount = await cache.likesCount() }
    }

    func handleDidBecomeActive() {
        kick()
    }

    func handleSignOut() {
        LibraryMetadataSyncEngine.shared.handleSignOut()
        runner?.cancel()
        runner = nil
        isSyncing = false
        indexedCount = 0
    }

    func indexedLikes(limit: Int? = nil) async -> (tracks: [Track], likedAt: [String: Date]) {
        guard Self.isEnabled else { return ([], [:]) }
        let rows = await cache.loadAllLikes(limit: limit)
        guard !rows.isEmpty else { return ([], [:]) }
        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            var tracks: [Track] = []
            var likedAt: [String: Date] = [:]
            tracks.reserveCapacity(rows.count)
            for row in rows {
                guard let track = try? decoder.decode(Track.self, from: row.payload) else { continue }
                tracks.append(track)
                if let millis = row.likedAtMillis {
                    likedAt[track.id] = Date(timeIntervalSince1970: Double(millis) / 1000)
                }
            }
            return (tracks, likedAt)
        }.value
    }

    func searchLibrary(_ query: String, limit: Int = 24) async -> [Track] {
        guard Self.isEnabled else { return [] }
        let rows = await cache.searchLikes(query: query, limit: limit)
        guard !rows.isEmpty else { return [] }
        let decoder = Self.makeDecoder()
        return rows.compactMap { try? decoder.decode(Track.self, from: $0.payload) }
    }

    func indexCompletedAt() async -> Date? {
        await cache.syncValue(forKey: StateKey.completedAt).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func didAdoptPeerLikes() async {
        indexedCount = await cache.likesCount()
        NotificationCenter.default.post(name: .likesIndexDidChange, object: nil)
    }

    func integrate(firstPage likes: [Like<Track>]) async {
        guard Self.isEnabled, !likes.isEmpty else { return }
        let generation = await currentGeneration()
        await ingest(likes, generation: generation)

        let boundary = likes.map(Self.millis(of:)).min() ?? 0
        let pageIDs = Set(likes.map(\.item.id))
        let newer = await cache.likeIDs(newerThanMillis: boundary)
        let stale = newer.filter { !pageIDs.contains($0) }
        if !stale.isEmpty {
            await cache.removeLikes(ids: stale)
            Log.library.info("Reconciled \(stale.count, privacy: .public) unliked track(s) out of the index")
        }

        indexedCount = await cache.likesCount()
        NotificationCenter.default.post(name: .likesIndexDidChange, object: nil)
    }

    private func kick() {
        guard activated, Self.isEnabled, api.hasCredentials, runner == nil else { return }
        runner = Task { [weak self] in
            await self?.sync()
            self?.runner = nil
        }
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }

        let now = Date()
        let resumeHref = await cache.syncValue(forKey: StateKey.nextHref)
        let completedAt = await indexCompletedAt()
        let toppedUpAt = await cache.syncValue(forKey: StateKey.toppedUpAt)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))

        if let resumeHref, let resumeURL = URL(string: resumeHref) {
            await walk(resumingFrom: resumeURL)
        } else if completedAt == nil || now.timeIntervalSince(completedAt!) > Self.fullWalkInterval {
            await walk(resumingFrom: nil)
        } else {
            let freshest = max(completedAt ?? .distantPast, toppedUpAt ?? .distantPast)
            if now.timeIntervalSince(freshest) > Self.topUpInterval {
                await topUp()
            }
        }
    }

    private func walk(resumingFrom resumeURL: URL?) async {
        let generation: Int64
        if resumeURL != nil {
            generation = await currentGeneration()
        } else {
            generation = await currentGeneration() + 1
            await cache.setSyncValue(String(generation), forKey: StateKey.generation)
        }

        var pages = 0
        var next = resumeURL
        var isFirstRequest = resumeURL == nil
        while !Task.isCancelled {
            guard api.hasCredentials else { return }

            let page: Page<Like<Track>>
            do {
                page = try await fetchPageWithRetry(from: isFirstRequest ? nil : next)
            } catch {
                Log.library.info("Likes walk parked after \(pages, privacy: .public) page(s); cursor kept, will resume")
                return
            }
            isFirstRequest = false
            pages += 1

            guard api.hasCredentials, !Task.isCancelled else { return }
            await ingest(page.collection, generation: generation)

            if let nextHref = page.nextHref {
                next = nextHref
                await cache.setSyncValue(nextHref.absoluteString, forKey: StateKey.nextHref)
                try? await Task.sleep(for: Self.interPageDelay)
            } else {
                let pruned = await cache.pruneLikes(olderThanGeneration: generation)
                await cache.setSyncValue(nil, forKey: StateKey.nextHref)
                await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: StateKey.completedAt)
                indexedCount = await cache.likesCount()
                Log.library.info("Likes walk complete: \(self.indexedCount, privacy: .public) indexed, \(pruned, privacy: .public) pruned, \(pages, privacy: .public) page(s) this run")
                NotificationCenter.default.post(name: .likesIndexDidChange, object: nil)
                return
            }
        }
    }

    private func topUp() async {
        guard let page = try? await fetchPageWithRetry(from: nil) else { return }
        await integrate(firstPage: page.collection)
        await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: StateKey.toppedUpAt)
    }

    private func fetchPageWithRetry(from url: URL?) async throws -> Page<Like<Track>> {
        var attempt = 0
        while true {
            do {
                if let url { return try await api.getLikesPage(from: url) }
                return try await api.getLikedTracks(limit: Self.pageLimit)
            } catch {
                // A traffic stop is not a transient retry condition. The API
                // persists its wait-until gate; park this walk and let the
                // normal lifecycle ticker reconsider it after that window.
                if case APIError.unauthorized = error { throw error }
                if case APIError.temporarilyBlocked = error { throw error }
                if case APIError.rateLimited = error { throw error }
                guard attempt < Self.retryDelays.count, !Task.isCancelled else { throw error }
                try await Task.sleep(for: Self.retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private func ingest(_ likes: [Like<Track>], generation: Int64) async {
        guard !likes.isEmpty else { return }
        let encoder = Self.makeEncoder()
        let rows: [LibraryCache.LikeIndexRow] = likes.compactMap { like in
            guard let payload = try? encoder.encode(like.item) else { return nil }
            return LibraryCache.LikeIndexRow(
                id: like.item.id,
                payload: payload,
                likedAtMillis: Self.millis(of: like),
                title: like.item.title,
                artist: "\(like.item.user.displayName) \(like.item.user.username)"
            )
        }
        await cache.upsertLikes(rows, generation: generation)
    }

    private func applyLikeChange(track: Track?, liked: Bool?) async {
        guard Self.isEnabled, let track, let liked else { return }
        if liked {
            guard let payload = try? Self.makeEncoder().encode(track) else { return }
            let row = LibraryCache.LikeIndexRow(
                id: track.id,
                payload: payload,
                likedAtMillis: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                title: track.title,
                artist: "\(track.user.displayName) \(track.user.username)"
            )
            await cache.upsertLikes([row], generation: await currentGeneration())
        } else {
            await cache.removeLikes(ids: [track.id])
        }
        indexedCount = await cache.likesCount()
        NotificationCenter.default.post(name: .likesIndexDidChange, object: nil)
    }

    private func currentGeneration() async -> Int64 {
        await cache.syncValue(forKey: StateKey.generation).flatMap(Int64.init) ?? 0
    }

    private nonisolated static func millis(of like: Like<Track>) -> Int64 {
        Int64((like.createdAt.timeIntervalSince1970 * 1000).rounded())
    }

    private nonisolated static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(makeFormatter())
        return decoder
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(makeFormatter())
        return encoder
    }
}

/// Slowly mirrors the account's saved-library metadata into `LibraryCache`.
/// This deliberately fetches JSON metadata only; audio remains an explicit
/// DownloadManager decision.
@MainActor
final class LibraryMetadataSyncEngine: ObservableObject {
    static let shared = LibraryMetadataSyncEngine()

    @Published private(set) var isSyncing = false
    @Published private(set) var statusText = "Updating library…"

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var activated = false
    private var runner: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    private static let activationDelay: Duration = .seconds(8)
    private static let interPageDelay: Duration = .milliseconds(450)
    private static let interCollectionDelay: Duration = .milliseconds(800)
    // Metadata hydration must remain a polite background task. In particular,
    // do not turn opening the app into an unbounded playlist-detail crawl.
    private static let maximumPlaylistManifestsPerRun = 48
    private static let tickInterval: Duration = .seconds(6 * 60 * 60)
    private static let completedKey = "libraryMetadata.completedAt"
    private static let playlistManifestOffsetKey = "libraryMetadata.playlistManifestOffset"

    private init() {}

    func activate() {
        guard !activated else { return }
        activated = true
        ticker = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            while !Task.isCancelled {
                self?.kick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func handleSignOut() {
        runner?.cancel()
        runner = nil
        isSyncing = false
    }

    private func kick() {
        guard api.hasCredentials, runner == nil else { return }
        runner = Task { [weak self] in
            await self?.sync()
            self?.runner = nil
        }
    }

    private func sync() async {
        isSyncing = true
        statusText = "Updating saved music…"
        defer { isSyncing = false }
        do {
            var discoveredPlaylists: [Playlist] = []
            var manifestCount = 0
            let library = try await walk(first: { try await api.getLibrary(limit: 100) }) { page in
                await persist("RecentlyAdded", values: page, id: Self.libraryItemID)
                let stations = page.compactMap(\.systemPlaylist)
                await persist("Stations", values: stations, id: \.id)
                await persist("Sets", values: stations, id: \.id)
                let playlists = page.compactMap(\.playlist)
                discoveredPlaylists.append(contentsOf: playlists)
                await persist("Playlists", values: playlists, id: \.id)
                await persist("LibraryAlbums", values: playlists.filter(\.isAlbum), id: \.id)
                await persist("Artists", values: Self.artists(in: page), id: \.id)
            }
            statusText = "Updating playlists…"
            _ = try await walk(first: { try await api.getLikedPlaylists(limit: 100) }) { page in
                discoveredPlaylists.append(contentsOf: page)
                await persist("LikedPlaylists", values: page, id: \.id)
                await persist("LikedAlbums", values: page.filter(\.isAlbum), id: \.id)
                await persist("Playlists", values: page, id: \.id)
                await persist("Artists", values: page.map(\.user), id: \.id)
            }
            if let user = await SoundCloudAPI.credentials?.waitForCurrentUser() {
                statusText = "Updating your playlists…"
                _ = try await walk(first: { try await self.api.getUserPlaylists(userId: user.id, limit: 100) }) { page in
                    discoveredPlaylists.append(contentsOf: page)
                    await self.persist("OwnedPlaylists", values: page, id: \.id)
                    await self.persist("OwnedAlbums", values: page.filter(\.isAlbum), id: \.id)
                    await self.persist("Playlists", values: page, id: \.id)
                }
            }
            guard !Task.isCancelled, api.hasCredentials else { return }

            var playlists = discoveredPlaylists
                .deduplicatedByID()
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

            let storedOffset = await cache.syncValue(forKey: Self.playlistManifestOffsetKey)
                .flatMap(Int.init) ?? 0
            let startOffset = playlists.isEmpty ? 0 : min(max(0, storedOffset), playlists.count - 1)
            let endOffset = min(playlists.count, startOffset + Self.maximumPlaylistManifestsPerRun)

            // Hydrate collection manifests at a background pace. This records
            // titles, artwork, membership and track metadata, never audio. A
            // durable rotating offset matters here: restarting at zero would
            // permanently starve playlist 49+ in a large library.
            for index in startOffset..<endOffset {
                guard !Task.isCancelled, api.hasCredentials else { return }
                manifestCount += 1
                statusText = "Indexing playlist \(index + 1) of \(playlists.count)…"
                do {
                    let playlist = try await api.getPlaylist(id: playlists[index].id)
                    var tracks = playlist.tracks ?? []
                    let missing = (playlist.trackIDs ?? []).filter { id in
                        !tracks.contains(where: { $0.id == id })
                    }
                    if !missing.isEmpty {
                        tracks.append(contentsOf: try await api.getPlaylistTracks(playlist, ids: missing))
                    }
                    playlists[index] = playlist
                    await persist("PlaylistTracks.\(playlist.id)", values: tracks.deduplicatedByID(), id: \.id)
                } catch {
                    if Self.isTrafficStop(error) {
                        await cache.setSyncValue(String(index), forKey: Self.playlistManifestOffsetKey)
                        statusText = "Waiting for SoundCloud"
                        Log.library.info("Metadata sync parked by SoundCloud traffic safety; playlist cursor retained")
                        return
                    }
                    Log.library.info("Metadata sync skipped playlist \(playlists[index].id, privacy: .public); it will retry later")
                }
                await cache.setSyncValue(String(index + 1), forKey: Self.playlistManifestOffsetKey)
                try? await Task.sleep(for: Self.interCollectionDelay)
            }

            await persist("Playlists", values: playlists, id: \.id)
            if endOffset >= playlists.count {
                await cache.setSyncValue("0", forKey: Self.playlistManifestOffsetKey)
                await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: Self.completedKey)
                statusText = "Library up to date"
            } else {
                statusText = "Indexed \(endOffset) of \(playlists.count) playlists; continuing later"
            }
            Log.library.info("Library metadata sync complete: \(library.count, privacy: .public) saved item(s), \(playlists.count, privacy: .public) collection(s)")
        } catch {
            Log.library.info("Library metadata sync parked; the last complete database snapshot remains available")
        }
    }

    private func walk<T: Decodable>(
        first: () async throws -> Page<T>,
        onPage: @MainActor ([T]) async -> Void
    ) async throws -> [T] {
        var page = try await first()
        let firstCollection = page.collection
        var values = firstCollection
        await onPage(firstCollection)
        while page.nextHref != nil, !Task.isCancelled, api.hasCredentials {
            try await Task.sleep(for: Self.interPageDelay)
            page = try await api.getNextPage(page)
            let nextCollection = page.collection
            values.append(contentsOf: nextCollection)
            await onPage(nextCollection)
        }
        return values
    }

    private func persist<T: Encodable>(
        _ section: String,
        values: [T],
        id: (T) -> String
    ) async {
        let encoder = LikesSyncEngine.makeEncoder()
        let rows = values.compactMap { value -> LibraryCache.WriteRow? in
            guard let payload = try? encoder.encode(value) else { return nil }
            return LibraryCache.WriteRow(id: id(value), payload: payload)
        }
        // A paged walk writes each page as it arrives. Keeping old rows until
        // a future complete reconciliation means cached library views never
        // flash empty during an interrupted refresh.
        await cache.mergeSection(section, rows: rows)
    }

    private static func libraryItemID(_ item: LibraryItem) -> String {
        item.track?.id ?? item.playlist?.id ?? item.systemPlaylist?.id ?? "library-\(item.createdAt.timeIntervalSince1970)"
    }

    private static func artists(in items: [LibraryItem]) -> [User] {
        (items.compactMap { $0.track?.user } + items.compactMap { $0.playlist?.user })
            .deduplicatedByID()
    }

    private static func isTrafficStop(_ error: Error) -> Bool {
        if case APIError.temporarilyBlocked = error { return true }
        if case APIError.rateLimited = error { return true }
        return false
    }
}
