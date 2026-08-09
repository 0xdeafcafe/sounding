import SwiftUI

private let searchColumns: [GridItem] = Array(
    repeating: .init(.flexible(), spacing: Space.gutter),
    count: 4
)

private let browseColumns: [GridItem] = Array(
    repeating: .init(.flexible(), spacing: Space.gutter),
    count: 4
)

private let prefetchLead = 12
private let artworkLookahead = 12

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject var playerService: PlayerService
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case firstBrowseTile }

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if viewModel.searchText.isEmpty {
                    emptyState
                } else if !viewModel.libraryResults.isEmpty || !viewModel.results.isEmpty {
                    resultsGrid
                } else if viewModel.isLoading {
                    StatusPanel(kind: .loading, title: "Searching…", minHeight: 480)
                } else if let error = viewModel.errorMessage {
                    StatusPanel(
                        kind: .error,
                        title: "Search failed",
                        message: error,
                        actionTitle: "Try Again",
                        action: { viewModel.retry() },
                        minHeight: 480
                    )
                } else {
                    noResultsState
                }
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.bottom, Space.gutter)
        }
        .scrollClipDisabled()
        .defaultFocus($focus, .firstBrowseTile)
        .onAppear {
            DispatchQueue.main.async { focus = .firstBrowseTile }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search")
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.scheduleSearch()
        }
        .onSubmit(of: .search) {
            viewModel.rememberCurrentQuery()
        }
    }

    private var resultsGrid: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            if viewModel.isLoading && viewModel.isShowingCachedResults {
                HStack(spacing: Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing saved results…")
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
                .accessibilityLabel("Refreshing saved search results")
            }

            if !viewModel.libraryResults.isEmpty {
                VStack(alignment: .leading, spacing: Space.base) {
                    Eyebrow(text: "From Your Library")

                    LazyVGrid(columns: searchColumns, spacing: Space.gutter) {
                        ForEach(viewModel.libraryResults) { track in
                            trackResultCell(track, in: viewModel.libraryResults)
                        }
                    }
                    .buttonStyle(SCCardButtonStyle())
                    .focusEffectDisabled()
                    .prefetchArtwork(viewModel.libraryResults.compactMap(\.artworkURL))
                }
                .focusSection()
            }

            if !viewModel.results.isEmpty {
                VStack(alignment: .leading, spacing: Space.base) {
                    if !viewModel.libraryResults.isEmpty {
                        Eyebrow(text: "SoundCloud")
                    }

                    LazyVGrid(columns: searchColumns, spacing: Space.gutter) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, track in
                            trackResultCell(track, in: viewModel.results)
                                .onAppear {
                                    guard viewModel.results.isNearEnd(track, lead: prefetchLead) else { return }
                                    Task { await viewModel.loadMore() }
                                }
                                .onAppear {
                                    let lookahead = viewModel.results[index..<min(index + artworkLookahead, viewModel.results.count)]
                                    ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                                }
                        }
                    }
                    .buttonStyle(SCCardButtonStyle())
                    .focusEffectDisabled()
                }
                .focusSection()
            }

            if viewModel.isLoadingMore {
                LoadingMoreRow()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SCBrowseMetrics.pageInset)
    }

    private func trackResultCell(_ track: Track, in context: [Track]) -> some View {
        Button {
            Task { await playerService.play(track, in: context) }
        } label: {
            VStack(alignment: .leading, spacing: Space.tight) {
                ArtworkImage(url: track.artworkURL)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                    .kyleCrowned(user: track.user, context: track.title)

                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.tvBodyEmph)
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(track.user.displayName)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Search SoundCloud")
                    .font(.tvTitle)
                    .foregroundStyle(Color.scTextPrimary)
                Text("Find tracks and artists, or start with a category.")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
            }
            if !viewModel.recentSearches.isEmpty {
                recentSearchesSection
            }
            browseCategoriesSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SCBrowseMetrics.pageInset)
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Eyebrow(text: "Recently Searched")

            ScrollView(.horizontal) {
                LazyHStack(spacing: Space.base) {
                    ForEach(viewModel.recentSearches) { entry in
                        RecentSearchRow(entry: entry) {
                            viewModel.searchText = entry.query
                            viewModel.scheduleSearch()
                        }
                        .frame(width: 640)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var browseCategoriesSection: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Eyebrow(text: "Vibes")

            LazyVGrid(columns: browseColumns, spacing: Space.gutter) {
                ForEach(Array(SearchVibe.all.enumerated()), id: \.offset) { index, vibe in
                    let tile = VibeTileButton(vibe: vibe) {
                        viewModel.searchText = vibe.query
                        viewModel.scheduleSearch()
                    }
                    if index == 0 {
                        tile.focused($focus, equals: .firstBrowseTile)
                    } else {
                        tile
                    }
                }
            }
        }
        .focusSection()
    }

    private var noResultsState: some View {
        StatusPanel(
            kind: .empty,
            icon: "magnifyingglass",
            title: "No results found",
            message: "Try a different spelling, or search for an artist instead.",
            minHeight: 480
        )
    }
}

private struct RecentSearchRow: View {
    let entry: RecentSearchEntry
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.base) {
            ArtworkImage(url: entry.avatarURL) {
                Circle().fill(Color.scBgRaised)
                    .overlay(
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.scTextTertiary)
                    )
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.query)
                    .font(.tvBodyEmph)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.snug)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous).fill(Color.scBgRaised))
        .scFocus(focused, cornerRadius: Corner.panel, reduceMotion: reduceMotion)
        .contentShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityLabel("\(entry.query), \(entry.subtitle)")
    }
}

private struct VibeTileButton: View {
    let vibe: SearchVibe
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SearchVibeArtwork(vibe: vibe, cornerRadius: Corner.control)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        .scFocus(focused, cornerRadius: Corner.control, reduceMotion: reduceMotion)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityLabel(vibe.title)
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [Track] = []
    @Published private(set) var libraryResults: [Track] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var recentSearches: [RecentSearchEntry]
    @Published private(set) var isShowingCachedResults = false

    init() {
        recentSearches = SettingsStore.shared.recentSearchQueries
        LikesSyncEngine.shared.activate()
    }

    static let browseGenres: [MusicGenre] = [
        .deepHouse, .techno, .trance, .hardstyle,
        .ukGarage, .drumAndBass, .dubstep, .nuDisco,
        .hipHop, .rnb, .pop, .ambient
    ]

    private static let maxRecents = 8

    private static func representativeEntry(for query: String, in results: [Track]) -> RecentSearchEntry {
        if let match = results.first(where: { $0.user.displayName.caseInsensitiveCompare(query) == .orderedSame }) {
            return RecentSearchEntry(query: query, avatarURL: match.user.avatarURL, subtitle: "Artist")
        }
        return RecentSearchEntry(query: query, avatarURL: nil, subtitle: "Search")
    }

    func rememberCurrentQuery() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let entry = Self.representativeEntry(for: query, in: results)
        var next = recentSearches.filter { $0.query.caseInsensitiveCompare(query) != .orderedSame }
        next.insert(entry, at: 0)
        next = Array(next.prefix(Self.maxRecents))
        recentSearches = next
        SettingsStore.shared.setRecentSearchQueries(next)
    }

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var debounceTask: Task<Void, Never>?
    private var resultsCursor = PageCursor<Track>()

    private var generation = 0
    private var completedNetworkGeneration: Int?
    private static let cacheSection = "search.tv.last"

    private struct CachedSearch: Codable {
        let query: String
        let tracks: [Track]
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        generation &+= 1
        let issued = generation
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else {
            results = []
            libraryResults = []
            resultsCursor.reset()
            errorMessage = nil
            isLoading = false
            isShowingCachedResults = false
            return
        }

        // Keep the on-screen result tied to the query. A recent exact search
        // is restored from disk while SoundCloud refreshes in the background.
        results = []
        libraryResults = []
        resultsCursor.reset()
        errorMessage = nil
        isLoading = true
        isShowingCachedResults = false
        completedNetworkGeneration = nil

        Task { [weak self] in
            await self?.hydrateCache(query: query, generation: issued)
        }

        Task { [weak self] in
            await self?.runLibrarySearch(query: query, generation: issued)
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query, generation: issued)
        }
    }

    private func runLibrarySearch(query: String, generation: Int) async {
        let hits = await LikesSyncEngine.shared.searchLibrary(query, limit: 8)
        guard generation == self.generation else { return }
        libraryResults = hits
    }

    func retry() {
        scheduleSearch()
    }

    private func runSearch(query: String, generation: Int) async {
        if results.isEmpty { isLoading = true }
        defer {
            if generation == self.generation { isLoading = false }
        }

        do {
            let result = try await api.searchTracks(query: query)
            guard generation == self.generation else { return }
            completedNetworkGeneration = generation
            results = result.collection
            resultsCursor.advance(to: result)
            errorMessage = nil
            isShowingCachedResults = false
            await persistCache(query: query)
        } catch {
            guard generation == self.generation else { return }
            print("Search error: \(error)")
            if results.isEmpty, libraryResults.isEmpty {
                errorMessage = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
            }
        }
    }

    private func hydrateCache(query: String, generation: Int) async {
        let rows = await cache.loadSection(Self.cacheSection)
        guard let payload = rows.first?.payload,
              let cached = try? JSONDecoder().decode(CachedSearch.self, from: payload),
              cached.query.caseInsensitiveCompare(query) == .orderedSame,
              generation == self.generation,
              completedNetworkGeneration != generation else { return }
        results = cached.tracks
        isShowingCachedResults = !cached.tracks.isEmpty
    }

    private func persistCache(query: String) async {
        guard let payload = try? JSONEncoder().encode(CachedSearch(query: query, tracks: results)) else { return }
        await cache.replaceSection(Self.cacheSection, rows: [.init(id: query, payload: payload)])
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, resultsCursor.canLoadMore,
              let page = resultsCursor.lastPage else { return }

        let issued = generation

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = try await api.getNextPage(page)
            guard issued == generation else { return }
            resultsCursor.advance(to: next)
            results.appendUnique(contentsOf: next.collection)
        } catch {
            print("Search load-more error: \(error)")
        }
    }
}
