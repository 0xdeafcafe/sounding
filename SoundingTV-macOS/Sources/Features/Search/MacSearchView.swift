import SwiftUI
import AppKit

@MainActor
final class MacSearchModel: ObservableObject {
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var artists: [User] = []
    @Published private(set) var albums: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isShowingCachedResults = false
    @Published private(set) var recentQueries: [String]

    private(set) var tracksPage: Page<Track>?
    private(set) var artistsPage: Page<User>?
    private(set) var playlistsPage: Page<Playlist>?

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var debounceTask: Task<Void, Never>?

    private var generation = 0
    private var completedNetworkGeneration: Int?
    private static let cacheSection = "search.mac.last"
    private static let recentQueriesKey = "red.forbes.sounding.mac.recentSearches"

    init() {
        recentQueries = UserDefaults.standard.stringArray(forKey: Self.recentQueriesKey) ?? []
    }

    private struct CachedSearch: Codable {
        let query: String
        let tracks: [Track]
        let artists: [User]
        let playlists: [Playlist]
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasResults: Bool {
        !tracks.isEmpty || !artists.isEmpty || !albums.isEmpty
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        generation &+= 1
        let issued = generation
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            tracks = []
            artists = []
            albums = []
            tracksPage = nil
            artistsPage = nil
            playlistsPage = nil
            errorMessage = nil
            isLoading = false
            isShowingCachedResults = false
            return
        }

        // Search is cache-first. Do not leave the prior query in place while
        // a new query is pending, but restore an exact previous result as soon
        // as the local cache responds.
        tracks = []
        artists = []
        albums = []
        tracksPage = nil
        artistsPage = nil
        playlistsPage = nil
        errorMessage = nil
        isLoading = true
        isShowingCachedResults = false
        completedNetworkGeneration = nil
        Task { [weak self] in
            await self?.hydrateCache(query: query, generation: issued)
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query, generation: issued)
        }
    }

    func retry() { scheduleSearch() }

    private func runSearch(query: String, generation: Int) async {
        isLoading = true
        defer {
            if generation == self.generation { isLoading = false }
        }

        async let tracksTask = api.searchTracks(query: query)
        async let artistsTask = api.searchUsers(query: query)
        async let playlistsTask = api.searchPlaylists(query: query)

        let tracksResult = try? await tracksTask
        let artistsResult = try? await artistsTask
        let playlistsResult = try? await playlistsTask

        guard generation == self.generation else { return }

        var anySucceeded = false
        if let tracksResult {
            tracks = tracksResult.collection
            tracksPage = tracksResult
            anySucceeded = true
        }
        if let artistsResult {
            artists = artistsResult.collection
            artistsPage = artistsResult
            anySucceeded = true
        }
        if let playlistsResult {
            playlistsPage = playlistsResult
            albums = playlistsResult.collection.filter(\.isAlbum)
            anySucceeded = true
        }

        errorMessage = anySucceeded ? nil : "Couldn't reach SoundCloud. Check your network connection."
        if anySucceeded {
            completedNetworkGeneration = generation
            isShowingCachedResults = false
            await persistCache(query: query)
            remember(query)
        }
    }

    private func remember(_ query: String) {
        recentQueries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentQueries.insert(query, at: 0)
        recentQueries = Array(recentQueries.prefix(12))
        UserDefaults.standard.set(recentQueries, forKey: Self.recentQueriesKey)
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
        albums = cached.playlists.filter(\.isAlbum)
        errorMessage = nil
        isShowingCachedResults = hasResults
    }

    private func persistCache(query: String) async {
        let snapshot = CachedSearch(
            query: query,
            tracks: tracks,
            artists: artists,
            playlists: playlistsPage?.collection ?? albums
        )
        guard let payload = try? JSONEncoder().encode(snapshot) else { return }
        await cache.replaceSection(Self.cacheSection, rows: [.init(id: query, payload: payload)])
    }

    static let browseGenres: [MusicGenre] = [
        .deepHouse, .techno, .trance, .hardstyle,
        .ukGarage, .drumAndBass, .dubstep, .nuDisco,
        .hipHop, .rnb, .pop, .ambient
    ]
}

@MainActor
final class SeeAllPagingModel<T: Identifiable & Codable>: ObservableObject {
    @Published private(set) var items: [T]
    @Published private(set) var isLoadingMore = false

    private var cursor = PageCursor<T>()

    init(page: Page<T>?) {
        items = page?.collection ?? []
        if let page { cursor.advance(to: page) }
    }

    var canLoadMore: Bool { cursor.canLoadMore }

    func loadMore() {
        guard !isLoadingMore, canLoadMore, let last = cursor.lastPage else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            do {
                let next = try await SoundCloudAPI.shared.getNextPage(last)
                cursor.advance(to: next)
                items.appendUnique(contentsOf: next.collection)
            } catch {
            }
        }
    }
}

private enum SearchDestination: Hashable {
    case artists, albums, songs
}

private enum MacSearchScope: String, CaseIterable, Identifiable {
    case soundCloud = "SoundCloud"
    case library = "Library"
    var id: Self { self }
}

struct MacSearchView: View {
    @ObservedObject private var model: MacSearchModel
    @ObservedObject private var libraryModel: MacLibraryModel
    @FocusState private var searchFieldFocused: Bool
    @State private var scope: MacSearchScope = .soundCloud
    @State private var librarySearchText = ""

    init(model: MacSearchModel, libraryModel: MacLibraryModel) {
        self.model = model
        self.libraryModel = libraryModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader
                content
            }
            .navigationDestination(for: SearchDestination.self) { destination in
                switch destination {
                case .artists: ArtistsSeeAllView(initialPage: model.artistsPage)
                case .albums: AlbumsSeeAllView(initialPage: model.playlistsPage)
                case .songs: SongsSeeAllView(initialPage: model.tracksPage)
                }
            }
            .navigationDestination(for: User.self) { user in
                MacArtistDetailView(user: user)
            }
            .navigationDestination(for: Playlist.self) { playlist in
                if playlist.isAlbum {
                    MacAlbumDetailView(album: playlist)
                } else {
                    MacPlaylistDetailView(playlist: playlist)
                }
            }
        }
        .navigationTitle("")
        .toolbar(removing: .title)
        .background(
            Group {
                Button("") { searchFieldFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { searchFieldFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
    }

    private var searchText: Binding<String> {
        scope == .soundCloud ? $model.searchText : $librarySearchText
    }

    private var searchHeader: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 180)

            HStack(spacing: 8) {
                MacSearchField(
                    text: searchText,
                    placeholder: scope == .soundCloud ? "Search SoundCloud" : "Search Library",
                    isFocused: $searchFieldFocused
                )
                if scope == .soundCloud, model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minWidth: 420, idealWidth: 620, maxWidth: 760)
            .overlay(alignment: .topLeading) {
                if searchFieldFocused, hasSearchSuggestions {
                    searchSuggestionsMenu
                        .padding(.top, 43)
                }
            }
            .zIndex(20)

            searchScopePicker
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
        .zIndex(20)
    }

    private var querySuggestions: [String] {
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(model.recentQueries.prefix(5)) }
        let candidates = model.recentQueries
            + model.artists.map(\.displayName)
            + model.tracks.map(\.title)
            + model.albums.map(\.title)
        var seen = Set<String>()
        return candidates.filter {
            let key = $0.lowercased()
            guard seen.insert(key).inserted,
                  $0.localizedCaseInsensitiveContains(query),
                  $0.caseInsensitiveCompare(query) != .orderedSame else { return false }
            return true
        }.prefix(3).map { $0 }
    }

    private var hasSearchSuggestions: Bool {
        !querySuggestions.isEmpty
            || (scope == .soundCloud && model.isSearching && model.hasResults)
    }

    private var searchSuggestionsMenu: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(querySuggestions, id: \.self) { suggestion in
                    Button {
                        searchText.wrappedValue = suggestion
                    } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if scope == .soundCloud, model.isSearching, model.hasResults {
                    Divider().padding(.horizontal, 14)

                    ForEach(model.artists.prefix(3)) { artist in
                        Button {
                            searchFieldFocused = false
                            MacRootSelection.shared.request(artist: artist)
                        } label: {
                            searchResultRow(
                                title: artist.displayName,
                                subtitle: "Artist",
                                artworkURL: artist.avatarURL,
                                circular: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(model.tracks.prefix(3)) { track in
                        Button {
                            searchFieldFocused = false
                            Task { await PlayerService.shared.play(track, in: model.tracks) }
                        } label: {
                            searchResultRow(
                                title: track.title,
                                subtitle: "Track · \(track.user.displayName)",
                                artworkURL: track.artworkURL,
                                circular: false
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(model.albums.prefix(2)) { album in
                        NavigationLink(value: album) {
                            searchResultRow(
                                title: album.title,
                                subtitle: "Album · \(album.user.displayName)",
                                artworkURL: album.artworkURL,
                                circular: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 520)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [.clear, Color.orange.opacity(0.15), Color(red: 0.16, green: 0.05, blue: 0.02).opacity(0.35)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.38), radius: 22, y: 11)
    }

    private func searchResultRow(
        title: String,
        subtitle: String,
        artworkURL: URL?,
        circular: Bool
    ) -> some View {
        HStack(spacing: 11) {
            SearchSuggestionArtwork(url: artworkURL, circular: circular)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .contentShape(Rectangle())
    }

    private var searchScopePicker: some View {
        HStack(spacing: 3) {
            ForEach(MacSearchScope.allCases) { candidate in
                Button {
                    scope = candidate
                    searchFieldFocused = true
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: scope == candidate ? .semibold : .medium))
                        .foregroundStyle(scope == candidate ? Color.white : Color.secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(
                            scope == candidate ? Color.white.opacity(0.12) : .clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if scope == .library {
            libraryContent
        } else if !model.isSearching {
            browseCategoriesSection
        } else if model.isLoading, !model.hasResults {
            searchingState
        } else if let errorMessage = model.errorMessage, !model.hasResults {
            SCEmptyState(
                kind: .error,
                title: "Couldn't Search SoundCloud",
                message: errorMessage,
                actionTitle: "Try Again",
                action: { model.retry() },
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasResults {
            SCEmptyState(
                icon: "magnifyingglass",
                title: "No Results",
                message: "Try a different spelling, or search for an artist instead.",
                actionTitle: "Clear Search",
                action: { model.searchText = "" },
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            resultsSections
                .overlay(alignment: .topTrailing) {
                    if model.isLoading && model.isShowingCachedResults {
                        cacheRefreshNotice
                            .padding(16)
                    }
                }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SCEmptyState(
                icon: "music.note.list",
                title: "Search Your Library",
                message: "Find songs from your likes and saved library.",
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryMatches.isEmpty {
            SCEmptyState(
                icon: "magnifyingglass",
                title: "No Library Results",
                message: "Nothing in your library matched \u{201C}\(librarySearchText)\u{201D}.",
                actionTitle: "Clear Search",
                action: { librarySearchText = "" },
                style: .mac
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SCSectionHeader(title: "Songs in Your Library", style: .mac)
                    LazyVGrid(columns: Self.songColumns, alignment: .leading, spacing: 2) {
                        ForEach(libraryMatches) { track in
                            SongRow(track: track, context: libraryMatches)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var libraryMatches: [Track] {
        let needle = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return libraryModel.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.user.displayName.localizedCaseInsensitiveContains(needle)
                || $0.user.username.localizedCaseInsensitiveContains(needle)
                || ($0.genre?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private static let browseColumns = Array(
        repeating: GridItem(.flexible(), spacing: SCContentStyle.mac.spaceBase),
        count: 5
    )

    private var browseCategoriesSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceGutter) {
                if !model.recentQueries.isEmpty {
                    SCSectionHeader(title: "Recently Searched", style: .mac)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(model.recentQueries.prefix(8), id: \.self) { query in
                                Button {
                                    model.searchText = query
                                    searchFieldFocused = true
                                } label: {
                                    Label(query, systemImage: "clock.arrow.circlepath")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 14)
                                        .frame(height: 38)
                                        .glassEffect(
                                            .regular.tint(.orange.opacity(0.06)),
                                            in: Capsule(style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                SCSectionHeader(title: "Vibes", style: .mac)

                LazyVGrid(columns: Self.browseColumns, spacing: SCContentStyle.mac.spaceBase) {
                    ForEach(SearchVibe.all) { vibe in
                        VibeBrowseTile(vibe: vibe) {
                            model.searchText = vibe.query
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var cacheRefreshNotice: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Refreshing saved results…")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .accessibilityLabel("Refreshing saved search results")
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Searching SoundCloud…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
    }

    private var resultsSections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                if !model.artists.isEmpty {
                    resultsSection(title: "Artists", destination: .artists) {
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(model.artists.prefix(8)) { user in
                                ArtistTile(user: user)
                            }
                        }
                    }
                }

                if !model.albums.isEmpty {
                    resultsSection(title: "Albums", destination: .albums) {
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(model.albums.prefix(6)) { playlist in
                                AlbumTile(playlist: playlist)
                            }
                        }
                    }
                }

                if !model.tracks.isEmpty {
                    resultsSection(title: "Songs", destination: .songs) {
                        LazyVGrid(columns: Self.songColumns, alignment: .leading, spacing: 2) {
                            ForEach(model.tracks.prefix(10)) { track in
                                SongRow(track: track, context: model.tracks)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .prefetchArtwork(resultsArtworkURLs)
    }

    private var resultsArtworkURLs: [URL] {
        model.artists.prefix(8).compactMap { $0.largeAvatarURL ?? $0.avatarURL }
            + model.albums.prefix(6).compactMap(\.displayArtworkURL)
            + model.tracks.prefix(10).compactMap(\.artworkURL)
    }

    private static let songColumns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]

    @ViewBuilder
    private func resultsSection<Content: View>(
        title: String, destination: SearchDestination, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: destination) {
                SCSectionHeader(title: title, showChevron: true, style: .mac)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal) {
                content()
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct MacSearchField: View {
    @Binding var text: String
    var placeholder = "Search SoundCloud"
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: SCContentStyle.mac.spaceTight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(.orange.opacity(isFocused.wrappedValue ? 0.08 : 0.025)),
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.orange.opacity(isFocused.wrappedValue ? 0.62 : 0.10),
                    lineWidth: isFocused.wrappedValue ? 1.5 : 0.7
                )
        }
    }
}

private struct SearchSuggestionArtwork: View {
    let url: URL?
    let circular: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.orange.opacity(0.14))
                    .overlay {
                        Image(systemName: circular ? "person.fill" : "waveform")
                            .foregroundStyle(Color.orange.opacity(0.72))
                    }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(
            circular
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        )
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ArtworkCache.shared.image(for: url, variant: .standard)
        }
    }
}

private struct SearchAvatarView: View {
    let url: URL?
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.32))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ArtworkCache.shared.image(for: url, variant: .standard)
        }
    }
}

private struct ArtistTile: View {
    let user: User

    var body: some View {
        Button {
            MacRootSelection.shared.request(artist: user)
        } label: {
            VStack(spacing: 8) {
                SearchAvatarView(url: user.avatarURL, size: 96)
                Text(user.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .contextMenu { MacArtistContextMenu(artist: user) }
        .help("View \(user.displayName)")
    }
}

private struct AlbumTile: View {
    let playlist: Playlist

    var body: some View {
        NavigationLink(value: playlist) {
            MacPlaylistCard(playlist: playlist)
                .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .contextMenu { MacPlaylistContextMenu(playlist: playlist) }
        .help("View “\(playlist.title)”")
    }
}

private struct SongRow: View {
    let track: Track
    let context: [Track]

    private var isPlayable: Bool { track.streamURL != nil }

    @State private var artwork: NSImage?

    private var displayedArtwork: NSImage? {
        if let artwork { return artwork }
        guard let url = track.artworkURL else { return nil }
        return ArtworkCache.shared.cachedImage(for: url, variant: .standard)
    }

    var body: some View {
        SCTrackRow(
            title: track.title,
            subtitle: track.user.displayName,
            artworkImage: displayedArtwork.map { Image(nsImage: $0) },
            isAvailable: isPlayable,
            crownUser: track.user,
            crownContext: track.title,
            style: .mac
        ) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .help("Right-click for more options")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard isPlayable else { return }
            Task { await PlayerService.shared.play(track, in: context) }
        }
        .contextMenu { MacTrackContextMenu(track: track) }
        .task(id: track.artworkURL) {
            guard let url = track.artworkURL else {
                artwork = nil
                return
            }
            if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .standard) {
                artwork = cached
                return
            }
            artwork = await ArtworkCache.shared.image(for: url, variant: .standard)
        }
    }
}

private struct ArtistsSeeAllView: View {
    @StateObject private var paging: SeeAllPagingModel<User>

    init(initialPage: Page<User>?) {
        _paging = StateObject(wrappedValue: SeeAllPagingModel(page: initialPage))
    }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 20)]

    private static let artworkLookahead = 12

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(Array(paging.items.enumerated()), id: \.element.id) { index, user in
                    ArtistTile(user: user)
                        .onAppear {
                            guard paging.items.isNearEnd(user, lead: 8) else { return }
                            paging.loadMore()
                        }
                        .onAppear {
                            let items = paging.items
                            let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
                        }
                }
            }
            .padding(20)

            if paging.isLoadingMore {
                ProgressView().padding(.bottom, 20)
            }
        }
        .navigationTitle("Artists")
    }
}

private struct AlbumsSeeAllView: View {
    @StateObject private var paging: SeeAllPagingModel<Playlist>

    init(initialPage: Page<Playlist>?) {
        _paging = StateObject(wrappedValue: SeeAllPagingModel(page: initialPage))
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 20)]

    private var albums: [Playlist] { paging.items.filter(\.isAlbum) }

    private static let artworkLookahead = 12

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, playlist in
                    AlbumTile(playlist: playlist)
                        .onAppear {
                            guard albums.isNearEnd(playlist, lead: 6) else { return }
                            paging.loadMore()
                        }
                        .onAppear {
                            let items = albums
                            let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                        }
                }
            }
            .padding(20)

            if paging.isLoadingMore {
                ProgressView().padding(.bottom, 20)
            }
        }
        .navigationTitle("Albums")
    }
}

private struct SongsSeeAllView: View {
    @StateObject private var paging: SeeAllPagingModel<Track>

    init(initialPage: Page<Track>?) {
        _paging = StateObject(wrappedValue: SeeAllPagingModel(page: initialPage))
    }

    private let columns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]

    private static let artworkLookahead = 10

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(Array(paging.items.enumerated()), id: \.element.id) { index, track in
                    SongRow(track: track, context: paging.items)
                        .onAppear {
                            guard paging.items.isNearEnd(track, lead: 10) else { return }
                            paging.loadMore()
                        }
                        .onAppear {
                            let items = paging.items
                            let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                        }
                }
            }
            .padding(20)

            if paging.isLoadingMore {
                ProgressView().padding(.bottom, 20)
            }
        }
        .navigationTitle("Songs")
    }
}

private struct VibeBrowseTile: View {
    let vibe: SearchVibe
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SearchVibeArtwork(vibe: vibe, cornerRadius: SCContentStyle.mac.cornerControl)
            .aspectRatio(1.7, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerControl, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovering ? 0.25 : 0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .onHover { isHovering = $0 }
        .animation(SCContentMotion.focus, value: isHovering)
    }
}
