import SwiftUI

extension SoundCloudSectionGate {
    init(section: LibraryBrowserViewModel.Section, @ViewBuilder content: @escaping () -> Content) {
        self.init(section.signInTopic, content: content)
    }
}

extension LibraryBrowserViewModel.Section {
    var signInTopic: SoundCloudSignInTopic {
        switch self {
        case .likes: .likes
        case .sets: .sets
        case .playlists: .playlists
        case .following: .following
        }
    }
}

extension View {
    func soundCloudSignIn(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isPresented.wrappedValue = false
                    SoundCloudCredentialSource.shared.refreshFromStore()
                }
            }
        }
    }
}

private struct ShowsTrackSourceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsTrackSource: Bool {
        get { self[ShowsTrackSourceKey.self] }
        set { self[ShowsTrackSourceKey.self] = newValue }
    }
}

struct TrackSourceMark: View {
    let track: Track

    @ObservedObject private var identity = LibraryIdentity.shared

    var body: some View {
        LibrarySourceMarks(sources: identity.index.sources(of: track))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

struct LibrarySongsView: View {
    @ObservedObject var viewModel: LibraryBrowserViewModel
    @ObservedObject var analysisStore: TrackAnalysisStore
    @ObservedObject var confirmation: QueueConfirmationController

    @ObservedObject private var library = LocalMusicLibrary.shared
    @ObservedObject private var identity = LibraryIdentity.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("library.songs.query") private var query = TrackCollectionQuery.newestFirst
    @AppStorage(trackListColumns: "songs") private var showsColumns: Bool
    @State private var searchText = ""
    @State private var isAdding = false
    @State private var isShowingSignIn = false
    @State private var memo = Memo()

    private final class Memo {
        var key: Key?
        var all: [Track] = []
        var rows: [Track] = []
    }

    private struct Key: Equatable {
        let likesRevision: Int
        let identityGeneration: Int
        let localCount: Int
        let localFirst: String?
        let hasSoundCloud: Bool
        let query: TrackCollectionQuery
        let needle: String
        let analysisRevision: Int
        let downloadsCount: Int
    }

    private var hasSoundCloud: Bool { credentials.showsSoundCloudLibrary }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsColumnHeader: Bool {
        showsColumns && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private func dateAdded(_ track: Track) -> Date {
        viewModel.likedAtByTrackID[track.id] ?? track.createdAt
    }

    private func derived() -> (all: [Track], rows: [Track]) {
        let local = library.allTracks
        let key = Key(
            likesRevision: hasSoundCloud ? viewModel.likesPager.revision : -1,
            identityGeneration: identity.index.generation,
            localCount: local.count,
            localFirst: local.first?.id,
            hasSoundCloud: hasSoundCloud,
            query: query,
            needle: trimmedSearch,
            analysisRevision: analysisStore.revision,
            downloadsCount: query.isFiltering ? downloads.states.count : 0
        )
        if memo.key == key { return (memo.all, memo.rows) }
        var all = local
        if hasSoundCloud {
            let localIDs = Set(local.map(\.id))
            all += viewModel.likedTracks.filter { liked in
                !localIDs.contains(liked.id) && identity.index.localCopy(of: liked).map { localIDs.contains($0.id) } != true
            }
        }
        let rows = TrackCollection.apply(
            all,
            query: query,
            search: trimmedSearch,
            analysis: analysisStore.summaries,
            context: TrackCollectionLoader.context(),
            dateAdded: dateAdded
        )
        memo.key = key
        memo.all = all
        memo.rows = rows
        return (all, rows)
    }

    private var filters: [TrackFilter] {
        hasSoundCloud ? TrackFilter.allCases : TrackFilter.allCases.filter { $0 != .soundCloud && $0 != .previews }
    }

    var body: some View {
        let derived = derived()
        content(all: derived.all, rows: derived.rows)
            .navigationTitle("Tracks")
            .navigationSubtitle(derived.all.isEmpty ? "" : LocalMusicFormat.trackCount(derived.all.count))
            .libraryPageTitleDisplayMode()
            .libraryPageSearchable(text: $searchText, prompt: "Search Tracks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TrackCollectionMenu(
                        query: $query,
                        showsColumns: $showsColumns,
                        sortKeys: TrackCollection.availableSortKeys(for: derived.all, analysis: analysisStore.summaries),
                        filters: filters
                    )
                }
            }
            .task(id: hasSoundCloud) {
                guard hasSoundCloud else { return }
                await viewModel.loadContent(for: .likes)
            }
            .task(id: derived.all.count) { await analysisStore.load(for: derived.all) }
            .onChange(of: library.folders, initial: true) { _, folders in
                for folder in folders { PlaybackQueueSourceDirectory.note(library.queueSource(for: folder)) }
            }
            .addMusicFolderImporter(isPresented: $isAdding)
            .queueConfirmationOverlay(confirmation)
            .sheet(isPresented: $isShowingSignIn) {
                NavigationStack {
                    SoundCloudLoginView.standalone {
                        isShowingSignIn = false
                        credentials.refreshFromStore()
                    }
                }
            }
    }

    @ViewBuilder
    private func content(all: [Track], rows: [Track]) -> some View {
        if all.isEmpty {
            emptyState
        } else if rows.isEmpty {
            if trimmedSearch.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Tracks", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No tracks match these filters.")
                } actions: {
                    Button("Clear Filters") { query.clearFilters() }
                        .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView.search(text: trimmedSearch)
            }
        } else {
            List {
                Section {
                    if showsColumnHeader {
                        TrackColumnsHeader(
                            query: $query,
                            sortKeys: TrackCollection.availableSortKeys(for: all, analysis: analysisStore.summaries)
                        )
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, track in
                        TrackListRow(
                            track: track,
                            analysis: analysisStore.summaries[track.id],
                            context: { rows },
                            confirmation: confirmation
                        )
                        .onAppear {
                            if hasSoundCloud, trimmedSearch.isEmpty, rows.isNearEnd(track, lead: 10) {
                                viewModel.requestMore(section: .likes)
                            }
                            let lookahead = rows[index..<min(index + 10, rows.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL), variant: .thumbnail)
                            AnalysisSummaries.shared.request(lookahead)
                        }
                    }
                    UnanalysedTracksFooter(tracks: rows, sortKey: query.sortKey, summaries: analysisStore.summaries)
                    if hasSoundCloud, trimmedSearch.isEmpty {
                        PagedFooter(pager: viewModel.likesPager).listRowSeparator(.hidden)
                    }
                    if hasSoundCloud {
                        LibrarySyncStatusLine().listRowSeparator(.hidden)
                    }
                }
                .listSectionSeparator(.hidden, edges: .top)
            }
            .environment(\.trackSortKey, query.sortKey)
            .environment(\.showsTrackSource, true)
            .trackListColumns(showsColumns)
            .animation(.smooth, value: showsColumns)
            .listStyle(.plain)
            .refreshable { await refresh() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.scanningFolderIDs.isEmpty {
            LocalMusicScanningState()
        } else if hasSoundCloud, viewModel.state(for: .likes) == .loading {
            LibraryLoadingState()
        } else {
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note")
            } description: {
                Text(hasSoundCloud
                     ? "Add a folder of your own music, or like tracks on SoundCloud."
                     : "Add a folder of your own music, or connect SoundCloud.")
            } actions: {
                Button("Add Folder…") { isAdding = true }
                    .buttonStyle(.bordered)
                if !hasSoundCloud {
                    Button("Connect SoundCloud") { isShowingSignIn = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refresh() async {
        library.rescanAll()
        if hasSoundCloud { await viewModel.loadContent(for: .likes, forceRefresh: true) }
    }
}
