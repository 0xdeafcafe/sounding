import Foundation
import Combine

@MainActor
final class LikesSyncEngine: ObservableObject {
    static let shared = LikesSyncEngine()

    @Published private(set) var indexedCount = 0
    @Published private(set) var isSyncing = false
    /// Monotonic state revision for subscribers that care about content
    /// changes even when the total item count is unchanged.
    @Published private(set) var revision = 0

    private let cache = LibraryCache.shared
    private let api = SoundCloudAPI.shared
    private let scheduler = WorkScheduler.shared

    private var activated = false
    private var runner: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let pageLimit = 100
    private static let interPageDelay: Duration = .milliseconds(500)
    private static let activationDelay: Duration = .seconds(4)
    private static let tickInterval: Duration = .seconds(60 * 60)
    private static let topUpInterval: TimeInterval = 60 * 60
    private static let topUpPageLimit = 10
    private static let walkPagesPerSegment = 5
    private static let walkSegmentInterval: TimeInterval = 15 * 60
    private static let fullWalkInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let retryBackoff = SoundCloudBackoff(base: 2, cap: 60)
    private static let maximumRetries = 3

    private enum StateKey {
        static let nextHref = "likes.nextHref"
        static let generation = "likes.generation"
        static let completedAt = "likes.completedAt"
        static let toppedUpAt = "likes.toppedUpAt"
        static let segmentAt = "likes.walkSegmentAt"
    }

    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LIKES_INDEX"] == "0" { return false }
        #endif
        return true
    }

    func activate() {
        guard Self.isEnabled, !activated else { return }
        activated = true
        LibrarySyncEngine.shared.activate()
        Task { indexedCount = await cache.likesCount() }
    }

    func handleDidBecomeActive() {
        LibrarySyncEngine.shared.handleDidBecomeActive()
    }

    func handleSignOut() {
        LibraryMetadataSyncEngine.shared.handleSignOut()
        Task { await LibrarySyncEngine.shared.handleSignOut() }
        runner?.cancel()
        runner = nil
        isSyncing = false
        indexedCount = 0
        revision &+= 1
    }

    func indexedLikes(offset: Int = 0, limit: Int? = nil) async -> (tracks: [Track], likedAt: [String: Date]) {
        guard Self.isEnabled else { return ([], [:]) }
        let rows = await cache.loadAllLikes(offset: offset, limit: limit)
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
        await LibrarySQLiteStore.shared.cursor(.likes).completedAt
    }

    func didAdoptPeerLikes() async {
        await publishIndexChange()
    }

    func integrate(firstPage likes: [Like<Track>]) async {
        guard Self.isEnabled, !likes.isEmpty else { return }
        let generation = await currentGeneration()
        await ingest(likes, generation: generation)

        let boundary = likes.map(Self.millis(of:)).min() ?? 0
        let pageIDs = Set(likes.map(\.item.id))
        let newer = await cache.likeIDs(newerThanMillis: boundary)
        let pending = await LibrarySyncEngine.shared.pendingMutations(.likes)
        let stale = newer.filter { !pageIDs.contains($0) && pending[LibraryRecord.key(.track, $0)] != true }
        if !stale.isEmpty {
            await cache.removeLikes(ids: stale)
            Log.library.info("Reconciled \(stale.count, privacy: .public) unliked track(s) out of the index")
        }
        await LibrarySyncEngine.shared.reassertPending(.likes)

        await publishIndexChange()
    }

    func integrate(laterPage likes: [Like<Track>]) async {
        guard Self.isEnabled, !likes.isEmpty else { return }
        await ingest(likes, generation: await currentGeneration())
        await LibrarySyncEngine.shared.reassertPending(.likes)
        indexedCount = await cache.likesCount()
    }

    private func kick() {
        LibrarySyncEngine.shared.kick()
    }

    private func legacyKick() {
        guard activated,
              Self.isEnabled,
              api.hasCredentials,
              SoundCloudGateway.shared.isApplicationForeground,
              runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                await self.sync()
            }
            self.runner = nil
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
            let segmentAt = await cache.syncValue(forKey: StateKey.segmentAt)
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            guard now.timeIntervalSince(segmentAt ?? .distantPast) >= Self.walkSegmentInterval else { return }
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
                if pages >= Self.walkPagesPerSegment {
                    await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: StateKey.segmentAt)
                    await publishIndexChange()
                    Log.library.info("Likes walk paused after \(pages, privacy: .public) page(s); resumes in the next segment")
                    return
                }
                try? await Task.sleep(for: Self.interPageDelay)
            } else {
                let pruned = await cache.pruneLikes(olderThanGeneration: generation)
                await cache.setSyncValue(nil, forKey: StateKey.nextHref)
                await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: StateKey.completedAt)
                await publishIndexChange()
                Log.library.info("Likes walk complete: \(self.indexedCount, privacy: .public) indexed, \(pruned, privacy: .public) pruned, \(pages, privacy: .public) page(s) this run")
                return
            }
        }
    }

    private func topUp() async {
        var window: [Like<Track>] = []
        var next: URL?
        var reachedKnownLike = false
        for pageIndex in 0..<Self.topUpPageLimit {
            guard !Task.isCancelled, api.hasCredentials,
                  let page = try? await fetchPageWithRetry(from: pageIndex == 0 ? nil : next) else { break }
            window.append(contentsOf: page.collection)
            for like in page.collection {
                if await cache.containsLike(id: like.item.id) {
                    reachedKnownLike = true
                    break
                }
            }
            next = page.nextHref
            if reachedKnownLike || next == nil { break }
            try? await Task.sleep(for: Self.interPageDelay)
        }
        guard !window.isEmpty else { return }
        await integrate(firstPage: window)
        if !reachedKnownLike, let next {
            await cache.setSyncValue(next.absoluteString, forKey: StateKey.nextHref)
        }
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
                if error is SoundCloudGatewayError { throw error }
                guard attempt < Self.maximumRetries, !Task.isCancelled else { throw error }
                try await Task.sleep(for: Self.retryBackoff.duration(attempt: attempt))
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
        await publishIndexChange()
    }

    private func publishIndexChange() async {
        indexedCount = await cache.likesCount()
        revision &+= 1
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
    private let scheduler = WorkScheduler.shared
    private var activated = false
    private var runner: Task<Void, Never>?

    private static let activationDelay: Duration = .seconds(8)
    private static let interPageDelay: Duration = .milliseconds(450)
    private static let libraryPageLimit = 3
    private static let collectionPageLimit = 10
    private static let tickInterval: Duration = .seconds(24 * 60 * 60)
    private static let minimumRunInterval: TimeInterval = 24 * 60 * 60
    private static let completedKey = "libraryMetadata.completedAt"
    private static let attemptedKey = "libraryMetadata.attemptedAt"

    private init() {}

    func activate() {
        guard !activated else { return }
        activated = true
        scheduler.registerPeriodic(
            id: "library.metadata.refresh",
            scope: "library",
            initialDelay: Self.activationDelay,
            interval: Self.tickInterval,
            condition: {
                SoundCloudGateway.shared.isApplicationForeground
            }
        ) { [weak self] in
            self?.kick()
        }
    }

    func handleSignOut() {
        runner?.cancel()
        runner = nil
        isSyncing = false
    }

    func handleDidBecomeActive() {
        kick()
    }

    private func kick() {
        guard api.hasCredentials,
              SoundCloudGateway.shared.isApplicationForeground,
              runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                await self.sync()
            }
            self.runner = nil
        }
    }

    private func sync() async {
        isSyncing = true
        statusText = "Updating saved music…"
        defer { isSyncing = false }

        let now = Date()
        let lastAttempt = await cache.syncValue(forKey: Self.attemptedKey)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        guard lastAttempt.map({ now.timeIntervalSince($0) >= Self.minimumRunInterval }) ?? true else {
            statusText = "Library up to date"
            return
        }
        // Persist before the first request. Relaunching during an interrupted
        // crawl must not restart the entire archive census.
        await cache.setSyncValue(String(now.timeIntervalSince1970), forKey: Self.attemptedKey)

        do {
            var discoveredPlaylists: [Playlist] = []
            let library = try await walk(pageLimit: Self.libraryPageLimit, first: { try await api.getLibrary(limit: 100) }) { page in
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
            _ = try await walk(pageLimit: Self.collectionPageLimit, first: { try await api.getLikedPlaylists(limit: 100) }) { page in
                discoveredPlaylists.append(contentsOf: page)
                await persist("LikedPlaylists", values: page, id: \.id)
                await persist("LikedAlbums", values: page.filter(\.isAlbum), id: \.id)
                await persist("Playlists", values: page, id: \.id)
                await persist("Artists", values: page.map(\.user), id: \.id)
            }
            if let user = await SoundCloudAPI.credentials?.waitForCurrentUser() {
                statusText = "Updating your playlists…"
                _ = try await walk(pageLimit: Self.collectionPageLimit, first: { try await self.api.getUserPlaylists(userId: user.id, limit: 100) }) { page in
                    discoveredPlaylists.append(contentsOf: page)
                    await self.persist("OwnedPlaylists", values: page, id: \.id)
                    await self.persist("OwnedAlbums", values: page.filter(\.isAlbum), id: \.id)
                    await self.persist("Playlists", values: page, id: \.id)
                }
            }
            guard !Task.isCancelled, api.hasCredentials else { return }

            let playlists = discoveredPlaylists
                .deduplicatedByID()
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            await persist("Playlists", values: playlists, id: \.id)
            // Playlist track manifests are intentionally hydrated only when a
            // person opens, pins, downloads, or plays that playlist. A broad
            // autonomous manifest crawl can multiply one library refresh into
            // hundreds of `/tracks?ids=` calls for large collections.
            await cache.setSyncValue(String(Date().timeIntervalSince1970), forKey: Self.completedKey)
            statusText = "Library up to date"
            Log.library.info("Library metadata sync complete: \(library.count, privacy: .public) saved item(s), \(playlists.count, privacy: .public) collection(s)")
        } catch {
            Log.library.info("Library metadata sync parked; the last complete database snapshot remains available")
        }
    }

    private func walk<T: Decodable>(
        pageLimit: Int,
        first: () async throws -> Page<T>,
        onPage: @MainActor ([T]) async -> Void
    ) async throws -> [T] {
        var page = try await first()
        let firstCollection = page.collection
        var values = firstCollection
        var pages = 1
        await onPage(firstCollection)
        while page.nextHref != nil, pages < pageLimit, !Task.isCancelled, api.hasCredentials {
            pages += 1
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

}
