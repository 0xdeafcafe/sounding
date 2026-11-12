import SwiftUI

struct PlaylistDetailView: View {
    let heroNamespace: Namespace.ID
    @StateObject private var viewModel: PlaylistDetailViewModel
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var analysisStore = TrackAnalysisStore()
    @StateObject private var related = CollectionRelatedModel()
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.artistRouter) private var artistRouter
    @Environment(\.downloadPrompter) private var prompter

    @State private var searchText = ""
    @AppStorage("playlist.query", store: .sounding) private var query = TrackCollectionQuery.collectionOrder
    @AppStorage(trackListColumns: "playlist") private var showsColumns: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingCollectionPolicy = false
    @State private var heroProgress: Double = 0
    @Namespace private var shelfNamespace

    init(playlist: Playlist, heroNamespace: Namespace.ID) {
        self.heroNamespace = heroNamespace
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    var body: some View {
        content
        .collectionPageScheme()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(viewModel.playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewModel.playlist.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(heroProgress)
                    .accessibilityHidden(heroProgress < 1)
            }
            if !viewModel.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    CollectionDownloadButton(
                        collectionId: viewModel.playlist.id,
                        playlist: viewModel.playlist,
                        tracks: { viewModel.tracks }
                    )
                }
            }
            if !viewModel.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    TrackCollectionMenu(
                        query: $query,
                        showsColumns: $showsColumns,
                        sortKeys: TrackCollection.availableSortKeys(for: viewModel.tracks, analysis: analysisStore.summaries),
                        naturalOrderLabel: "Playlist Order"
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SendToWatchMenuToggle(selection: WatchSendSelection(playlist: viewModel.playlist)) {
                        downloadForWatch()
                    }
                    Button("Collection Settings", systemImage: "slider.horizontal.3") {
                        isShowingCollectionPolicy = true
                    }
                    if viewModel.playlist.isAlbum {
                        LibraryAlbumLinkMenuItems(route: .playlist(viewModel.playlist))
                    }
                    SidebarPinButton(playlist: viewModel.playlist)
                    PlaylistManagementMenuItems(playlist: viewModel.playlist, tracks: viewModel.tracks)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .libraryPageSearchable(text: $searchText, prompt: "Search this playlist", alwaysShown: false)
        .task(id: searchText) { await loadMoreWhileSearchIsEmpty() }
        .task { await viewModel.loadIfNeeded() }
        .task(id: viewModel.tracks.map(\.id)) {
            await analysisStore.load(for: viewModel.tracks)
            DownloadManager.shared.applyCollectionPolicy(
                tracks: viewModel.tracks,
                collectionId: viewModel.playlist.id
            )
        }
        .queueConfirmationOverlay(confirmation)
        .phonePlaylistEditing(viewModel)
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: viewModel.playlist.id,
                collectionName: viewModel.playlist.title,
                collectionKind: CollectionKind.classify(playlist: viewModel.playlist),
                tracks: viewModel.tracks,
                applier: DownloadManager.shared
            )
        }
        .collectionPage(artworkURL: viewModel.playlist.largeDisplayArtworkURL)
        .collectionAccent(from: viewModel.playlist.largeDisplayArtworkURL)
        .modifier(ZoomTransitionIfMotionAllowed(
            reduceMotion: reduceMotion, sourceID: viewModel.playlist.id, namespace: heroNamespace
        ))
    }

    private func downloadForWatch() {
        guard !DownloadManager.shared.isCollectionDownloaded(viewModel.playlist.id) else { return }
        let descriptor = DownloadCollectionDescriptor(playlist: viewModel.playlist)
        let tracks = viewModel.tracks
        prompter.request { confirmed in
            await DownloadManager.shared.download(collection: descriptor, tracks: tracks, confirmed: confirmed)
        }
    }

    private var visibleTracks: [Track] {
        TrackCollection.apply(
            viewModel.tracks,
            query: query,
            search: searchText,
            analysis: analysisStore.summaries,
            context: query.isFiltering ? TrackCollectionLoader.context() : TrackFilterContext()
        )
    }

    private var isSearchIncomplete: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.tracks.count < viewModel.playlist.trackCount
    }

    private func loadMoreWhileSearchIsEmpty() async {
        guard isSearchIncomplete else { return }
        try? await Task.sleep(for: .milliseconds(500))
        var pages = 0
        while !Task.isCancelled, pages < 10, visibleTracks.isEmpty, isSearchIncomplete, !viewModel.tracks.isEmpty,
              viewModel.pager.hasMore, !viewModel.pager.didFailLoadingMore, !viewModel.pager.isPaused {
            if viewModel.isLoadingMore {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            pages += 1
            let before = viewModel.tracks.count
            await viewModel.loadMore()
            if viewModel.tracks.count == before { return }
        }
    }

    private var showsColumnHeader: Bool {
        showsColumns && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var isWide: Bool {
        PadLayout.isPad && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var heroContent: CollectionHeroContent {
        CollectionHeroContent(playlist: viewModel.playlist, loadedTrackCount: viewModel.tracks.count)
    }

    private var openArtist: (() -> Void)? {
        guard let artistRouter else { return nil }
        let user = viewModel.playlist.user
        return { artistRouter.open(user) }
    }

    private var heroMetrics: CollectionHeroMetrics { isWide ? .padFullBleed : .phoneFullBleed }

    private var hero: some View {
        CollectionHero(content: heroContent, metrics: heroMetrics, onSubtitle: openArtist) {
            VStack(alignment: isWide ? .leading : .center, spacing: Spacing.sm) {
                LibraryAlbumCounterpartLink(route: .playlist(viewModel.playlist))
                CollectionHeroPlayButtons(
                    isEnabled: !viewModel.tracks.isEmpty,
                    fills: !isWide,
                    collectionID: viewModel.playlist.id,
                    revealsNowPlaying: true,
                    prewarm: { CollectionPlayback.prewarm(viewModel.tracks, immediate: $0) },
                    onPlay: play,
                    onShuffle: shufflePlay
                )
            }
        }
    }

    private var rowInsets: EdgeInsets? {
        guard !showsColumnHeader || dynamicTypeSize.isAccessibilitySize else { return nil }
        let inset = heroMetrics.horizontalInset
        return EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: max(inset - 12, 8))
    }

    private var isAlbum: Bool { CollectionPageKind(playlist: viewModel.playlist) == .album }

    private var showsNumbers: Bool {
        isAlbum && query.sortKey == nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shelfTileWidth: CGFloat { isWide ? 180 : 150 }

    private var relatedShelves: some View {
        Group {
            collectionFooter

            if !related.moreByArtist.isEmpty {
                CollectionShelf(
                    title: CollectionRelatedModel.moreTitle(for: related.artist ?? viewModel.playlist.user),
                    items: related.moreByArtist,
                    style: .phoneSectionHeader,
                    tileWidth: shelfTileWidth,
                    spacing: Spacing.md,
                    inset: Spacing.lg
                ) { playlist in
                    PlaylistLink(playlist, heroNamespace: shelfNamespace) {
                        ArtworkShelfCard(playlist: playlist, style: .phone)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: playlist.id, in: shelfNamespace)
                    .contextMenu { PlaylistContextMenu(playlist: playlist) }
                }
                .padding(.top, Spacing.lg)
            }

            if !related.similar.isEmpty {
                CollectionShelf(
                    title: "You Might Also Like",
                    items: related.similar,
                    style: .phoneSectionHeader,
                    tileWidth: shelfTileWidth,
                    spacing: Spacing.md,
                    inset: Spacing.lg
                ) { track in
                    Button {
                        playRelated(track)
                    } label: {
                        ArtworkShelfCard(track: track, style: .phone)
                    }
                    .buttonStyle(.plain)
                    .disabled(track.streamURL == nil)
                    .trackDragSource(track)
                }
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            } else if !related.hasFinished(.similar) {
                CollectionRelatedTrigger { loadRelated(.similar) }
            }
        }
    }

    private var collectionFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            CollectionReleaseFooter(info: CollectionReleaseInfo(playlist: viewModel.playlist, tracks: viewModel.tracks))
            let artist = related.artist ?? viewModel.playlist.user
            SoundCloudUploaderRow(user: artist, avatarSize: isWide ? 72 : 60, postsMusic: viewModel.playlist.isAlbum, open: artistRouter.map { router in { router.open(artist) } })
            CollectionEngagementSection(playlist: viewModel.playlist, openUser: { artistRouter?.open($0) })
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xl)
        .onAppear {
            loadRelated(.artist)
            loadRelated(.moreByArtist)
        }
    }

    private func loadRelated(_ part: CollectionRelatedModel.Part) {
        let playlist = viewModel.playlist
        let tracks = viewModel.tracks
        Task { await related.load(part, for: playlist, tracks: tracks) }
    }

    private func playRelated(_ track: Track) {
        let playable = related.similar.filter { $0.streamURL != nil }
        Task {
            if let message = await coordinator.play(track, in: playable) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let visibleTracks = visibleTracks
        if viewModel.isLoading, viewModel.tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                LoadingPlaceholder(.trackList(.phoneRoomy))
            }
        } else if let error = viewModel.errorMessage, viewModel.tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                SCEmptyState(
                    kind: .error, title: "Couldn't Load", message: error,
                    actionTitle: "Try Again",
                    action: { Task { await viewModel.load() } },
                    style: .phone
                )
            }
        } else if viewModel.tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                AddTracksEmptyState(playlist: viewModel.playlist) {
                    Task { await viewModel.load() }
                }
            }
        } else if visibleTracks.isEmpty, isSearchIncomplete, viewModel.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleTracks.isEmpty, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.isFiltering {
            ContentUnavailableView {
                Label("No Matching Tracks", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No tracks in this playlist match these filters.")
            } actions: {
                Button("Clear Filters") { query.clearFilters() }
                    .buttonStyle(.bordered)
            }
        } else if visibleTracks.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            let numbered = showsNumbers
            List {
                hero
                    .collectionHeroProgress($heroProgress)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if showsColumnHeader {
                    TrackColumnsHeader(
                        query: $query,
                        sortKeys: TrackCollection.availableSortKeys(for: viewModel.tracks, analysis: analysisStore.summaries),
                        numbered: numbered
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    TrackListRow(
                        track: track,
                        analysis: analysisStore.summaries[track.id],
                        context: { visibleTracks },
                        collectionId: viewModel.playlist.id,
                        confirmation: confirmation,
                        number: numbered ? index + 1 : nil
                    )
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              viewModel.tracks.isNearEnd(track, lead: 10) else { return }
                        viewModel.requestMore()
                    }
                }
                UnanalysedTracksFooter(tracks: visibleTracks, sortKey: query.sortKey, summaries: analysisStore.summaries)
                    .listRowBackground(Color.clear)
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PagedFooter(pager: viewModel.pager)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if !viewModel.pager.hasMore {
                        relatedShelves
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .environment(\.trackSortKey, query.sortKey)
            .trackListColumns(showsColumns)
            .environment(\.showsTrackPlayCounts, true)
            .playlistTrackDropTarget(viewModel.playlist, cornerRadius: 0) {
                Task { await viewModel.load() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .collectionFullBleedBackdrop(url: heroContent.artworkURL, identity: viewModel.playlist.id)
            .scrollEdgeEffectHidden(heroProgress < 1, for: .top)
            .tracksCollectionOverscroll()
            .animation(.smooth, value: showsColumns)
            .refreshable { await viewModel.load() }
        }
    }

    private func play() {
        guard !viewModel.tracks.isEmpty else { return }
        let playlist = viewModel.playlist
        let loaded = viewModel.tracks
        Task {
            await CollectionPlayback.start(playlist: playlist, loaded: loaded) { first, queue in
                _ = await coordinator.play(first, in: queue, collectionId: playlist.id)
            }
        }
    }

    private func shufflePlay() {
        guard !viewModel.tracks.isEmpty else { return }
        Task { await coordinator.play(shuffled: viewModel.tracks, collectionId: viewModel.playlist.id) }
    }
}

private struct ZoomTransitionIfMotionAllowed: ViewModifier {
    let reduceMotion: Bool
    let sourceID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}
