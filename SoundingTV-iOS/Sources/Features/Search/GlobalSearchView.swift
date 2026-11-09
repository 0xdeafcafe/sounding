import SwiftUI
import Combine

struct GlobalSearchView: View {
    @StateObject private var model = UnifiedSearchModel(scope: .soundCloud)
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var libraryInsights = LibrarySearchInsights()
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingSignIn = false
    @Namespace private var playlistNamespace

    static let prompt = "Artists, Tracks, Sets and More"

    private enum Mode: Hashable { case idle, searching }

    private var mode: Mode { model.isSearching ? .searching : .idle }

    var body: some View {
        ZStack {
            if model.isSearching {
                SearchResultsList(
                    model: model,
                    libraryInsights: libraryInsights,
                    confirmation: confirmation,
                    playlistNamespace: playlistNamespace,
                    signIn: { isShowingSignIn = true }
                )
                .transition(.opacity)
            } else {
                SearchIdlePage(model: model, confirmation: confirmation, playlistNamespace: playlistNamespace)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : SearchMotion.state, value: mode)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Self.prompt)
        .searchSuggestions {
            ForEach(model.suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass").searchCompletion(suggestion)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IdentifySongToolbarButton()
            }
        }
        .modifier(SearchScopeControl(scope: $model.scope))
        .sensoryFeedback(.selection, trigger: model.scope)
        .sensoryFeedback(.selection, trigger: model.filter)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: model.query) { _, text in libraryInsights.update(query: text) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
            model.reloadRecents()
        }
        .task { await credentials.prepareStoreAtLaunch() }
        .queueConfirmationOverlay(confirmation)
        .onAppear {
            model.reloadRecents()
            if let query = SearchRequestRouter.shared.consume() { model.search(query) }
        }
        .onReceive(SearchRequestRouter.shared.$pendingQuery.compactMap { $0 }) { query in
            model.search(query)
            SearchRequestRouter.shared.handled(query)
        }
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    credentials.refreshFromStore()
                    model.retry()
                }
            }
        }
        #if DEBUG
        .onAppear {
            if VisualFixtures.isEnabled, let query = ProcessInfo.processInfo.environment["SOUNDING_TV_UI_SEARCH"], model.query.isEmpty {
                model.search(query)
            }
        }
        #endif
    }
}

private struct SearchScopeControl: ViewModifier {
    @Binding var scope: SearchScope

    func body(content: Content) -> some View {
        if PadLayout.isPad {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Search In", selection: $scope) {
                        ForEach(SearchScope.browsable) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        } else {
            content.searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(SearchScope.browsable) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        }
    }
}

// MARK: - Idle

private struct SearchIdlePage: View {
    @ObservedObject var model: UnifiedSearchModel
    @ObservedObject var confirmation: QueueConfirmationController
    let playlistNamespace: Namespace.ID

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    private var isWide: Bool { PadLayout.isPad && width > 600 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PhoneLayout.shelfGap) {
                if !model.recents.isEmpty {
                    recentsSection
                        .transition(.opacity)
                }
                categoriesSection
            }
            .padding(.horizontal, PhoneLayout.margin)
            .padding(.top, Space.tight)
            .padding(.bottom, Space.section)
            .animation(reduceMotion ? nil : SearchMotion.state, value: model.recents.map(\.id))
        }
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Recently Searched

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: PhoneLayout.headerGap) {
            HStack(alignment: .firstTextBaseline) {
                PhoneSectionTitle(title: "Recently Searched")
                Spacer()
                Button("Clear") {
                    withAnimation(reduceMotion ? nil : SearchMotion.state) { model.clearRecents() }
                }
                .font(.subheadline)
            }
            if isWide && !dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: PhoneLayout.tileGap)], alignment: .leading, spacing: Space.tight) {
                    ForEach(model.recents) { entry in
                        recentCard(entry)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.recents.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().padding(.leading, 48 + Space.snug)
                        }
                        recentCard(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentCard(_ entry: RecentSearchEntry) -> some View {
        let card = SearchRecentCard(entry: entry)
            .contentShape(.hoverEffect, .rect(cornerRadius: 10, style: .continuous))
            .hoverEffect(.highlight)
        Group {
            switch model.recentHits[entry.id] {
            case .artist(let user)?:
                NavigationLink(value: user) {
                    card
                }
                .libraryTilePreviewShape()
                .simultaneousGesture(TapGesture().onEnded { model.remember(.artist(user)) })
            case .playlist(let playlist)?:
                PlaylistLink(playlist, heroNamespace: playlistNamespace, onOpen: { model.remember(.playlist(playlist)) }) {
                    card
                }
                .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
                .libraryTilePreviewShape()
            case .track(let track)?:
                Button {
                    model.remember(.track(track))
                    Task {
                        if let message = await coordinator.play(track, in: [track]) {
                            confirmation.show(message, icon: "exclamationmark.triangle.fill")
                        }
                    }
                } label: {
                    card
                }
                .disabled(track.streamURL == nil)
            case nil:
                Button {
                    model.search(entry.query)
                } label: {
                    card
                }
                .accessibilityHint("Searches again")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(reduceMotion ? nil : SearchMotion.state) { model.removeRecent(entry) }
            } label: {
                Label("Remove from Recently Searched", systemImage: "minus.circle")
            }
        }
    }

    // MARK: Browse Categories

    private var categoryColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        let available = max(width - PhoneLayout.margin * 2, 0)
        let count = PadLayout.isPad ? min(5, max(2, Int((available + PhoneLayout.tileGap) / (170 + PhoneLayout.tileGap)))) : 2
        return Array(repeating: GridItem(.flexible(), spacing: PhoneLayout.tileGap), count: count)
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: PhoneLayout.headerGap) {
            PhoneSectionTitle(title: "Browse Categories")
            LazyVGrid(columns: categoryColumns, spacing: PhoneLayout.tileGap) {
                ForEach(SearchCategory.all) { category in
                    NavigationLink(value: category) {
                        SearchCategoryTile(category: category)
                            .contentShape(.hoverEffect, .rect(cornerRadius: 12, style: .continuous))
                            .hoverEffect(.lift)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Results

private struct SearchResultsList: View {
    @ObservedObject var model: UnifiedSearchModel
    @ObservedObject var libraryInsights: LibrarySearchInsights
    @ObservedObject var confirmation: QueueConfirmationController
    let playlistNamespace: Namespace.ID
    let signIn: () -> Void

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let artworkLookahead = 10

    var body: some View {
        let items = model.visibleItems
        let queue = items.compactMap(\.hit.track)
        List {
            if model.filter == .top {
                askLibrarySections
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, queue: queue)
                    .onAppear {
                        model.loadMoreIfNeeded(after: item)
                        let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                        ArtworkCache.shared.prefetch(lookahead.compactMap(\.hit.artworkURL), variant: .thumbnail)
                    }
            }
            if model.isPaging {
                LoadingMoreRow()
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, Space.page, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .animation(reduceMotion ? nil : SearchMotion.state, value: items.map(\.id))
        .safeAreaBar(edge: .top) {
            SearchFilterPills(selection: $model.filter, filters: model.availableFilters, horizontalInset: PhoneLayout.margin)
                .padding(.vertical, Space.hair)
        }
        .overlay {
            if items.isEmpty, !showsAskLibrary, !showsVibe {
                emptyState
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.phase == .failed, model.scope.includesSoundCloud {
            if credentials.needsSignIn {
                LoadFailureView(failure: LoadFailure.credentialFailure(), subject: "search results", action: signIn)
            } else {
                ContentUnavailableView {
                    Label("Couldn’t Search SoundCloud", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { model.retry() }
                }
            }
        } else if model.phase == .searching || (model.scope.includesSoundCloud && (model.isRemoteLoading || model.isPaging)) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Searching")
        } else if model.scope == .library {
            ContentUnavailableView {
                Label("Nothing in Your Library", systemImage: "music.note.list")
            } description: {
                Text("Try SoundCloud to search everything.")
            } actions: {
                Button("Search SoundCloud") { model.scope = .soundCloud }
            }
        } else {
            ContentUnavailableView.search(text: model.trimmedQuery)
        }
    }

    @ViewBuilder
    private func row(_ item: SearchResultItem, queue: [Track]) -> some View {
        switch item.hit {
        case .track(let track):
            TrackListRow(track: track, analysis: nil, context: { queue }, confirmation: confirmation)
                .environment(\.trackRowShowsType, true)
                .simultaneousGesture(TapGesture().onEnded { model.remember(item.hit) })
        case .artist(let user):
            NavigationLink(value: user) {
                SearchResultRowLabel(item: item)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + 12 }
            .libraryRowPreviewShape()
            .contextMenu { UserContextMenu(user: user) }
            .simultaneousGesture(TapGesture().onEnded { model.remember(item.hit) })
        case .playlist(let playlist):
            PlaylistLink(playlist, heroNamespace: playlistNamespace, isListRow: true, onOpen: { model.remember(item.hit) }) {
                SearchResultRowLabel(item: item)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + 12 }
            .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
            .libraryRowPreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
        }
    }

    private var showsAskLibrary: Bool {
        model.filter == .top && model.scope.includesLibrary && LibrarySearchInsights.canAskLibrary && LibraryQuestionHeuristics.looksLikeQuestion(model.trimmedQuery)
    }

    private var showsVibe: Bool {
        model.filter == .top && model.scope.includesLibrary && !libraryInsights.vibeTracks.isEmpty
    }

    @ViewBuilder
    private var askLibrarySections: some View {
        if showsAskLibrary {
            Section {
                switch libraryInsights.question {
                case .idle:
                    Button {
                        libraryInsights.ask(model.trimmedQuery)
                    } label: {
                        Label("Ask Your Library", systemImage: "sparkles")
                    }
                case .asking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching your library…").foregroundStyle(.secondary)
                    }
                case .noAnswer:
                    Text("Nothing in your library matches.").foregroundStyle(.secondary)
                case .answered(let text, let tracks):
                    if !text.isEmpty {
                        Label(text, systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tracks.prefix(10)) { track in
                        TrackListRow(track: track, analysis: nil, context: { Array(tracks.prefix(10)) }, confirmation: confirmation)
                    }
                }
            } header: {
                PhoneSectionTitle(title: "Ask Your Library")
            }
            .headerProminence(.increased)
        }
        if showsVibe {
            Section {
                ForEach(libraryInsights.vibeTracks.prefix(5)) { track in
                    VStack(alignment: .leading, spacing: 6) {
                        TrackListRow(
                            track: track, analysis: nil,
                            context: { Array(libraryInsights.vibeTracks.prefix(5)) },
                            confirmation: confirmation
                        )
                        GeneratedTagChips(tags: GeneratedInsightsService.shared.insights(for: track.id)?.tags ?? [], font: .caption)
                    }
                }
            } header: {
                PhoneSectionTitle(title: "Matching Vibe in Your Likes")
            }
            .headerProminence(.increased)
        }
    }
}

// MARK: - Category page

struct SearchCategoryView: View {
    let category: SearchCategory

    @StateObject private var model: SearchCategoryModel
    @StateObject private var confirmation = QueueConfirmationController()
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    init(category: SearchCategory) {
        self.category = category
        _model = StateObject(wrappedValue: SearchCategoryModel(category: category))
    }

    var body: some View {
        content
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if model.state == .loaded {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Play", systemImage: "play.fill") { play(shuffled: false) }
                        Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
                    }
                }
            }
            .task { await model.load() }
            .queueConfirmationOverlay(confirmation)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load \(category.title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.load(force: true) } }
            }
        case .empty:
            ContentUnavailableView(
                "Nothing Here Yet",
                systemImage: "music.note",
                description: Text("Nothing is trending in \(category.title) right now.")
            )
        case .loaded:
            List {
                ForEach(model.tracks) { track in
                    TrackListRow(track: track, analysis: nil, context: { model.tracks }, confirmation: confirmation)
                }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, Space.page, for: .scrollContent)
            .prefetchArtwork(model.tracks.prefix(20).compactMap(\.artworkURL), variant: .thumbnail)
        }
    }

    private func play(shuffled: Bool) {
        let playable = model.tracks.filter { $0.streamURL != nil }
        let queue = shuffled ? playable.shuffled() : playable
        guard let first = queue.first else { return }
        Task {
            if let message = await coordinator.play(first, in: queue) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }
}
