import SwiftUI
import Combine

struct MacLibraryCollectionsPane: View {
    @ObservedObject var model: LibraryCollectionsModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var findFocus = MacFindFocus.shared
    @State private var isAddingFolder = false
    @State private var isSearchPresented = false
    @State private var searchText = ""

    private var viewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: "library.\(model.kind.rawValue)") },
            set: { settings.setCollectionViewMode($0, for: "library.\(model.kind.rawValue)") }
        )
    }

    var body: some View {
        if model.kind == .artists {
            MacLibraryArtistsPane(model: model)
        } else {
            grid
        }
    }

    private var grid: some View {
        LibraryCollectionStates(model: model, minimumTile: 168, addFolder: { isAddingFolder = true }) {
            let items = LibraryCollectionsModel.matching(model.items, search: searchText)
            if items.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .macFillsPane()
            } else {
                MacViewportScrollView {
                    VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceBase) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.kind.title)
                                    .font(.largeTitle.weight(.bold))
                                if let subtitle = model.subtitle {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(MacSecondaryStyle())
                                }
                            }
                            LibraryCollectionPlayButtons(model: model, items: items, fills: false, isCompact: true) { tracks, shuffled in
                                Task {
                                    if shuffled {
                                        await MacPlayback.shuffle(tracks)
                                    } else if let first = tracks.first {
                                        await MacPlayback.play(first, in: tracks)
                                    }
                                }
                            }
                        }
                        .macFadesUnderToolbar()

                        if viewMode.wrappedValue == .list {
                            list(items)
                        } else {
                            LibraryCollectionGrid(
                                items: items,
                                minimumTile: 168,
                                play: { item in Task { await play(item) } }
                            ) { item in
                                menu(for: item)
                            }
                        }
                    }
                    .padding(SCContentStyle.mac.spaceGutter)
                }
            }
        }
        .macFillsPane()
        .navigationTitle(model.kind.title)
        .toolbar {
            ToolbarItem(id: "library-collection-view-mode", placement: .primaryAction) {
                CollectionViewModeToggle(mode: viewMode)
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Find in \(model.kind.title)"
        )
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .task { await model.load() }
        .addMusicFolderImporter(isPresented: $isAddingFolder)
    }

    private func list(_ items: [LibraryGridItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                NavigationLink(value: item.route) {
                    MacLibraryCollectionListRow(item: item)
                }
                .buttonStyle(.plain)
                .macHoverRowHighlight()
                .contextMenu {
                    menu(for: item)
                    LibraryAlbumLinkMenuItems(route: item.route)
                }
                Divider().padding(.leading, 68)
            }
        }
    }

    @ViewBuilder
    private func menu(for item: LibraryGridItem) -> some View {
        switch item.route {
        case .playlist(let playlist):
            MacPlaylistContextMenu(playlist: playlist)
        case .local(let collection):
            Button("Play", systemImage: "play") {
                Task { await MacPlayback.play(collection.tracks[0], in: collection.tracks) }
            }
            .disabled(collection.tracks.isEmpty)
            Button("Shuffle", systemImage: "shuffle") {
                Task { await MacPlayback.shuffle(collection.tracks) }
            }
            .disabled(collection.tracks.isEmpty)
        }
    }

    private func play(_ item: LibraryGridItem) async {
        switch item.route {
        case .playlist(let playlist):
            await MacPlayback.play(playlist: playlist)
        case .local(let collection):
            guard let first = collection.tracks.first else { return }
            await MacPlayback.play(first, in: collection.tracks)
        }
    }
}

struct MacLibraryArtistsPane: View {
    @ObservedObject var model: LibraryCollectionsModel
    @ObservedObject private var findFocus = MacFindFocus.shared
    @ObservedObject private var identity = LibraryIdentity.shared
    @State private var isAddingFolder = false
    @State private var isSearchPresented = false
    @State private var searchText = ""
    @State private var selectedID: String?
    @AppStorage("library.artists.sort", store: .sounding) private var sort = LibraryArtistSort.name

    private var artists: [LibraryArtist] {
        LibraryArtists.list(identity.index.artists, search: searchText, sort: sort)
    }

    private var subtitle: String? {
        let count = identity.index.artists.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 artist" : "\(count.formatted()) artists"
    }

    var body: some View {
        states
            .macFillsPane()
            .navigationTitle(model.kind.title)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .toolbar,
                prompt: "Find in Artists"
            )
            .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
            .task { await model.load() }
            .addMusicFolderImporter(isPresented: $isAddingFolder)
    }

    @ViewBuilder
    private var states: some View {
        if identity.index.artists.isEmpty {
            if !identity.isReady || model.isLoading {
                LoadingPlaceholder(.trackList(.mac))
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
            LibraryArtistsSplit(
                artists: artists,
                searchText: searchText,
                selectedID: $selectedID,
                play: playArtist,
                listHeader: AnyView(header)
            ) { artist in
                LibraryArtistOverview(artist: artist, play: play) { track, queue in
                    MacTrackContextMenu(track: track, context: queue)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.kind.title)
                    .font(.largeTitle.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
            Spacer(minLength: 8)
            LibraryArtistSortMenu(sort: $sort)
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .labelStyle(.iconOnly)
                .fixedSize()
        }
        .padding(.horizontal, SCContentStyle.mac.spaceGutter)
        .padding(.top, SCContentStyle.mac.spaceBase)
        .padding(.bottom, SCContentStyle.mac.spaceSnug)
    }

    private func playArtist(_ artist: LibraryArtist, shuffled: Bool) {
        let tracks = identity.index.releases(for: artist, setMinimumDuration: SettingsStore.shared.setMinimumDurationSeconds).playable
        play(tracks, start: tracks.first, shuffled: shuffled)
    }

    private func play(_ tracks: [Track], start: Track?, shuffled: Bool) {
        let tracks = identity.index.preferringLocalCopies(tracks)
        let start = start.map { identity.index.localCopy(of: $0) ?? $0 }
        Task {
            if shuffled {
                await MacPlayback.shuffle(tracks)
            } else if let first = start ?? tracks.first {
                await MacPlayback.play(first, in: tracks)
            }
        }
    }
}

struct MacLocalCollectionView: View {
    let collection: LocalCollection
    @State private var titleIsHidden = false
    @State private var backdropGone = false

    private var isAlbum: Bool { collection.kind == .album }

    var body: some View {
        MacViewportScrollView(hidesContentUnderToolbar: backdropGone) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                hero
                    .macReportsScrolledAway($backdropGone)

                MacCollectionTrackTable(
                    tracks: collection.tracks,
                    margin: SCContentStyle.mac.spaceGutter,
                    onPlay: { track in Task { await MacPlayback.play(track, in: collection.tracks) } }
                )
            }
            .collectionPageScheme()
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectHidden(!backdropGone, for: .top)
        .tracksCollectionOverscroll()
        .animation(.smooth, value: backdropGone)
        .animation(.smooth, value: titleIsHidden)
        .collectionPage(artworkURL: collection.artworkURL)
        .collectionAccent(from: collection.artworkURL)
        .navigationTitle(collection.title)
        .toolbar(removing: .title)
        .toolbar {
            if titleIsHidden {
                MacScrolledPageTitle(title: collection.title)
            }
        }
        .onChange(of: titleIsHidden) { _, hidden in MacPageTitleVisibility.shared.isShowingPushedTitle = hidden }
        .onDisappear { MacPageTitleVisibility.shared.isShowingPushedTitle = false }
    }

    private var hero: some View {
        CollectionHero(content: heroContent, metrics: .macFullBleed) {
            HStack(spacing: SCContentStyle.mac.spaceSnug) {
                CollectionHeroPlayButtons(
                    isEnabled: !collection.tracks.isEmpty,
                    fills: false,
                    isCompact: true,
                    onPlay: play,
                    onShuffle: shuffle
                )
                if isAlbum {
                    LibraryAlbumCounterpartLink(route: .local(collection))
                    Menu {
                        LibraryAlbumLinkMenuItems(route: .local(collection))
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .help("More")
                    .accessibilityLabel("More")
                }
            }
            .padding(.top, SCContentStyle.mac.spaceTight)
        }
        .macReportsScrolledAway($titleIsHidden)
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

    private func play() {
        guard let first = collection.tracks.first else { return }
        Task { await MacPlayback.play(first, in: collection.tracks) }
    }

    private func shuffle() {
        guard !collection.tracks.isEmpty else { return }
        Task { await MacPlayback.shuffle(collection.tracks) }
    }
}

private struct MacLibraryCollectionListRow: View {
    let item: LibraryGridItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                url: item.artworkURL,
                identity: item.id,
                size: 56,
                cornerRadius: item.isCircular ? 28 : SCContentStyle.mac.artworkCorner
            )
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.subtitle)
                        .lineLimit(1)
                    if item.sources.contains(.files) && item.sources.contains(.soundCloud) {
                        LibrarySourceMarks(sources: item.sources)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
