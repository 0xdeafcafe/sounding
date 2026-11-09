import SwiftUI

struct PlaylistFolderLink: View {
    let folder: PlaylistFolder
    var isTile = false

    @ScaledMetric(relativeTo: .body) private var rowArtwork: CGFloat = 56

    var body: some View {
        if isTile {
            NavigationLink(value: PlaylistFolderRoute(folderID: folder.id)) {
                PlaylistFolderTile(folder: folder, cornerRadius: SCContentStyle.phone.artworkCorner)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.artworkCorner, style: .continuous))
                    .hoverEffect(.lift)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { PlaylistFolderMenuActions(folder: folder) }
            .playlistFolderDragSource(.folder(folder.id))
            .playlistFolderDropTarget(folder.id, highlightCorner: SCContentStyle.phone.artworkCorner)
        } else {
            NavigationLink(value: PlaylistFolderRoute(folderID: folder.id)) {
                PlaylistFolderRow(folder: folder, artworkSize: min(rowArtwork, 72), cornerRadius: SCContentStyle.phone.artworkCorner)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in min(rowArtwork, 72) + 12 }
            }
            .libraryRowPreviewShape()
            .contextMenu { PlaylistFolderMenuActions(folder: folder) }
            .playlistFolderDragSource(.folder(folder.id))
            .playlistFolderDropTarget(folder.id)
        }
    }
}

struct PlaylistFolderDetailView: View {
    let folderID: String

    @ObservedObject private var store = PlaylistFolderStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarNavigator) private var navigator
    @Namespace private var namespace
    @State private var isCreatingPlaylist = false
    @State private var createdPlaylist: Playlist?
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 170

    private static let viewModePage = "library.playlistFolder"

    private var viewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: Self.viewModePage, default: .list) },
            set: { settings.setCollectionViewMode($0, for: Self.viewModePage) }
        )
    }

    private var folder: PlaylistFolder? { store.folder(folderID) }

    var body: some View {
        content
            .navigationTitle(folder?.name ?? "")
            .libraryPageTitleDisplayMode()
            .toolbar {
                if folder != nil {
                    ToolbarItem(placement: .topBarTrailing) { CollectionViewModeToggle(mode: viewMode) }
                    ToolbarItem(placement: .topBarTrailing) { addMenu }
                    if store.canEdit {
                        ToolbarItem(placement: .topBarTrailing) { moreMenu }
                    }
                }
            }
            .onChange(of: folder == nil) { _, isMissing in
                if isMissing { dismiss() }
            }
            .sheet(isPresented: $isCreatingPlaylist) {
                NewPlaylistSheet { playlist in
                    store.register(playlist)
                    withAnimation(.snappy) { store.movePlaylist(playlist.id, to: folderID) }
                    navigator?.insert(playlist)
                    createdPlaylist = playlist
                }
            }
            .navigationDestination(item: $createdPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, heroNamespace: namespace)
            }
            .task { store.reloadPlaylists() }
    }

    @ViewBuilder
    private var content: some View {
        let entries = store.entries(in: folderID)
        if folder == nil {
            ContentUnavailableView("Folder Not Found", systemImage: "folder")
        } else if entries.isEmpty, !store.hasLoadedPlaylists {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("No Playlists", systemImage: "folder")
            } description: {
                Text("Add playlists to this folder from their menu, or drag them here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .playlistFolderDropTarget(folderID, highlightCorner: 0)
        } else if viewMode.wrappedValue == .grid {
            grid(entries)
        } else {
            list(entries)
        }
    }

    private func list(_ entries: [PlaylistFolderEntry]) -> some View {
        List {
            ForEach(entries) { entry in
                switch entry {
                case .folder(let child):
                    PlaylistFolderLink(folder: child)
                case .playlist(let playlist):
                    PlaylistLink(playlist, heroNamespace: namespace, isListRow: true) {
                        PlaylistRow(playlist: playlist)
                    }
                    .matchedTransitionSource(id: playlist.id, in: namespace)
                    .libraryRowPreviewShape()
                    .contextMenu { PlaylistContextMenu(playlist: playlist) }
                    .collectionDragSource(playlist)
                    .playlistFolderDropTarget(folderID, before: .playlist(playlist.id))
                }
            }
        }
        .listStyle(.plain)
        .animation(.snappy, value: entries.map(\.id))
        .refreshable { store.reloadPlaylists() }
    }

    private func grid(_ entries: [PlaylistFolderEntry]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: max(240, tileMinimum * 1.4)), spacing: Space.base, alignment: .top)],
                alignment: .leading,
                spacing: Space.section
            ) {
                ForEach(entries) { entry in
                    switch entry {
                    case .folder(let child):
                        PlaylistFolderLink(folder: child, isTile: true)
                    case .playlist(let playlist):
                        PlaylistLink(playlist, heroNamespace: namespace) {
                            RecentlyAddedTile(playlist: playlist, heroNamespace: namespace)
                                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.artworkCorner, style: .continuous))
                                .hoverEffect(.lift)
                        }
                        .buttonStyle(.plain)
                        .libraryTilePreviewShape()
                        .contextMenu { PlaylistContextMenu(playlist: playlist) }
                        .collectionDragSource(playlist)
                        .playlistTrackDropTarget(playlist, cornerRadius: SCContentStyle.phone.artworkCorner)
                        .playlistFolderDropTarget(folderID, before: .playlist(playlist.id), highlightCorner: SCContentStyle.phone.artworkCorner)
                    }
                }
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.tight)
            .animation(.snappy, value: entries.map(\.id))
        }
        .refreshable { store.reloadPlaylists() }
    }

    private var addMenu: some View {
        Menu {
            Button {
                isCreatingPlaylist = true
            } label: {
                Label("New Playlist", systemImage: "music.note.list")
            }
            .disabled(credentials.isSignedOut)
            Button {
                PlaylistFolderPrompter.shared.newFolder(in: folderID)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!store.canEdit)
        } label: {
            Label("New", systemImage: "plus")
        }
    }

    private var moreMenu: some View {
        Menu {
            if let folder = store.folder(folderID) {
                SidebarPinButton(folder: folder)
            }
            if store.canEdit {
                Divider()
                Button {
                    PlaylistFolderPrompter.shared.rename(folderID)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    PlaylistFolderPrompter.shared.delete(folderID)
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}
