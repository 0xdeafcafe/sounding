import AppIntents
import Combine
import CoreSpotlight
import Foundation

private struct SearchableIndexHandle: @unchecked Sendable {
    private let index = CSSearchableIndex.default()

    func index(_ track: Track) async throws {
        try await index.indexAppEntities([TrackEntity(track)])
    }

    func index(_ tracks: [TrackEntity]) async throws {
        guard !tracks.isEmpty else { return }
        try await index.indexAppEntities(tracks)
    }

    func index(_ playlists: [PlaylistEntity]) async throws {
        guard !playlists.isEmpty else { return }
        try await index.indexAppEntities(playlists)
    }

    func index(_ setlists: [SetlistEntity]) async throws {
        guard !setlists.isEmpty else { return }
        try await index.indexAppEntities(setlists)
    }

    func deleteTrack(identifiedBy id: String) async throws {
        try await index.deleteAppEntities(identifiedBy: [id], ofType: TrackEntity.self)
    }

    func deleteTracks(identifiedBy ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await index.deleteAppEntities(identifiedBy: ids, ofType: TrackEntity.self)
    }

    func deletePlaylists(identifiedBy ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await index.deleteAppEntities(identifiedBy: ids, ofType: PlaylistEntity.self)
    }

    func deleteSetlists(identifiedBy ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await index.deleteAppEntities(identifiedBy: ids, ofType: SetlistEntity.self)
    }

    func deleteAll() async throws {
        try await index.deleteAllSearchableItems()
    }
}

@MainActor
final class SpotlightIndexingService {
    static let shared = SpotlightIndexingService()

    private static let playDonationDelay: Duration = .seconds(8)
    private static let libraryIndexDelay: Duration = .seconds(30)
    private static let libraryBatchSize = 200
    private static let queue = WorkScheduler.QueueID(rawValue: "integration.spotlight")

    private let index = SearchableIndexHandle()
    private let scheduler = WorkScheduler.shared
    private var cancellables = Set<AnyCancellable>()
    private weak var player: PlayerService?
    private var indexedSetlists: [String: Date] = [:]
    private var lastRelevantTrackID: String?
    private var insightsIndexedThrough = Date.distantPast

    private init() {}

    func start(player: PlayerService) {
        self.player = player
        player.$currentTrack
            .combineLatest(player.$isPlaying)
            .sink { [weak self] track, isPlaying in
                self?.scheduleDonation(for: track, isPlaying: isPlaying)
                self?.noteNowPlaying(track)
            }
            .store(in: &cancellables)

        SoundCloudAPI.shared.$latestLikeChange
            .compactMap { $0 }
            .sink { [weak self] change in
                self?.handleLikeChange(change)
            }
            .store(in: &cancellables)

        SetlistIntelligenceStore.shared.$setlists
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] setlists in
                self?.reconcileSetlists(setlists)
            }
            .store(in: &cancellables)

        LikesSyncEngine.shared.$revision
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleLibraryIndex()
            }
            .store(in: &cancellables)

        GeneratedInsightsService.shared.$insights
            .dropFirst()
            .debounce(for: .seconds(10), scheduler: RunLoop.main)
            .sink { [weak self] insights in
                self?.indexGeneratedTags(insights)
            }
            .store(in: &cancellables)

        SoundCloudCredentialSource.shared.$state
            .map(\.isSignedOut)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.clearIndex()
            }
            .store(in: &cancellables)
    }

    private func noteNowPlaying(_ track: Track?) {
        guard track?.id != lastRelevantTrackID else { return }
        lastRelevantTrackID = track?.id
        if #available(iOS 27.0, macOS 27.0, *) {
            AudioSchemaSupport.noteNowPlaying(track)
        }
    }

    private func reconcileSetlists(_ setlists: [String: GeneratedSetlist]) {
        let saved = setlists.values.filter(\.isSaved)
        let current = Dictionary(saved.map { ($0.trackId, $0.updatedAt) }, uniquingKeysWith: max)
        let changed = saved.filter { indexedSetlists[$0.trackId] != $0.updatedAt }.map(SetlistEntity.init)
        let removed = indexedSetlists.keys.filter { current[$0] == nil }
        indexedSetlists = current
        guard !changed.isEmpty || !removed.isEmpty else { return }
        Task { [index] in
            try? await index.index(changed)
            try? await index.deleteSetlists(identifiedBy: removed)
        }
    }

    // MARK: Library

    private func scheduleLibraryIndex() {
        scheduler.submit(
            queue: Self.queue,
            key: "library-index",
            delivery: .latest,
            delay: Self.libraryIndexDelay,
            priority: .background
        ) { [weak self] in
            await self?.indexLibrary()
            await self?.backfillGeneratedTags()
        }
    }

    private func indexLibrary() async {
        guard SoundCloudAPI.credentials?.accessToken != nil else { return }
        let local = DeviceLocalCatalog()
        let library = local.library
        let likeIDs = await library.likeIDs(newerThanMillis: -1)
        var playlists = await local.cachedPlaylists().map(PlaylistEntity.init)
        if !likeIDs.isEmpty {
            playlists.insert(PlaylistEntity.likes(trackCount: likeIDs.count), at: 0)
        }

        var ledger = SpotlightLibraryLedger.load()
        let plan = ledger.plan(likeIDs: likeIDs, playlists: playlists)
        guard plan != .init(likesToIndex: [], likesToRemove: [], playlistsToIndex: [], playlistsToRemove: []) else { return }

        let decoder = LikesSyncEngine.makeDecoder()
        var start = 0
        while start < plan.likesToIndex.count {
            let chunk = Array(plan.likesToIndex[start..<min(start + Self.libraryBatchSize, plan.likesToIndex.count)])
            start += chunk.count
            let entities = await library.loadLikes(ids: chunk)
                .compactMap { try? decoder.decode(Track.self, from: $0.payload) }
                .map(TrackEntity.init)
            do {
                try await index.index(entities)
                ledger.likeIDs.formUnion(entities.map(\.id))
            } catch {
                break
            }
            await Task.yield()
        }

        if (try? await index.deleteTracks(identifiedBy: plan.likesToRemove)) != nil {
            ledger.likeIDs.subtract(plan.likesToRemove)
        }

        let changedPlaylists = playlists.filter { plan.playlistsToIndex.contains($0.id) }
        if (try? await index.index(changedPlaylists)) != nil {
            for playlist in changedPlaylists {
                ledger.playlistDigests[playlist.id] = SpotlightLibraryLedger.playlistDigest(playlist)
            }
        }
        if (try? await index.deletePlaylists(identifiedBy: plan.playlistsToRemove)) != nil {
            for id in plan.playlistsToRemove { ledger.playlistDigests[id] = nil }
        }
        ledger.save()
    }

    // MARK: Generated tags

    private func backfillGeneratedTags() async {
        let service = GeneratedInsightsService.shared
        guard service.isEnabled else { return }
        await service.loadCache()
        let tracks = await DeviceLocalCatalog().recentLikedTracks(limit: 150)
        for track in tracks where service.insights[track.id] == nil {
            service.request(GeneratedInsightInputs.input(for: track, comments: [], waveform: nil), isBackground: true)
        }
    }

    private func indexGeneratedTags(_ insights: [String: GeneratedInsights]) {
        let fresh = insights.values.filter { $0.generatedAt > insightsIndexedThrough && !$0.tags.isEmpty }
        guard !fresh.isEmpty, GeneratedInsightsService.shared.isEnabled else { return }
        insightsIndexedThrough = fresh.map(\.generatedAt).max() ?? insightsIndexedThrough
        let tags = Dictionary(uniqueKeysWithValues: fresh.map { ($0.trackId, $0.tags) })
        Task { [index] in
            let tracks = await DeviceLocalCatalog().likedTracks(ids: Array(tags.keys))
            let entities = tracks.map { track -> TrackEntity in
                var entity = TrackEntity(track)
                entity.keywords += tags[track.id] ?? []
                return entity
            }
            try? await index.index(entities)
        }
    }

    private func clearIndex() {
        scheduler.cancelPending(keyPrefix: "library-index", in: [Self.queue])
        indexedSetlists = [:]
        SpotlightLibraryLedger.reset()
        Task { [index] in
            try? await index.deleteAll()
        }
    }

    // MARK: Donations

    private func scheduleDonation(for track: Track?, isPlaying: Bool) {
        scheduler.cancelPending(keyPrefix: "play-donation", in: [Self.queue])
        guard let track, isPlaying else { return }

        let trackId = track.id
        scheduler.submit(
            queue: Self.queue,
            key: "play-donation",
            delivery: .latest,
            delay: Self.playDonationDelay,
            priority: .background
        ) { [weak self] in
            guard let self,
                  self.player?.currentTrack?.id == trackId,
                  self.player?.isPlaying == true else { return }
            await self.donate(track)
        }
    }

    private func handleLikeChange(_ change: SoundCloudLikeChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if change.isLiked {
                await self.donate(change.track)
            } else {
                try? await self.index.deleteTrack(identifiedBy: change.track.id)
            }
        }
    }

    private func donate(_ track: Track) async {
        do {
            try await index.index(track)
        } catch {
        }
    }
}
