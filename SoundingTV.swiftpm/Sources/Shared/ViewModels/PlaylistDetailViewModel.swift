import Foundation
import Combine
import os

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published private(set) var playlist: Playlist

    let pager: Paginator<Track>

    var tracks: [Track] {
        get { pager.items }
        set { pager.prime(items: newValue, cursor: pager.cursor, total: pager.total) }
    }

    var isLoading: Bool { pager.isLoadingFirst || (pager.isPaused && pager.items.isEmpty) }
    var isLoadingMore: Bool { pager.isLoadingMore }
    var errorMessage: String? {
        pager.firstError == nil ? nil : "Couldn't reach SoundCloud. Check your connection and try again."
    }

    private var trackIDs: [String]
    private let api = SoundCloudAPI.shared
    private var didLoad = false
    private var pagerObservation: AnyCancellable?

    init(playlist: Playlist) {
        self.playlist = playlist
        #if !os(watchOS)
        PlaybackQueueSourceDirectory.note(playlist)
        #endif
        let ids = PlaylistTrackCursor(playlist: playlist).trackIDs
        trackIDs = ids
        pager = Paginator(soundCloudSource: PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) }))
        pager.setSource(PagedSource(
            first: { [weak self] in
                guard let self else { return PagedChunk(items: []) }
                return try await self.fetchFirst()
            },
            next: { [weak self] cursor in
                guard let self else { return PagedChunk(items: []) }
                return try await self.fetchBatch(after: cursor)
            }
        ))
        pager.prime(
            items: playlist.loadedTracks,
            cursor: ids.isEmpty ? nil : .offset(0),
            total: playlist.totalTrackCount
        )
        pagerObservation = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func load() async {
        #if DEBUG && os(tvOS)
        if VisualFixtures.isEnabled {
            didLoad = true
            pager.prime(items: playlist.loadedTracks, cursor: nil)
            return
        }
        #endif

        didLoad = true
        if let stored = await LibraryDB.playlistTracks(id: playlist.id), !stored.isEmpty {
            pager.prime(items: stored, cursor: nil, total: stored.count)
            return
        }
        await pager.reload()
        if pager.firstError == nil, !Task.isCancelled {
            while !Task.isCancelled, pager.hasMore, !pager.isPaused, !pager.didFailLoadingMore {
                let before = pager.items.count
                await pager.loadMore()
                if pager.items.count == before { break }
            }
        }
    }

    func loadMore() async {
        await pager.loadMore()
    }

    func applyEdit(_ edited: Playlist, tracks edits: [Track]?) {
        playlist = edited
        if let ids = edited.trackIDs { trackIDs = ids }
        guard let edits else { return }
        let next: PagedCursor? = pager.cursor == nil ? nil : .offset(edits.count)
        pager.prime(items: edits, cursor: next, total: edited.totalTrackCount)
    }

    func requestMore() {
        pager.requestMore()
    }

    private func fetchFirst() async throws -> PagedChunk<Track> {
        let full = try await api.getPlaylist(id: playlist.id)
        playlist = full
        trackIDs = PlaylistTrackCursor(playlist: full).trackIDs
        return PagedChunk(
            items: full.loadedTracks,
            next: trackIDs.isEmpty ? nil : .offset(0),
            total: full.totalTrackCount
        )
    }

    private func fetchBatch(after cursor: PagedCursor) async throws -> PagedChunk<Track> {
        guard case .offset(let offset) = cursor, offset < trackIDs.count else { return PagedChunk(items: []) }
        let end = min(offset + PlaylistTrackCursor.batchSize, trackIDs.count)
        let batch = Array(trackIDs[offset..<end])
        let fetched = try await api.getPlaylistTracks(playlist, ids: batch)
        return PagedChunk(items: fetched, next: end < trackIDs.count ? .offset(end) : nil)
    }
}
