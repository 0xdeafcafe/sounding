import SwiftUI
import AppKit
import Combine

enum MacPlaylistScope: Hashable {
    case all
    case mine
    case liked

    var title: String {
        switch self {
        case .all: "All Playlists"
        case .mine: "My Playlists"
        case .liked: "Liked Playlists"
        }
    }
}

struct MacPlaylistsView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacPlaylistsModel
    @ObservedObject private var findFocus = MacFindFocus.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var folders = PlaylistFolderStore.shared
    let scope: MacPlaylistScope
    @State private var isSearchPresented = false

    private static let viewModePage = "library.playlists"

    private var viewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: Self.viewModePage) },
            set: { settings.setCollectionViewMode($0, for: Self.viewModePage) }
        )
    }

    init(model: MacPlaylistsModel, scope: MacPlaylistScope = .all) {
        self.model = model
        self.scope = scope
    }

    var body: some View {
        MacViewportScrollView {
            content
                .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                .padding(.top, SCContentStyle.mac.spaceBase)
                .padding(.bottom, 32)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .background(Color.primary.opacity(0.001))
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(id: "playlist-new", placement: .primaryAction) {
                Menu {
                    Button("New Playlist\u{2026}") {
                        MacRootSelection.shared.requestNewPlaylist()
                    }
                    Button("New Playlist Folder\u{2026}") {
                        PlaylistFolderPrompter.shared.newFolder()
                    }
                    .disabled(!folders.canEdit)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New Playlist or Folder")
                .disabled(credentials.isSignedOut)
            }
            ToolbarItem(id: "playlist-kind-filter", placement: .primaryAction) {
                kindFilter
            }
            ToolbarItem(id: "playlist-view-mode", placement: .primaryAction) {
                CollectionViewModeToggle(mode: viewMode)
            }
        }
        .searchable(
            text: $model.searchText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Find in \(scope.title)"
        )
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .task {
            if model.liked.isEmpty, model.mine.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
    }

    private var kindFilter: some View {
        Menu {
            Button {
                model.kindFilter = nil
            } label: {
                Label("All Collections", systemImage: model.kindFilter == nil ? "checkmark" : "square.stack.3d.up")
            }
            Button {
                model.kindFilter = .playlist
            } label: {
                Label("Playlists", systemImage: model.kindFilter == .playlist ? "checkmark" : "music.note.list")
            }
            Button {
                model.kindFilter = .album
            } label: {
                Label("Albums", systemImage: model.kindFilter == .album ? "checkmark" : "square.stack")
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.kindFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help(model.kindFilter.map { "Showing \($0.noun)s only" } ?? "Filter by kind")
        .accessibilityLabel("Collection filter: \(filterLabel)")
    }

    private var filterLabel: String {
        switch model.kindFilter {
        case .playlist: "Playlists"
        case .album: "Albums"
        case nil: "All"
        }
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut {
            MacSignedOutEmptyState(
                title: "Playlists Need an Account",
                message: "Sign in to see the playlists you've made and liked. Search works without an account.",
                browsableRoute: .search
            )
            .macFillsPane()
        } else if model.isLoading, model.liked.isEmpty, model.mine.isEmpty {
            LoadingPlaceholder(.grid(minimumTile: 150), showsSyncStatus: true)
        } else if let error = model.errorMessage, model.liked.isEmpty, model.mine.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
                }
            }
            .macFillsPane()
        } else if scopedLiked.isEmpty, scopedMine.isEmpty, !showsLikes, visibleFolders.isEmpty, !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .macFillsPane()
        } else if scopedLiked.isEmpty, scopedMine.isEmpty, !showsLikes, visibleFolders.isEmpty {
            ContentUnavailableView(
                "No Playlists",
                systemImage: "music.note.list",
                description: Text("Playlists you make or like on SoundCloud show up here.")
            )
            .macFillsPane()
        } else {
            LazyVStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                if scopedMine.isEmpty, scopedLiked.isEmpty {
                    if viewMode.wrappedValue == .list {
                        likesRow
                    } else {
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
                            likesCard
                        }
                    }
                }
                if !visibleFolders.isEmpty {
                    folderSection
                }
                if !scopedMine.isEmpty {
                    section(title: scope == .all ? "My Playlists" : nil, playlists: scopedMine, source: .mine, pinsLikes: showsLikes)
                }
                if !scopedLiked.isEmpty {
                    section(title: scope == .all ? "Liked Playlists" : nil, playlists: scopedLiked, source: .liked, pinsLikes: showsLikes && scopedMine.isEmpty)
                }
            }
        }
    }

    private var scopedMine: [Playlist] {
        scope == .liked ? [] : unfoldered(model.filteredMine)
    }

    private var scopedLiked: [Playlist] {
        scope == .mine ? [] : unfoldered(model.filteredLiked)
    }

    private var showsFolders: Bool {
        scope == .all && model.kindFilter != .album
    }

    private var visibleFolders: [PlaylistFolder] {
        guard showsFolders else { return [] }
        return folders.matchingFolders(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func unfoldered(_ playlists: [Playlist]) -> [Playlist] {
        guard showsFolders, model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return playlists }
        return playlists.filter { !folders.isFoldered($0.id) }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader(title: "Folders", style: .mac)
            if viewMode.wrappedValue == .list {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleFolders) { folder in
                        MacPlaylistFolderListRow(folder: folder)
                        Divider().padding(.leading, 68)
                    }
                }
            } else {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
                    ForEach(visibleFolders) { folder in
                        MacPlaylistFolderCardLink(folder: folder)
                    }
                }
            }
        }
        .animation(.snappy, value: visibleFolders.map(\.id))
    }

    private static let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    private var showsLikes: Bool {
        scope != .mine && model.kindFilter != .album && LikesPlaylist.matches(search: model.searchText)
    }

    private var likesCard: some View {
        NavigationLink(value: LikesPlaylistRoute()) {
            LikesPlaylistCard(style: .mac)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playlists.likes")
    }

    private var likesRow: some View {
        NavigationLink(value: LikesPlaylistRoute()) {
            MacLikesPlaylistRow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playlists.likes")
    }

    private func listRows(_ playlists: [Playlist], source: MacPlaylistScope, pinsLikes: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if pinsLikes {
                likesRow
                Divider().padding(.leading, 68)
            }
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    MacPlaylistListRow(playlist: playlist)
                }
                .buttonStyle(.plain)
                .macHoverRowHighlight()
                .contextMenu {
                    MacPlaylistContextMenu(
                        playlist: playlist,
                        canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                        isUpdatingPrivacy: model.updatingPlaylistIDs.contains(playlist.id),
                        onTogglePrivacy: { model.togglePrivacy(playlist) }
                    )
                }
                .collectionDragSource(playlist)
                .playlistTrackDropTarget(playlist, cornerRadius: 6)
                .onAppear {
                    (source == .liked ? model.likedPager : model.minePager).loadMoreIfNeeded(after: playlist, lead: 12)
                }
                Divider().padding(.leading, 68)
            }
        }
    }

    private func section(title: String?, playlists: [Playlist], source: MacPlaylistScope, pinsLikes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                SCSectionHeader(title: title, style: .mac)
            }

            if viewMode.wrappedValue == .list {
                listRows(playlists, source: source, pinsLikes: pinsLikes)
            } else {
                grid(playlists, source: source, pinsLikes: pinsLikes)
            }

            MacPagedFooter(pager: source == .liked ? model.likedPager : model.minePager)
        }
    }

    private func grid(_ playlists: [Playlist], source: MacPlaylistScope, pinsLikes: Bool) -> some View {
        Group {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
                if pinsLikes {
                    likesCard
                }
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        MacPlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                        MacPlaylistContextMenu(
                            playlist: playlist,
                            canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                            isUpdatingPrivacy: model.updatingPlaylistIDs.contains(playlist.id),
                            onTogglePrivacy: { model.togglePrivacy(playlist) }
                        )
                    }
                    .collectionDragSource(playlist)
                    .playlistTrackDropTarget(playlist, cornerRadius: SCContentStyle.mac.artworkCorner)
                    .onAppear {
                        (source == .liked ? model.likedPager : model.minePager).loadMoreIfNeeded(after: playlist, lead: 12)
                    }
                }
            }
        }
    }
}

struct MacPlaylistListRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            SCCollectionArtworkResolver(
                artworkURL: playlist.displayArtworkURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL)
            ) { image in
                SCArtwork(image: image, identity: playlist.id, style: .mac, subject: .collection)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(LikesPlaylist.subtitle(trackCount: playlist.trackCount)) · \(playlist.user.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MacLikesPlaylistRow: View {
    @ObservedObject private var count = LikesPlaylistCount.shared

    var body: some View {
        HStack(spacing: 12) {
            LikesPlaylistArtwork(cornerRadius: SCContentStyle.mac.artworkCorner)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(LikesPlaylist.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle = count.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task { await count.refresh() }
    }
}

struct MacPagedFooter<Item: Identifiable>: View {
    @ObservedObject var pager: Paginator<Item>
    var isInLazyContainer = false

    var body: some View {
        if isInLazyContainer {
            PagedFooter(pager: pager)
        } else {
            LazyVStack(spacing: 0) {
                PagedFooter(pager: pager)
            }
        }
    }
}

struct MacPlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        SCCollectionArtworkResolver(
            artworkURL: playlist.displayArtworkURL,
            trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL)
        ) { image in
            SCMediaCard(
                title: playlist.title,
                subtitle: playlist.user.displayName,
                artworkImage: image,
                artIdentity: playlist.id,
                artSubject: .collection,
                crownUser: playlist.user,
                crownContext: playlist.title,
                style: .mac,
                isPrivate: playlist.isPrivate
            )
        }
    }
}

struct MacPlaylistContextMenu: View {
    let playlist: Playlist
    var canChangePrivacy = false
    var isUpdatingPrivacy = false
    var onTogglePrivacy: (() -> Void)?

    var body: some View {
        Button {
            Task { await MacPlayback.play(playlist: playlist) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            MacRootSelection.shared.request(playlist: playlist)
        } label: {
            Label(playlist.isAlbum ? "Go to Album" : "Go to Playlist", systemImage: "arrow.right.circle")
        }

        PlaylistFolderMenuItems(playlist: playlist)
        SidebarPinButton(playlist: playlist)

        Button {
            let playlist = playlist
            Task {
                var tracks = playlist.tracks ?? []
                if tracks.count < playlist.trackCount, let full = try? await SoundCloudAPI.shared.getPlaylist(id: playlist.id) {
                    tracks = full.tracks ?? tracks
                }
                MacRootSelection.shared.request(usbExport: .playlist(playlist, tracks: tracks))
            }
        } label: {
            Label("Export to USB…", systemImage: "externaldrive.badge.plus")
        }

        Divider()

        Button {
            NSWorkspace.shared.open(playlist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            macCopySoundCloudLink(playlist.permalinkURL)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: playlist.permalinkURL, subject: Text(playlist.title), preview: SharePreview(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if canChangePrivacy, let onTogglePrivacy {
            Divider()
            Button(action: onTogglePrivacy) {
                Label(
                    playlist.sharing == "private" ? "Make Public" : "Make Private",
                    systemImage: playlist.sharing == "private" ? "globe" : "lock"
                )
            }
            .disabled(isUpdatingPrivacy)
        }

        PlaylistManagementMenuItems(playlist: playlist, includesPrivacy: !(canChangePrivacy && onTogglePrivacy != nil))
    }
}

struct MacArtistContextMenu: View {
    let artist: User

    var body: some View {
        Button {
            Task { await MacPlayback.play(user: artist) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        StartStationMenuButton(artist: artist)

        ScoutToggleButton(user: artist)

        Button {
            MacRootSelection.shared.request(artist: artist)
        } label: {
            Label("Go to \(artist.kindLabel)", systemImage: "person.crop.circle")
        }

        Divider()

        Button {
            MacMessageComposer.shared.present(user: artist)
        } label: {
            Label("Message", systemImage: "envelope")
        }

        Button {
            NSWorkspace.shared.open(artist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            macCopySoundCloudLink(artist.permalinkURL)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: artist.permalinkURL, subject: Text(artist.displayName), preview: SharePreview(artist.displayName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

private func macCopySoundCloudLink(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

enum MacCoverArt {
    static func load(
        _ candidates: [URL],
        variant: ArtworkVariant = .standard
    ) async -> NSImage? {
        for url in candidates.prefix(4) {
            if let image = await ArtworkCache.shared.image(for: url, variant: variant) {
                return image
            }
        }
        return nil
    }
}

enum MacPlaylistKind: Equatable {
    case playlist
    case album

    var noun: String { self == .playlist ? "Playlist" : "Album" }
}

@MainActor
final class MacPlaylistsModel: ObservableObject {
    @Published private(set) var isHydrating = false
    @Published private(set) var actionErrorMessage: String?
    @Published var searchText = ""
    @Published var kindFilter: MacPlaylistKind?
    @Published private(set) var updatingPlaylistIDs: Set<String> = []
    @Published private var overrides: [String: Playlist] = [:]

    let likedPager: Paginator<Playlist>
    let minePager: Paginator<Playlist>

    private var loadTask: Task<Void, Never>?
    private var currentUserId: String?
    private var observations: [AnyCancellable] = []
    private let cache = LibraryCache.shared
    private static let pageSize = 50
    private static let likedSection = "LikedPlaylists"
    private static let ownedSection = "OwnedPlaylists"

    init() {
        likedPager = Paginator(source: LibraryDB.playlistSource(.likedPlaylists, pageSize: Self.pageSize), maxUnattendedPages: 1_000)
        minePager = Paginator(source: LibraryDB.playlistSource(.ownPlaylists, pageSize: Self.pageSize), maxUnattendedPages: 1_000)
        observations = [
            likedPager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            minePager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            LibrarySyncEngine.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            LibrarySyncEngine.shared.$revision.dropFirst().sink { [weak self] _ in
                let changed = LibrarySyncEngine.shared.lastChanged
                guard changed.contains(.likedPlaylists) || changed.contains(.ownPlaylists) else { return }
                Task {
                    await self?.likedPager.reload()
                    await self?.minePager.reload()
                }
            }
        ]
    }

    private static let nextSource: @MainActor (PagedCursor) async throws -> PagedChunk<Playlist> = { cursor in
        guard case .url(let url) = cursor else { return PagedChunk(items: []) }
        let page = try await SoundCloudAPI.shared.getPage(Playlist.self, from: url)
        return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
    }

    private static func chunk(_ page: Page<Playlist>, keeping cached: [Playlist]) -> PagedChunk<Playlist> {
        let known = Set(page.collection.map(\.id))
        return PagedChunk(
            items: page.collection + cached.filter { !known.contains($0.id) },
            next: page.nextHref.map(PagedCursor.url)
        )
    }

    var liked: [Playlist] { likedPager.items.map { overrides[$0.id] ?? $0 } }
    var mine: [Playlist] { minePager.items.map { overrides[$0.id] ?? $0 } }

    var isLoading: Bool {
        isHydrating || likedPager.isLoadingFirst || minePager.isLoadingFirst || likedPager.isPaused || minePager.isPaused
            || (likedPager.items.isEmpty && minePager.items.isEmpty && LibrarySyncEngine.shared.isAwaitingFirstSync(.ownPlaylists))
    }

    var errorMessage: String? {
        if let actionErrorMessage { return actionErrorMessage }
        return (likedPager.firstError ?? minePager.firstError)?.macUserFacingMessage
    }

    var filteredLiked: [Playlist] { filter(liked) }
    var filteredMine: [Playlist] { filter(mine) }

    private func filter(_ playlists: [Playlist]) -> [Playlist] {
        var result = playlists
        if let kindFilter {
            result = result.filter { ($0.isAlbum ? MacPlaylistKind.album : .playlist) == kindFilter }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        return result.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    func load(currentUserId: String?, isSignedOut: Bool) {
        loadTask?.cancel()
        self.currentUserId = currentUserId
        actionErrorMessage = nil
        guard !isSignedOut else {
            likedPager.reset()
            minePager.reset()
            overrides = [:]
            return
        }
        LibrarySyncEngine.shared.prioritise([.ownPlaylists, .likedPlaylists])
        loadTask = Task {
            await likedPager.reload()
            guard !Task.isCancelled else { return }
            await minePager.reload()
        }
    }

    func togglePrivacy(_ playlist: Playlist) {
        guard !updatingPlaylistIDs.contains(playlist.id) else { return }
        updatingPlaylistIDs.insert(playlist.id)
        Task {
            defer { updatingPlaylistIDs.remove(playlist.id) }
            do {
                let updated = try await SoundCloudAPI.shared.setPlaylistSharing(
                    playlist.sharing == "private" ? "public" : "private",
                    playlistId: playlist.id
                )
                overrides[updated.id] = updated
                actionErrorMessage = nil
            } catch {
                actionErrorMessage = error.macUserFacingMessage
            }
        }
    }

    private func cachedPlaylists(in section: String) async -> [Playlist] {
        let rows = cache.loadSection(section, limit: Self.pageSize)
        let decoder = LikesSyncEngine.makeDecoder()
        return rows.compactMap { try? decoder.decode(Playlist.self, from: $0.payload) }
    }

    private func persist(_ values: [Playlist], in section: String) {
        let encoder = LikesSyncEngine.makeEncoder()
        let rows = values.compactMap { playlist -> LibraryCache.WriteRow? in
            guard let payload = try? encoder.encode(playlist) else { return nil }
            return LibraryCache.WriteRow(id: playlist.id, payload: payload)
        }
        let cache = cache
        Task { await cache.mergeSection(section, rows: rows) }
    }
}
