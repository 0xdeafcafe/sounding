import SwiftUI

struct PhoneLibraryCollectionsView: View {
    @ObservedObject var model: LibraryCollectionsModel
    var showsAccount = false

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isAddingFolder = false
    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 150

    private var viewModePage: String { "library.\(model.kind.rawValue)" }

    private var visibleItems: [LibraryGridItem] {
        LibraryCollectionsModel.matching(model.items, search: searchText)
    }

    private var isWide: Bool { horizontalSizeClass == .regular }

    private var viewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: viewModePage, default: .grid) },
            set: { mode in withAnimation(.smooth) { settings.setCollectionViewMode(mode, for: viewModePage) } }
        )
    }

    var body: some View {
        if model.kind == .artists {
            PhoneLibraryArtistsView(model: model, showsAccount: showsAccount)
        } else {
            grid
        }
    }

    private var grid: some View {
        LibraryCollectionStates(model: model, minimumTile: tileMinimum, addFolder: { isAddingFolder = true }) {
            let items = visibleItems
            Group {
                if items.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewMode.wrappedValue == .list {
                    List {
                        playButtons(items)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        ForEach(items) { item in
                            NavigationLink(value: item.route) {
                                LibraryCollectionListRow(item: item)
                            }
                            .contextMenu { menu(for: item) }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ScrollView {
                        VStack(alignment: isWide ? .leading : .center, spacing: Space.roomy) {
                            playButtons(items)
                            LibraryCollectionGrid(items: items, minimumTile: tileMinimum) { item in
                                menu(for: item)
                            }
                        }
                        .padding(.horizontal, Space.roomy)
                        .padding(.vertical, Space.tight)
                    }
                }
            }
            .refreshable { await model.load(force: true) }
            .prefetchArtwork(model.items.prefix(24).compactMap(\.artworkURL))
        }
        .navigationTitle(model.kind.title)
        .navigationSubtitle(model.subtitle ?? "")
        .libraryPageTitleDisplayMode()
        .libraryPageSearchable(text: $searchText, prompt: "Search \(model.kind.title)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionViewModeToggle(mode: viewMode)
            }
            if showsAccount {
                AccountToolbarItem()
            }
        }
        .task { await model.load() }
        .addMusicFolderImporter(isPresented: $isAddingFolder)
    }

    private func playButtons(_ items: [LibraryGridItem]) -> some View {
        LibraryCollectionPlayButtons(model: model, items: items, fills: !isWide) { tracks, shuffled in
            Task {
                if shuffled {
                    _ = await coordinator.play(shuffled: tracks)
                } else if let first = tracks.first {
                    _ = await coordinator.play(first, in: tracks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
    }

    @ViewBuilder
    private func menu(for item: LibraryGridItem) -> some View {
        switch item.route {
        case .playlist(let playlist):
            PlaylistContextMenu(playlist: playlist)
        case .local(let collection):
            Button {
                Task { _ = await coordinator.play(collection.tracks[0], in: collection.tracks) }
            } label: {
                Label("Play", systemImage: "play")
            }
            .disabled(collection.tracks.isEmpty)
            Button {
                Task { _ = await coordinator.play(shuffled: collection.tracks) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(collection.tracks.isEmpty)
        }
    }
}

struct PhoneLibraryArtistsView: View {
    @ObservedObject var model: LibraryCollectionsModel
    var showsAccount = false

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var identity = LibraryIdentity.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.artistRouter) private var artistRouter
    @Environment(\.presentArtist) private var presentArtist
    @StateObject private var confirmation = QueueConfirmationController()
    @State private var isAddingFolder = false
    @State private var searchText = ""
    @State private var selectedID: String?
    @AppStorage("library.artists.sort") private var sort = LibraryArtistSort.name

    private var artists: [LibraryArtist] {
        LibraryArtists.list(identity.index.artists, search: searchText, sort: sort)
    }

    var body: some View {
        states
            .navigationTitle(model.kind.title)
            .navigationSubtitle(subtitle)
            .libraryPageTitleDisplayMode()
            .libraryPageSearchable(text: $searchText, prompt: "Search Artists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryArtistSortMenu(sort: $sort)
                }
                if showsAccount {
                    AccountToolbarItem()
                }
            }
            .task { await model.load() }
            .addMusicFolderImporter(isPresented: $isAddingFolder)
            .queueConfirmationOverlay(confirmation)
    }

    private var subtitle: String {
        let count = identity.index.artists.count
        guard count > 0 else { return "" }
        return count == 1 ? "1 artist" : "\(count.formatted()) artists"
    }

    @ViewBuilder
    private var states: some View {
        if identity.index.artists.isEmpty {
            if !identity.isReady || model.isLoading {
                LoadingPlaceholder(.trackList(.phoneRoomy))
            } else {
                ContentUnavailableView {
                    Label(model.kind.emptyTitle, systemImage: model.kind.symbol)
                } description: {
                    Text(model.kind.emptyMessage)
                } actions: {
                    Button("Add Folder…") { isAddingFolder = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .regular {
            LibraryArtistsSplit(
                artists: artists,
                searchText: searchText,
                selectedID: $selectedID,
                play: playArtist
            ) { artist in
                overview(artist)
            }
        } else if artists.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            LibraryArtistList(artists: artists, play: playArtist) { artist in
                overview(artist)
                    .navigationTitle(artist.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func overview(_ artist: LibraryArtist) -> some View {
        LibraryArtistOverview(
            artist: artist,
            play: play,
            openProfile: openProfile,
            activity: activity
        ) { track, queue in
            Button("Play", systemImage: "play") { play(queue, start: track, shuffled: false) }
            Button("Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") {
                coordinator.addToQueue(track)
                confirmation.show("Added \u{201C}\(track.title)\u{201D} to Up Next")
            }
            if !track.isLocal {
                Button("Go to SoundCloud Artist", systemImage: "person.crop.circle") { openProfile(track.user) }
            }
        }
    }

    private func openProfile(_ user: User) {
        if let artistRouter {
            artistRouter.open(user)
        } else {
            presentArtist(user)
        }
    }

    private func activity(_ track: Track) -> SCTrackActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    private func playArtist(_ artist: LibraryArtist, shuffled: Bool) {
        let tracks = identity.index.releases(for: artist, setMinimumDuration: SettingsStore.shared.setMinimumDurationSeconds).playable
        play(tracks, start: tracks.first, shuffled: shuffled)
    }

    private func play(_ tracks: [Track], start: Track?, shuffled: Bool) {
        let tracks = identity.index.preferringLocalCopies(tracks)
        let start = start.map { identity.index.localCopy(of: $0) ?? $0 }
        Task {
            let message: String?
            if shuffled {
                message = await coordinator.play(shuffled: tracks)
            } else if let first = start ?? tracks.first {
                message = await coordinator.play(first, in: tracks)
            } else {
                message = nil
            }
            if let message {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }
}

struct LocalCollectionDetailView: View {
    let collection: LocalCollection

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var analysisStore = TrackAnalysisStore()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("local.collection.query") private var query = TrackCollectionQuery.collectionOrder
    @AppStorage(trackListColumns: "playlist") private var showsColumns: Bool
    @State private var searchText = ""
    @State private var heroProgress: Double = 0
    @State private var related = LocalCollectionRelated()
    @State private var opened: LocalCollection?
    @Environment(\.artistRouter) private var router
    @ObservedObject private var watchLink = PhoneWatchLinkServer.shared

    private var isAlbum: Bool { collection.kind == .album }

    private func open(_ other: LocalCollection) {
        if let router {
            router.path.append(LibraryCollectionRoute.local(other))
        } else {
            opened = other
        }
    }

    private var isWide: Bool {
        PadLayout.isPad && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortKeys: [TrackSortKey] {
        TrackCollection.availableSortKeys(for: collection.tracks, analysis: analysisStore.summaries)
    }

    private var visibleTracks: [Track] {
        TrackCollection.apply(
            collection.tracks,
            query: query,
            search: searchText,
            analysis: analysisStore.summaries,
            context: query.isFiltering ? TrackCollectionLoader.context() : TrackFilterContext()
        )
    }

    var body: some View {
        content
            .collectionPageScheme()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(collection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(collection.title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(heroProgress)
                        .accessibilityHidden(heroProgress < 1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TrackCollectionMenu(
                        query: $query,
                        showsColumns: $showsColumns,
                        sortKeys: sortKeys,
                        naturalOrderLabel: isAlbum ? "Album Order" : "Folder Order"
                    )
                }
                if isAlbum {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            LibraryAlbumLinkMenuItems(route: .local(collection))
                            if watchLink.isWatchPaired {
                                SendToWatchMenuToggle(selection: WatchSendSelection(local: collection))
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .libraryPageSearchable(text: $searchText, prompt: isAlbum ? "Search this album" : "Search this artist", alwaysShown: false)
            .task { await analysisStore.load(for: collection.tracks) }
            .onReceive(LocalMusicLibrary.shared.$tracksByFolder) { folders in
                related = LocalCollectionRelated(collection: collection, libraryTracks: folders.values.flatMap { $0 })
            }
            .navigationDestination(item: $opened) { other in
                LocalCollectionDetailView(collection: other)
            }
            .queueConfirmationOverlay(confirmation)
            .collectionPage(artworkURL: collection.artworkURL)
            .collectionAccent(from: collection.artworkURL)
    }

    private var content: some View {
        let visibleTracks = visibleTracks
        let numbered = isAlbum && query.sortKey == nil && !isSearching
        return List {
            hero
                .collectionHeroProgress($heroProgress)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !isAlbum, !isSearching, !related.albums.isEmpty {
                albumShelf(title: "Albums", items: related.albums)
                    .padding(.vertical, Spacing.md)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if showsColumns, horizontalSizeClass == .regular, !dynamicTypeSize.isAccessibilitySize {
                TrackColumnsHeader(query: $query, sortKeys: sortKeys, numbered: numbered)
                    .listRowBackground(Color.clear)
            }

            if visibleTracks.isEmpty {
                emptyTracks
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    TrackListRow(
                        track: track,
                        analysis: analysisStore.summaries[track.id],
                        context: { visibleTracks },
                        confirmation: confirmation,
                        number: numbered ? index + 1 : nil
                    )
                    .listRowBackground(Color.clear)
                }
            }

            if isAlbum, !isSearching {
                footer
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .environment(\.trackSortKey, query.sortKey)
        .trackListColumns(showsColumns)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .collectionFullBleedBackdrop(url: collection.artworkURL, identity: collection.id)
        .scrollEdgeEffectHidden(heroProgress < 1, for: .top)
        .tracksCollectionOverscroll()
        .animation(.smooth, value: showsColumns)
    }

    @ViewBuilder
    private var emptyTracks: some View {
        if isSearching {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label("No Matching Tracks", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(isAlbum ? "No tracks on this album match these filters." : "No tracks by this artist match these filters.")
            } actions: {
                Button("Clear Filters") { query.clearFilters() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var heroContent: CollectionHeroContent {
        CollectionHeroContent(
            id: collection.id,
            title: collection.title,
            subtitle: isAlbum ? collection.subtitle : nil,
            metadata: collection.metadataLine,
            artworkURL: collection.artworkURL
        )
    }

    private var openArtist: (() -> Void)? {
        guard isAlbum, let artist = related.artist else { return nil }
        return { open(artist) }
    }

    private var hero: some View {
        CollectionHero(content: heroContent, metrics: isWide ? .padFullBleed : .phoneFullBleed, onSubtitle: openArtist) {
            VStack(alignment: isWide ? .leading : .center, spacing: Spacing.sm) {
                LibraryAlbumCounterpartLink(route: .local(collection))
                CollectionHeroPlayButtons(
                    isEnabled: !collection.tracks.isEmpty,
                    fills: !isWide,
                    collectionID: collection.id,
                    revealsNowPlaying: true,
                    prewarm: { CollectionPlayback.prewarm(collection.tracks, immediate: $0) },
                    onPlay: play,
                    onShuffle: shuffle
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                CollectionReleaseFooter(info: CollectionReleaseInfo(local: collection))
                if let artist = related.artist {
                    Button {
                        open(artist)
                    } label: {
                        LocalArtistLabel(artist: artist, avatarSize: isWide ? 72 : 60)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xl)

            if !related.albums.isEmpty {
                albumShelf(title: "More by \(collection.subtitle)", items: related.albums)
                    .padding(.top, Spacing.lg)
            }
        }
        .padding(.bottom, Spacing.xl)
    }

    private func albumShelf(title: String, items: [LocalCollection]) -> some View {
        CollectionShelf(
            title: title,
            items: items,
            style: .phoneSectionHeader,
            tileWidth: isWide ? 180 : 150,
            spacing: Spacing.md,
            inset: Spacing.lg
        ) { album in
            Button {
                open(album)
            } label: {
                ArtworkShelfCard(
                    title: album.title,
                    subtitle: album.trackCountText,
                    artworkURL: album.artworkURL,
                    identity: album.id,
                    style: .phone
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Play", systemImage: "play") {
                    Task { await start(album.tracks, shuffled: false) }
                }
                Button("Shuffle", systemImage: "shuffle") {
                    Task { await start(album.tracks, shuffled: true) }
                }
            }
        }
    }

    private func play() {
        Task { await start(collection.tracks, shuffled: false) }
    }

    private func shuffle() {
        Task { await start(collection.tracks, shuffled: true) }
    }

    private func start(_ tracks: [Track], shuffled: Bool) async {
        guard let first = tracks.first else { return }
        let message: String?
        if shuffled {
            message = await coordinator.play(shuffled: tracks)
        } else {
            message = await coordinator.play(first, in: tracks)
        }
        if let message {
            confirmation.show(message, icon: "exclamationmark.triangle.fill")
        }
    }
}

private struct LibraryCollectionListRow: View {
    let item: LibraryGridItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                url: item.artworkURL,
                systemImage: item.isCircular ? "person.fill" : "square.stack",
                isCircle: item.isCircular,
                size: 56,
                cornerRadius: 6,
                identity: item.id
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct LocalArtistLabel: View {
    let artist: LocalCollection
    var avatarSize: CGFloat = 60

    var body: some View {
        HStack(spacing: 14) {
            LibraryArtistAvatar(
                artist: LibraryIdentity.shared.index.artist(forLocalKey: artist.id)
                    ?? LibraryArtist(id: "artist.\(artist.id)", name: artist.title, local: artist, user: nil, linkOrigin: nil),
                size: avatarSize
            )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(artist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows \(artist.title)")
    }
}

enum LibraryPageRoute: Hashable {
    case setlists
}

extension View {
    func appNavigationDestinations() -> some View {
        modifier(AppNavigationDestinations())
    }
}

private struct AppNavigationDestinations: ViewModifier {
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: LibraryCollectionRoute.self) { route in
                switch route {
                case .playlist(let playlist):
                    PlaylistDetailView(playlist: playlist, heroNamespace: namespace)
                case .local(let collection):
                    LocalCollectionDetailView(collection: collection)
                }
            }
            .navigationDestination(for: PlaylistPageRoute.self) { route in
                PlaylistDetailView(playlist: route.playlist, heroNamespace: route.zoom)
            }
            .navigationDestination(for: User.self) { ArtistDetailView(user: $0) }
            .navigationDestination(for: SearchCategory.self) { SearchCategoryView(category: $0) }
            .navigationDestination(for: PlaylistFolderRoute.self) { PlaylistFolderDetailView(folderID: $0.folderID) }
            .navigationDestination(for: LibraryPageRoute.self) { route in
                switch route {
                case .setlists: SavedSetlistsLibraryView()
                }
            }
    }
}
