import SwiftUI

struct PlaylistGridView: View {
    let playlists: [Playlist]
    var columns: Int = TVGridMetrics.columns
    var paging: TVPaging?
    var emptyIcon = "music.note.list"
    var emptyTitle = "No playlists"
    var pinsLikes = false

    @ObservedObject private var folders = PlaylistFolderStore.shared

    private static let artworkLookahead = 12

    private var shownFolders: [PlaylistFolder] {
        pinsLikes ? folders.rootFolders : []
    }

    private var shownPlaylists: [Playlist] {
        pinsLikes ? playlists.filter { !folders.isFoldered($0.id) } : playlists
    }

    var body: some View {
        let playlists = shownPlaylists
        if playlists.isEmpty, !pinsLikes {
            StatusPanel(kind: .empty, icon: emptyIcon, title: emptyTitle, minHeight: 520)
            if let paging {
                TVPagedFooter(paging: paging)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: Space.base) {
                LazyVGrid(columns: TVGridMetrics.gridItems(columns), alignment: .leading, spacing: TVGridMetrics.rowSpacing) {
                    if pinsLikes {
                        NavigationLink(value: LibraryFilter.likes) {
                            LikesPlaylistCard(style: SCBrowseMetrics.tile)
                        }
                        .accessibilityIdentifier("library.playlists.grid.likes")
                    }
                    ForEach(shownFolders) { folder in
                        NavigationLink {
                            TVPlaylistFolderView(folderID: folder.id)
                        } label: {
                            PlaylistFolderCard(folder: folder, style: .tv)
                        }
                    }
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistCard(playlist: playlist)
                        }
                        .onAppear {
                            guard playlists.isNearEnd(playlist, lead: 12) else { return }
                            paging?.loadMore()
                        }
                        .onAppear {
                            let lookahead = playlists[index..<min(index + Self.artworkLookahead, playlists.count)]
                            ArtworkCache.shared.prefetch(lookahead.flatMap { playlist in
                                [playlist.largeArtworkURL].compactMap { $0 }
                                    + playlist.loadedTracks.prefix(4).compactMap(\.artworkURL)
                            })
                        }
                    }
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                .focusEffectDisabled()

                if let paging {
                    TVPagedFooter(paging: paging)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TVPlaylistFolderView: View {
    let folderID: String

    @ObservedObject private var store = PlaylistFolderStore.shared

    var body: some View {
        let entries = store.entries(in: folderID)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(store.folder(folderID)?.name ?? "")
                        .font(.tvTitle)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(store.summary(for: folderID))
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                }
                if entries.isEmpty {
                    ContentUnavailableView("No Playlists", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 600)
                } else {
                    LazyVGrid(columns: TVGridMetrics.gridItems(), alignment: .leading, spacing: TVGridMetrics.rowSpacing) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .folder(let child):
                                NavigationLink {
                                    TVPlaylistFolderView(folderID: child.id)
                                } label: {
                                    PlaylistFolderCard(folder: child, style: .tv)
                                }
                            case .playlist(let playlist):
                                NavigationLink {
                                    PlaylistDetailView(playlist: playlist)
                                } label: {
                                    PlaylistCard(playlist: playlist)
                                }
                            }
                        }
                    }
                    .buttonStyle(SCCardButtonStyle())
                    .focusEffectDisabled()
                }
            }
            .padding(.bottom, Space.section)
        }
        .scrollClipDisabled()
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        SCCollectionArtworkResolver(
            artworkURL: playlist.largeArtworkURL,
            trackArtworkURLs: playlist.loadedTracks.compactMap(\.artworkURL)
        ) { image in
            SCMediaCard(
                title: playlist.title,
                subtitle: typeLine,
                artworkImage: image,
                artIdentity: playlist.id,
                artSubject: .collection,
                crownUser: playlist.user,
                crownContext: playlist.title,
                style: SCBrowseMetrics.tile
            )
        }
        .frame(width: SCBrowseMetrics.tileEdge)
    }

    private var typeLine: String {
        if playlist.isAlbum { return playlist.user.displayName }
        let count = playlist.totalTrackCount
        guard count > 0 else { return playlist.user.displayName }
        return "\(count) \(count == 1 ? "track" : "tracks")"
    }
}
