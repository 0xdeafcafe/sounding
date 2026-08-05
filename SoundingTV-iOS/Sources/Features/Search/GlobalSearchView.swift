import SwiftUI
import os

struct GlobalSearchView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var viewModel = GlobalSearchViewModel()
    @StateObject private var confirmation = QueueConfirmationController()
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var playlistNamespace

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                recentSearchesState
            } else {
                resultsState
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AccountAvatarButton()
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Artists, Tracks, and Playlists")
        .onChange(of: viewModel.searchText) { _, _ in viewModel.scheduleSearch() }
        .onSubmit(of: .search) { viewModel.rememberCurrentQuery() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
        .task { credentials.refreshFromStore() }
        .queueConfirmationOverlay(confirmation)
    }

    private var recentSearchesState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("Search SoundCloud")
                        .font(.scTitle2)
                        .foregroundStyle(Color.scTextPrimary)
                    Text("Find tracks, artists and playlists, or start with a genre.")
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                }
                .padding(.horizontal, Space.page)

                if !viewModel.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: Space.base) {
                        HStack {
                            Text("Recently Searched")
                                .font(.scHeadline)
                                .foregroundStyle(Color.scTextPrimary)
                            Spacer()
                            Button("Clear") { viewModel.clearRecentSearches() }
                                .font(.scSubhead)
                                .foregroundStyle(Color.scAccent)
                        }
                        .padding(.horizontal, Space.page)

                        VStack(spacing: 0) {
                            ForEach(viewModel.recentSearches) { entry in
                                RecentSearchRow(entry: entry) {
                                    viewModel.searchText = entry.query
                                    viewModel.scheduleSearch(immediate: true)
                                }
                                if entry.id != viewModel.recentSearches.last?.id {
                                    ScRowDivider(leading: 52 + Space.snug)
                                }
                            }
                        }
                        .padding(.horizontal, Space.page)
                    }
                }

                VStack(alignment: .leading, spacing: Space.base) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browse")
                            .font(.scTitle2)
                            .foregroundStyle(Color.scTextPrimary)
                        Text("Pick a genre, then narrow it down from there.")
                            .font(.scSubhead)
                            .foregroundStyle(Color.scTextSecondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.snug) {
                        ForEach(GlobalSearchViewModel.browseGenres, id: \.self) { genre in
                            PhoneSearchGenreTile(genre: genre) {
                                viewModel.searchText = GenreProfile.of(genre).displayName
                                viewModel.scheduleSearch(immediate: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.page)
            }
            .padding(.top, Space.tight)
            .padding(.bottom, PhoneChrome.floatingClearance)
        }
    }

    @ViewBuilder
    private var resultsState: some View {
        switch viewModel.state {
        case .loading where viewModel.hasResults:
            searchResultsList
                .overlay(alignment: .top) {
                    if viewModel.isShowingCachedResults {
                        SearchCacheRefreshNotice()
                            .padding(.top, Space.tight)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, Space.tight)
                    }
                }

        case .loading:
            LoadingState(message: "Searching…")

        case .error(let message):
            SCEmptyState(
                kind: .error, title: "Search Failed", message: message,
                actionTitle: "Try Again",
                action: { viewModel.scheduleSearch(immediate: true) },
                style: .phone
            )

        case .empty:
            SCEmptyState(
                icon: "magnifyingglass",
                title: "No Results",
                message: "Try a different spelling, or search for an artist instead.",
                style: .phone
            )

        case .loaded:
            searchResultsList
        }
    }

    private var searchResultsList: some View {
        List {
            if !viewModel.tracks.isEmpty {
                Section("Songs") {
                    ForEach(viewModel.tracks.prefix(GlobalSearchViewModel.previewCount)) { track in
                        TrackListRow(
                            track: track, analysis: nil,
                            context: { Array(viewModel.tracks.prefix(GlobalSearchViewModel.previewCount)) },
                            confirmation: confirmation
                        )
                    }
                    if viewModel.tracks.count > GlobalSearchViewModel.previewCount {
                        seeAllRow(kind: .tracks)
                    }
                }
            }

            if !viewModel.artists.isEmpty {
                Section("Artists") {
                    ForEach(viewModel.artists.prefix(GlobalSearchViewModel.previewCount)) { user in
                        NavigationLink { ArtistDetailView(user: user) } label: { UserRow(user: user) }
                    }
                    if viewModel.artists.count > GlobalSearchViewModel.previewCount {
                        seeAllRow(kind: .artists)
                    }
                }
            }

            if !viewModel.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(viewModel.playlists.prefix(GlobalSearchViewModel.previewCount)) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist, heroNamespace: playlistNamespace)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                        .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
                    }
                    if viewModel.playlists.count > GlobalSearchViewModel.previewCount {
                        seeAllRow(kind: .playlists)
                    }
                }
            }
        }
        .listStyle(.plain)
        .prefetchArtwork(searchResultsArtworkURLs)
    }

    private var searchResultsArtworkURLs: [URL] {
        viewModel.tracks.prefix(GlobalSearchViewModel.previewCount).compactMap(\.artworkURL)
            + viewModel.artists.prefix(GlobalSearchViewModel.previewCount).compactMap { $0.largeAvatarURL ?? $0.avatarURL }
            + viewModel.playlists.prefix(GlobalSearchViewModel.previewCount).compactMap(\.artworkURL)
    }

    private func seeAllRow(kind: GlobalSearchScopedListView.Kind) -> some View {
        NavigationLink {
            GlobalSearchScopedListView(kind: kind, query: trimmedQuery)
        } label: {
            Text("See All \(kind.title)")
                .font(.scSubhead)
                .foregroundStyle(Color.scAccent)
        }
    }
}

private struct RecentSearchRow: View {
    let entry: RecentSearchEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                ArtworkThumbnail(url: entry.avatarURL, systemImage: "magnifyingglass", isCircle: true, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.query)
                        .font(.scBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PhoneSearchGenreTile: View {
    let genre: MusicGenre
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(.white.opacity(0.14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                Text(GenreProfile.of(genre).displayName)
                    .font(.scHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(14)
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse \(GenreProfile.of(genre).displayName)")
    }

    private var palette: [Color] {
        switch GenreProfile.of(genre).family {
        case .house: return [Color.indigo, Color.blue]
        case .techno: return [Color.black, Color.purple]
        case .trance: return [Color.cyan, Color.indigo]
        case .garage: return [Color.orange, Color.pink]
        case .bass: return [Color.red, Color.purple]
        case .disco: return [Color.pink, Color.orange]
        case .urban: return [Color.brown, Color.orange]
        case .ambient: return [Color.teal, Color.blue]
        default: return [Color.gray, Color.indigo]
        }
    }

    private var symbol: String {
        switch GenreProfile.of(genre).family {
        case .house: return "house.fill"
        case .techno: return "waveform.path.ecg"
        case .trance: return "sparkles"
        case .garage: return "car.fill"
        case .bass: return "waveform"
        case .disco: return "party.popper.fill"
        case .urban: return "mic.fill"
        case .ambient: return "cloud.fill"
        default: return "music.note"
        }
    }
}

@MainActor
final class GlobalSearchViewModel: ObservableObject {
    enum State: Equatable {
        case loading, loaded, empty, error(String)
    }

    static let previewCount = 5
    static let browseGenres: [MusicGenre] = [
        .deepHouse, .techno, .trance, .ukGarage,
        .drumAndBass, .nuDisco, .hipHop, .ambient
    ]

    @Published var searchText = ""
    @Published private(set) var state: State = .empty
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var artists: [User] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var recentSearches: [RecentSearchEntry]
    @Published private(set) var isShowingCachedResults = false

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private var completedNetworkGeneration: Int?
    private var failedNetworkGeneration: Int?
    private static let cacheSection = "search.phone.last"

    private struct CachedSearch: Codable {
        let query: String
        let tracks: [Track]
        let artists: [User]
        let playlists: [Playlist]
    }

    var hasResults: Bool {
        !tracks.isEmpty || !artists.isEmpty || !playlists.isEmpty
    }

    init() {
        recentSearches = SettingsStore.shared.recentSearchQueries
    }

    func scheduleSearch(immediate: Bool = false) {
        debounceTask?.cancel()
        generation &+= 1
        let issued = generation
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            tracks = []
            artists = []
            playlists = []
            state = .empty
            isShowingCachedResults = false
            return
        }

        // Never display results for a different query while typing. If this
        // exact search ran recently, restore it immediately below.
        tracks = []
        artists = []
        playlists = []
        state = .loading
        isShowingCachedResults = false
        completedNetworkGeneration = nil
        failedNetworkGeneration = nil
        Task { [weak self] in
            await self?.hydrateCache(query: query, generation: issued)
        }

        debounceTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query, generation: issued)
        }
    }

    private func runSearch(query: String, generation: Int) async {
        if !hasResults { state = .loading }

        async let tracksResult = try? api.searchTracks(query: query, limit: 25)
        async let artistsResult = try? api.searchUsers(query: query, limit: 10)
        async let playlistsResult = try? api.searchPlaylists(query: query, limit: 10)

        let (tracksPage, artistsPage, playlistsPage) = await (tracksResult, artistsResult, playlistsResult)
        guard generation == self.generation else { return }

        if tracksPage == nil, artistsPage == nil, playlistsPage == nil {
            failedNetworkGeneration = generation
            if !hasResults {
                state = .error("Couldn't reach SoundCloud. Check your connection and try again.")
            } else {
                state = .loaded
            }
            return
        }

        completedNetworkGeneration = generation
        failedNetworkGeneration = nil
        tracks = tracksPage?.collection ?? []
        artists = artistsPage?.collection ?? []
        playlists = playlistsPage?.collection ?? []
        isShowingCachedResults = false
        state = (tracks.isEmpty && artists.isEmpty && playlists.isEmpty) ? .empty : .loaded
        await persistCache(query: query)
    }

    private func hydrateCache(query: String, generation: Int) async {
        let rows = await cache.loadSection(Self.cacheSection)
        guard let payload = rows.first?.payload,
              let cached = try? JSONDecoder().decode(CachedSearch.self, from: payload),
              cached.query.caseInsensitiveCompare(query) == .orderedSame,
              generation == self.generation,
              completedNetworkGeneration != generation else { return }
        tracks = cached.tracks
        artists = cached.artists
        playlists = cached.playlists
        isShowingCachedResults = hasResults
        if hasResults, failedNetworkGeneration == generation {
            state = .loaded
        }
    }

    private func persistCache(query: String) async {
        let snapshot = CachedSearch(query: query, tracks: tracks, artists: artists, playlists: playlists)
        guard let payload = try? JSONEncoder().encode(snapshot) else { return }
        await cache.replaceSection(Self.cacheSection, rows: [.init(id: query, payload: payload)])
    }

    func rememberCurrentQuery() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let entry: RecentSearchEntry
        if let match = artists.first(where: { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }) {
            entry = RecentSearchEntry(query: query, avatarURL: match.avatarURL, subtitle: "Artist")
        } else {
            entry = RecentSearchEntry(query: query, avatarURL: nil, subtitle: "Search")
        }

        var next = recentSearches.filter { $0.query.caseInsensitiveCompare(query) != .orderedSame }
        next.insert(entry, at: 0)
        next = Array(next.prefix(8))
        recentSearches = next
        SettingsStore.shared.setRecentSearchQueries(next)
    }

    func clearRecentSearches() {
        recentSearches = []
        SettingsStore.shared.setRecentSearchQueries([])
    }
}

struct GlobalSearchScopedListView: View {
    enum Kind {
        case tracks, artists, playlists

        var title: String {
            switch self {
            case .tracks:    return "Songs"
            case .artists:   return "Artists"
            case .playlists: return "Playlists"
            }
        }
    }

    let kind: Kind
    let query: String

    @StateObject private var viewModel = GlobalSearchScopedListViewModel()
    @StateObject private var confirmation = QueueConfirmationController()
    @Namespace private var playlistNamespace

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load(kind: kind, query: query) }
            .queueConfirmationOverlay(confirmation)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingState(message: "Loading \(kind.title.lowercased())…")
        case .error(let message):
            SCEmptyState(
                kind: .error, title: "Couldn't Load", message: message,
                actionTitle: "Try Again",
                action: { Task { await viewModel.load(kind: kind, query: query) } },
                style: .phone
            )
        case .empty:
            SCEmptyState(icon: "magnifyingglass", title: "No Results", message: "Nothing matched \u{201C}\(query)\u{201D}.", style: .phone)
        case .loaded:
            List {
                switch kind {
                case .tracks:
                    ForEach(Array(viewModel.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackListRow(track: track, analysis: nil, context: { viewModel.tracks }, confirmation: confirmation)
                            .onAppear {
                                guard viewModel.tracks.isNearEnd(track, lead: 10) else { return }
                                Task { await viewModel.loadMore() }
                            }
                            .onAppear {
                                let tracks = viewModel.tracks
                                let lookahead = tracks[index..<min(index + Self.artworkLookahead, tracks.count)]
                                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                            }
                    }
                case .artists:
                    ForEach(Array(viewModel.artists.enumerated()), id: \.element.id) { index, user in
                        NavigationLink { ArtistDetailView(user: user) } label: { UserRow(user: user) }
                            .onAppear {
                                guard viewModel.artists.isNearEnd(user, lead: 10) else { return }
                                Task { await viewModel.loadMore() }
                            }
                            .onAppear {
                                let artists = viewModel.artists
                                let lookahead = artists[index..<min(index + Self.artworkLookahead, artists.count)]
                                ArtworkCache.shared.prefetch(lookahead.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
                            }
                    }
                case .playlists:
                    ForEach(Array(viewModel.playlists.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist, heroNamespace: playlistNamespace)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                        .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
                        .onAppear {
                            guard viewModel.playlists.isNearEnd(playlist, lead: 10) else { return }
                            Task { await viewModel.loadMore() }
                        }
                        .onAppear {
                            let playlists = viewModel.playlists
                            let lookahead = playlists[index..<min(index + Self.artworkLookahead, playlists.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                        }
                    }
                }
                if viewModel.isLoadingMore {
                    LoadingMoreRow()
                }
            }
            .listStyle(.plain)
        }
    }

    private static let artworkLookahead = 10
}

@MainActor
private final class GlobalSearchScopedListViewModel: ObservableObject {
    enum State: Equatable { case loading, loaded, empty, error(String) }

    @Published private(set) var state: State = .loading
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var artists: [User] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoadingMore = false

    private let api = SoundCloudAPI.shared
    private var trackCursor = PageCursor<Track>()
    private var artistCursor = PageCursor<User>()
    private var playlistCursor = PageCursor<Playlist>()
    private var loadedOnce = false

    func load(kind: GlobalSearchScopedListView.Kind, query: String) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        state = .loading

        do {
            switch kind {
            case .tracks:
                let page = try await api.searchTracks(query: query, limit: 50)
                tracks = page.collection
                trackCursor.advance(to: page)
                state = tracks.isEmpty ? .empty : .loaded
            case .artists:
                let page = try await api.searchUsers(query: query, limit: 50)
                artists = page.collection
                artistCursor.advance(to: page)
                state = artists.isEmpty ? .empty : .loaded
            case .playlists:
                let page = try await api.searchPlaylists(query: query, limit: 50)
                playlists = page.collection
                playlistCursor.advance(to: page)
                state = playlists.isEmpty ? .empty : .loaded
            }
        } catch {
            state = .error("Couldn't reach SoundCloud. Check your connection and try again.")
        }
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            if let page = trackCursor.lastPage, trackCursor.canLoadMore {
                let next = try await api.getNextPage(page)
                trackCursor.advance(to: next)
                tracks.appendUnique(contentsOf: next.collection)
            } else if let page = artistCursor.lastPage, artistCursor.canLoadMore {
                let next = try await api.getNextPage(page)
                artistCursor.advance(to: next)
                artists.appendUnique(contentsOf: next.collection)
            } else if let page = playlistCursor.lastPage, playlistCursor.canLoadMore {
                let next = try await api.getNextPage(page)
                playlistCursor.advance(to: next)
                playlists.appendUnique(contentsOf: next.collection)
            }
        } catch {
            Log.api.error("Search scoped load-more error: \(error, privacy: .public)")
        }
    }
}
