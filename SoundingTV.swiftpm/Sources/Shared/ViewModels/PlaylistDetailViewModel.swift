import Foundation
import os

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published private(set) var playlist: Playlist
    @Published var tracks: [Track]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    private var cursor: PlaylistTrackCursor
    private let api = SoundCloudAPI.shared
    private var didLoad = false

    init(playlist: Playlist) {
        self.playlist = playlist
        self.tracks = playlist.loadedTracks
        self.cursor = PlaylistTrackCursor(playlist: playlist)
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func load() async {
        #if DEBUG && os(tvOS)
        if VisualFixtures.isEnabled {
            didLoad = true
            tracks = playlist.loadedTracks
            return
        }
        #endif

        didLoad = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let full = try await api.getPlaylist(id: playlist.id)
            playlist = full
            tracks = full.loadedTracks
            cursor = PlaylistTrackCursor(playlist: full)
            await loadMore()
        } catch {
            errorMessage = "Couldn't reach SoundCloud. Check your connection and try again."
        }
    }

    func loadMore() async {
        guard !isLoadingMore, cursor.canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let batch = cursor.nextBatch()
        guard !batch.isEmpty else { return }
        do {
            let fetched = try await api.getPlaylistTracks(playlist, ids: batch)
            cursor.accept(fetched, for: batch)
            tracks.appendUnique(contentsOf: fetched)
        } catch {
            Log.ui.error("Playlist load-more error (\(self.playlist.id, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
}
