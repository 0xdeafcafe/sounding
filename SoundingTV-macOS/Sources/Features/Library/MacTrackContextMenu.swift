import SwiftUI
import AppKit

extension View {
    @ViewBuilder
    func macTrackContextMenu(track: Track) -> some View {
        self.contextMenu {
            MacTrackContextMenu(track: track)
        }
    }
}

struct MacTrackContextMenu: View {
    let track: Track
    var contextPlaylist: Playlist? = nil
    var context: [Track] = []

    @ObservedObject private var engagement = MacTrackEngagement.shared
    @ObservedObject private var downloads = DownloadManager.shared

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        header

        Divider()

        if isPlayable {
            Button("Play") {
                let queue = context.contains(where: { $0.id == track.id }) ? context : [track]
                Task { await PlayerService.shared.play(track, in: queue) }
            }
            Button("Play Next") {
                let player = PlayerService.shared
                player.insertIntoQueue(track, at: player.currentIndex + 1)
            }
            Button("Play Last") {
                PlayerService.shared.addToQueue(track)
            }
            Divider()
        }

        likeButton

        Menu {
            MacAddToPlaylistMenuItems(track: track)
        } label: {
            Label("Add to Playlist", systemImage: "plus.square.on.square")
        }

        if isPlayable {
            downloadButton
        }

        if track.mixSource != nil {
            Divider()
            Button {
                Task { try? await MacMixLoader.load(track, into: .a) }
            } label: {
                Label("Load to Deck A", systemImage: "a.square")
            }
            Button {
                Task { try? await MacMixLoader.load(track, into: .b) }
            } label: {
                Label("Load to Deck B", systemImage: "b.square")
            }
        }

        Divider()

        Menu {
            Button {
                Task { await MacAnalysisRunner.analyse(track, force: true) }
            } label: {
                Label("Analyse Again", systemImage: "arrow.clockwise")
            }
            .disabled(track.streamURL == nil)

            Button {
                Task { await MacAnalysisIndex.shared.forgetAnalysis(forTrackId: track.id) }
            } label: {
                Label("Forget Analysis", systemImage: "trash")
            }

            Divider()

            Button {
                MacRootSelection.shared.request(.intelligence)
            } label: {
                Label("Show in Music Intelligence", systemImage: "waveform.badge.magnifyingglass")
            }
        } label: {
            Label("Analysis", systemImage: "waveform.badge.magnifyingglass")
        }

        Divider()

        Button {
            MacRootSelection.shared.request(artist: track.user)
        } label: {
            Label("Go to Artist", systemImage: "person.crop.circle")
        }
        MacGoToAlbumMenuItem(track: track, contextPlaylist: contextPlaylist)

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(track.permalinkURL.absoluteString, forType: .string)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: track.permalinkURL, subject: Text(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            MacMessageComposer.shared.present(track: track)
        } label: {
            Label("Send in SoundCloud Message", systemImage: "bubble.left.and.bubble.right")
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if case .downloaded = downloads.state(for: track.id) {
            Button {
                downloads.cancel(trackId: track.id)
            } label: {
                Label("Remove Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                _ = downloads.download(track)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(downloads.downloadRefusalReason(for: track) != nil)
        }
    }

    private var header: some View {
        Button(action: {}) {
            HStack(spacing: 8) {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.title,
                    size: 30,
                    cornerRadius: 4,
                    isAvailable: track.streamURL != nil,
                    crownUser: track.user,
                    crownContext: track.title
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(track.user.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(true)
    }

    private var likeButton: some View {
        Button {
            Task { await engagement.toggleLike(track) }
        } label: {
            Label(
                engagement.isLiked(track) ? "Unlike" : "Like",
                systemImage: engagement.isLiked(track) ? "heart.fill" : "heart"
            )
        }
    }
}

@MainActor
final class MacPlaylistCache: ObservableObject {
    static let shared = MacPlaylistCache()

    enum State {
        case idle
        case loading
        case loaded([PlaylistSummary])
        case failed
    }

    @Published private(set) var state: State = .idle
    private var loadTask: Task<Void, Never>?

    private init() {}

    func ensureLoaded() {
        switch state {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        state = .loading
        loadTask = Task {
            do {
                let page = try await SoundCloudAPI.shared.getMyPlaylists()
                state = .loaded(page.collection)
            } catch {
                state = .failed
            }
        }
    }
}

private struct MacAddToPlaylistMenuItems: View {
    let track: Track

    @ObservedObject private var cache = MacPlaylistCache.shared
    @State private var pendingPlaylistId: String?

    var body: some View {
        Group {
            switch cache.state {
            case .idle, .loading:
                Button("Loading Playlists…") {}.disabled(true)
            case .failed:
                Button("Couldn't Load Playlists - Try Again") { cache.reload() }
            case .loaded(let playlists) where playlists.isEmpty:
                Button("No Playlists Yet") {}.disabled(true)
            case .loaded(let playlists):
                ForEach(playlists) { playlist in
                    Button {
                        addTrack(to: playlist)
                    } label: {
                        Text(playlist.title)
                    }
                    .disabled(pendingPlaylistId == playlist.id)
                }
            }
        }
        .task { cache.ensureLoaded() }
    }

    private func addTrack(to playlist: PlaylistSummary) {
        guard pendingPlaylistId == nil else { return }
        pendingPlaylistId = playlist.id
        Task {
            try? await SoundCloudAPI.shared.addTrack(track.id, toPlaylist: playlist.id)
            pendingPlaylistId = nil
        }
    }
}

private struct MacGoToAlbumMenuItem: View {
    let track: Track
    var contextPlaylist: Playlist? = nil

    @State private var albumPlaylist: PlaylistSummary?
    @State private var checked = false

    var body: some View {
        Group {
            if checked, let albumPlaylist, let url = albumPlaylist.permalinkURL, albumPlaylist.id != contextPlaylist?.id {
                Button {
                    Task { await openAlbum(at: url) }
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
        .task(id: track.id) {
            if let cached = MacAlbumLookupCache.cache[track.id] {
                albumPlaylist = cached
                checked = true
                return
            }
            let page = try? await SoundCloudAPI.shared.getPlaylistsContaining(trackId: track.id)
            let found = page?.collection.first { $0.isAlbum }
            MacAlbumLookupCache.cache[track.id] = found
            albumPlaylist = found
            checked = true
        }
    }

    private func openAlbum(at url: URL) async {
        if let resolved = try? await SoundCloudAPI.shared.resolve(url: url), case .playlist(let playlist) = resolved {
            MacRootSelection.shared.request(playlist: playlist)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private enum MacAlbumLookupCache {
    static var cache: [String: PlaylistSummary?] = [:]
}
