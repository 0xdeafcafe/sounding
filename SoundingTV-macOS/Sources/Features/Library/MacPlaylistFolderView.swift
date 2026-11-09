import SwiftUI

struct MacPlaylistFolderListRow: View {
    let folder: PlaylistFolder

    var body: some View {
        NavigationLink(value: PlaylistFolderRoute(folderID: folder.id)) {
            PlaylistFolderRow(folder: folder, cornerRadius: SCContentStyle.mac.artworkCorner)
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight()
        .contextMenu { PlaylistFolderMenuActions(folder: folder) }
        .playlistFolderDragSource(.folder(folder.id))
        .playlistFolderDropTarget(folder.id, highlightCorner: 6)
    }
}

struct MacPlaylistFolderCardLink: View {
    let folder: PlaylistFolder

    var body: some View {
        NavigationLink(value: PlaylistFolderRoute(folderID: folder.id)) {
            PlaylistFolderCard(folder: folder, style: .mac)
        }
        .buttonStyle(.plain)
        .contextMenu { PlaylistFolderMenuActions(folder: folder) }
        .playlistFolderDragSource(.folder(folder.id))
        .playlistFolderDropTarget(folder.id, highlightCorner: SCContentStyle.mac.artworkCorner)
    }
}

struct MacPlaylistFolderView: View {
    let folderID: String

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var store = PlaylistFolderStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isCreatingPlaylist = false

    private static let viewModePage = "library.playlistFolder"
    private static let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    private var viewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: Self.viewModePage) },
            set: { settings.setCollectionViewMode($0, for: Self.viewModePage) }
        )
    }

    private var folder: PlaylistFolder? { store.folder(folderID) }

    var body: some View {
        let entries = store.entries(in: folderID)
        Group {
            if folder == nil {
                ContentUnavailableView("Folder Not Found", systemImage: "folder")
                    .macFillsPane()
            } else if entries.isEmpty, !store.hasLoadedPlaylists {
                ProgressView()
                    .macFillsPane()
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "folder")
                } description: {
                    Text("Add playlists to this folder from their menu, or drag them here.")
                }
                .macFillsPane()
                .contentShape(Rectangle())
                .playlistFolderDropTarget(folderID, highlightCorner: 0)
            } else {
                MacViewportScrollView {
                    Group {
                        if viewMode.wrappedValue == .list {
                            list(entries)
                        } else {
                            grid(entries)
                        }
                    }
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.top, SCContentStyle.mac.spaceBase)
                    .padding(.bottom, 32)
                    .animation(.snappy, value: entries.map(\.id))
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .background(Color.primary.opacity(0.001))
                .playlistFolderDropTarget(folderID, highlightCorner: 0)
            }
        }
        .navigationTitle(folder?.name ?? "")
        .toolbar {
            if folder != nil {
                ToolbarItem(id: "playlist-folder-view-mode", placement: .primaryAction) {
                    CollectionViewModeToggle(mode: viewMode)
                }
                ToolbarItem(id: "playlist-folder-new", placement: .primaryAction) { addMenu }
                if store.canEdit {
                    ToolbarItem(id: "playlist-folder-more", placement: .primaryAction) { moreMenu }
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
            }
        }
        .task { store.reloadPlaylists() }
    }

    private func list(_ entries: [PlaylistFolderEntry]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .folder(let child):
                    MacPlaylistFolderListRow(folder: child)
                case .playlist(let playlist):
                    NavigationLink(value: playlist) {
                        MacPlaylistListRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .macHoverRowHighlight()
                    .contextMenu { contextMenu(for: playlist) }
                    .collectionDragSource(playlist)
                    .playlistTrackDropTarget(playlist, cornerRadius: 6)
                    .playlistFolderDropTarget(folderID, before: .playlist(playlist.id), highlightCorner: 6)
                }
                Divider().padding(.leading, 68)
            }
        }
    }

    private func grid(_ entries: [PlaylistFolderEntry]) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
            ForEach(entries) { entry in
                switch entry {
                case .folder(let child):
                    MacPlaylistFolderCardLink(folder: child)
                case .playlist(let playlist):
                    NavigationLink(value: playlist) {
                        MacPlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                        contextMenu(for: playlist)
                    }
                    .collectionDragSource(playlist)
                    .playlistTrackDropTarget(playlist, cornerRadius: SCContentStyle.mac.artworkCorner)
                    .playlistFolderDropTarget(folderID, before: .playlist(playlist.id), highlightCorner: SCContentStyle.mac.artworkCorner)
                }
            }
        }
    }

    private func contextMenu(for playlist: Playlist) -> some View {
        MacPlaylistContextMenu(playlist: playlist)
    }

    private var addMenu: some View {
        Menu {
            Button("New Playlist\u{2026}") { isCreatingPlaylist = true }
                .disabled(credentials.isSignedOut)
            Button("New Folder\u{2026}") { PlaylistFolderPrompter.shared.newFolder(in: folderID) }
                .disabled(!store.canEdit)
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("New Playlist or Folder")
    }

    private var moreMenu: some View {
        Menu {
            if let folder = store.folder(folderID) {
                SidebarPinButton(folder: folder)
            }
            if store.canEdit {
                Divider()
                Button("Rename\u{2026}") { PlaylistFolderPrompter.shared.rename(folderID) }
                Button("Delete Folder\u{2026}", role: .destructive) { PlaylistFolderPrompter.shared.delete(folderID) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .help("More")
    }
}
