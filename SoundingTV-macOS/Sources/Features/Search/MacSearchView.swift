import SwiftUI
import AppKit
import Combine

typealias MacSearchModel = UnifiedSearchModel

struct MacSearchView: View {
    @ObservedObject private var model: MacSearchModel
    @ObservedObject private var findFocus = MacFindFocus.shared
    @State private var isSearchPresented = false
    @StateObject private var libraryInsights = LibrarySearchInsights()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let prompt = "Artists, Tracks, Sets and More"

    init(model: MacSearchModel) {
        self.model = model
    }

    var body: some View {
        ZStack {
            if model.isSearching {
                resultsList
                    .transition(.opacity)
            } else {
                idlePage
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : SearchMotion.state, value: model.isSearching)
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
        .navigationDestination(for: SearchCategory.self) { category in
            MacSearchCategoryView(category: category)
        }
        .navigationTitle("Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MacIdentifySongToolbarButton()
            }
        }
        .searchable(
            text: $model.query,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: Self.prompt
        )
        .searchSuggestions {
            if model.isSearching {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "magnifyingglass").searchCompletion(suggestion)
                }
            }
        }
        .onSubmit(of: .search) { dismissSearchFocus() }
        .onChange(of: model.query, initial: true) { _, text in
            libraryInsights.update(query: text)
        }
        .onExitCommand { dismissSearchFocus() }
        .safeAreaBar(edge: .top) {
            VStack(spacing: SCContentStyle.mac.spaceTight) {
                MacGlassTabs(
                    "Search in",
                    selection: $model.scope,
                    options: SearchScope.browsable,
                    title: \.title
                )
                .frame(maxWidth: .infinity)
                if model.isSearching {
                    SearchFilterPills(selection: $model.filter, filters: model.availableFilters, horizontalInset: 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, SCContentStyle.mac.spaceSnug)
            .padding(.bottom, SCContentStyle.mac.spaceTight)
            .animation(reduceMotion ? nil : SearchMotion.state, value: model.isSearching)
        }
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .background {
            MacSearchFocusDismissalMonitor(isSearchPresented: $isSearchPresented)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            if !SearchScope.browsable.contains(model.scope) { model.scope = .soundCloud }
            model.reloadRecents()
        }
        #if DEBUG
        .onAppear {
            if VisualFixtures.isEnabled, let query = ProcessInfo.processInfo.environment["SOUNDING_TV_UI_SEARCH"], model.query.isEmpty {
                model.search(query)
            }
        }
        #endif
    }

    private func dismissSearchFocus() {
        isSearchPresented = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Idle

    private static let categoryColumns = Array(
        repeating: GridItem(.flexible(), spacing: SCContentStyle.mac.spaceBase),
        count: 5
    )

    private var idlePage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SCContentStyle.mac.spaceGutter) {
                if !model.recents.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        SCSectionHeader(title: "Recently Searched", style: .mac)
                        Spacer()
                        Button("Clear") {
                            withAnimation(reduceMotion ? nil : SearchMotion.state) { model.clearRecents() }
                        }
                        .buttonStyle(.borderless)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: SCContentStyle.mac.spaceBase)], alignment: .leading, spacing: 4) {
                        ForEach(model.recents) { entry in
                            recentCard(entry)
                        }
                    }
                }
                SCSectionHeader(title: "Browse Categories", style: .mac)
                LazyVGrid(columns: Self.categoryColumns, spacing: SCContentStyle.mac.spaceBase) {
                    ForEach(SearchCategory.all) { category in
                        NavigationLink(value: category) {
                            SearchCategoryTile(category: category, cornerRadius: SCContentStyle.mac.cornerControl)
                        }
                        .buttonStyle(.plain)
                        .macHoverLift()
                        .help(category.title)
                    }
                }
            }
            .padding(20)
            .animation(reduceMotion ? nil : SearchMotion.state, value: model.recents.map(\.id))
        }
        .defaultScrollAnchor(.top, for: .alignment)
    }

    @ViewBuilder
    private func recentCard(_ entry: RecentSearchEntry) -> some View {
        let card = SearchRecentCard(entry: entry, thumbnailSize: 40)
            .padding(.horizontal, 6)
        Group {
            switch model.recentHits[entry.id] {
            case .artist(let user)?:
                Button {
                    model.remember(.artist(user))
                    MacRootSelection.shared.request(artist: user)
                } label: {
                    card
                }
            case .playlist(let playlist)?:
                NavigationLink(value: playlist) {
                    card
                }
                .simultaneousGesture(TapGesture().onEnded { model.remember(.playlist(playlist)) })
            case .track(let track)?:
                Button {
                    model.remember(.track(track))
                    Task { await MacPlayback.play(track, in: [track]) }
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
            }
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight(cornerRadius: 8)
        .contextMenu {
            Button("Remove from Recently Searched", systemImage: "minus.circle") {
                withAnimation(reduceMotion ? nil : SearchMotion.state) { model.removeRecent(entry) }
            }
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        let items = model.visibleItems
        let queue = items.compactMap(\.hit.track)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.filter == .top {
                    if showsAskLibrary {
                        askLibrarySection
                            .padding(.bottom, SCContentStyle.mac.spaceSection)
                    }
                    if showsVibe {
                        vibeSection
                            .padding(.bottom, SCContentStyle.mac.spaceSection)
                    }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 48 + 12 + 8)
                    }
                    MacSearchResultRow(item: item, queue: queue) { model.remember(item.hit) }
                        .onAppear { model.loadMoreIfNeeded(after: item) }
                }
                if model.isPaging {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .animation(reduceMotion ? nil : SearchMotion.state, value: items.map(\.id))
        }
        .contentMargins(.bottom, 12, for: .scrollContent)
        .defaultScrollAnchor(.top, for: .alignment)
        .prefetchArtwork(items.prefix(30).compactMap(\.hit.artworkURL), variant: .thumbnail)
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
            ContentUnavailableView {
                Label("Couldn’t Search SoundCloud", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your network connection.")
            } actions: {
                Button("Try Again") { model.retry() }
            }
            .macFillsPane()
        } else if model.phase == .searching || (model.scope.includesSoundCloud && (model.isRemoteLoading || model.isPaging)) {
            ProgressView()
                .controlSize(.large)
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
            .macFillsPane()
        } else {
            ContentUnavailableView.search(text: model.trimmedQuery)
                .macFillsPane()
        }
    }

    private var showsAskLibrary: Bool {
        model.filter == .top && model.scope.includesLibrary && LibrarySearchInsights.canAskLibrary && LibraryQuestionHeuristics.looksLikeQuestion(model.trimmedQuery)
    }

    private var showsVibe: Bool {
        model.filter == .top && model.scope.includesLibrary && !libraryInsights.vibeTracks.isEmpty
    }

    private static let songColumns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]

    @ViewBuilder
    private var askLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch libraryInsights.question {
            case .idle:
                Button {
                    libraryInsights.ask(model.trimmedQuery)
                } label: {
                    Label("Ask Your Library", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
            case .asking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your library…").foregroundStyle(.secondary)
                }
            case .noAnswer:
                Text("Nothing in your library matches.").foregroundStyle(.secondary)
            case .answered(let text, let tracks):
                if !text.isEmpty {
                    Label(text, systemImage: "sparkles").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Self.songColumns, alignment: .leading, spacing: 2) {
                    ForEach(tracks.prefix(10)) { track in
                        SongRow(track: track, context: Array(tracks.prefix(10)))
                    }
                }
            }
        }
    }

    private var vibeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader(title: "Matching Vibe in Your Likes", style: .mac)
            LazyVGrid(columns: Self.songColumns, alignment: .leading, spacing: 8) {
                ForEach(libraryInsights.vibeTracks.prefix(6)) { track in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRow(track: track, context: Array(libraryInsights.vibeTracks.prefix(6)))
                        GeneratedTagChips(tags: GeneratedInsightsService.shared.insights(for: track.id)?.tags ?? [], font: .caption)
                    }
                }
            }
        }
    }
}

private struct MacSearchResultRow: View {
    let item: SearchResultItem
    let queue: [Track]
    let onOpen: () -> Void

    var body: some View {
        switch item.hit {
        case .track(let track):
            HStack(spacing: 8) {
                Button {
                    onOpen()
                    Task { await MacPlayback.play(track, in: queue) }
                } label: {
                    SearchResultRowLabel(item: item, thumbnailSize: 48)
                }
                .buttonStyle(.plain)
                .disabled(track.streamURL == nil)
                Menu {
                    MacTrackContextMenu(track: track, context: queue)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More for \(track.title)")
            }
            .padding(.horizontal, 8)
            .macHoverRowHighlight(cornerRadius: 8)
            .opacity(track.streamURL == nil ? 0.5 : 1)
            .help(track.streamURL == nil ? "Not playable on this account" : "Play")
            .contextMenu { MacTrackContextMenu(track: track, context: queue) }
        case .artist(let user):
            Button {
                onOpen()
                MacRootSelection.shared.request(artist: user)
            } label: {
                navigable
            }
            .buttonStyle(.plain)
            .macHoverRowHighlight(cornerRadius: 8)
            .contextMenu { MacArtistContextMenu(artist: user) }
        case .playlist(let playlist):
            NavigationLink(value: playlist) {
                navigable
            }
            .buttonStyle(.plain)
            .macHoverRowHighlight(cornerRadius: 8)
            .simultaneousGesture(TapGesture().onEnded { onOpen() })
            .contextMenu { MacPlaylistContextMenu(playlist: playlist) }
        }
    }

    private var navigable: some View {
        HStack(spacing: 8) {
            SearchResultRowLabel(item: item, thumbnailSize: 48)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

private struct MacSearchCategoryView: View {
    let category: SearchCategory

    @StateObject private var model: SearchCategoryModel

    init(category: SearchCategory) {
        self.category = category
        _model = StateObject(wrappedValue: SearchCategoryModel(category: category))
    }

    var body: some View {
        content
            .navigationTitle(category.title)
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load \(category.title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your network connection.")
            } actions: {
                Button("Try Again") { Task { await model.load(force: true) } }
            }
            .macFillsPane()
        case .empty:
            ContentUnavailableView(
                "Nothing Here Yet",
                systemImage: "music.note",
                description: Text("Nothing is trending in \(category.title) right now.")
            )
            .macFillsPane()
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Button("Play", systemImage: "play.fill") { play(shuffled: false) }
                            .buttonStyle(.glassProminent)
                        Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
                            .buttonStyle(.glass)
                    }
                    .padding(.bottom, 12)
                    ForEach(model.tracks) { track in
                        SongRow(track: track, context: model.tracks)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.top, for: .alignment)
            .prefetchArtwork(model.tracks.prefix(20).compactMap(\.artworkURL))
        }
    }

    private func play(shuffled: Bool) {
        let playable = model.tracks.filter { $0.streamURL != nil }
        let queue = shuffled ? playable.shuffled() : playable
        guard let first = queue.first else { return }
        Task { await MacPlayback.play(first, in: queue) }
    }
}

private struct MacSearchFocusDismissalMonitor: NSViewRepresentable {
    @Binding var isSearchPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            window: nsView.window,
            isSearchPresented: $isSearchPresented
        )
        if nsView.window == nil {
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                coordinator?.update(
                    window: nsView?.window,
                    isSearchPresented: $isSearchPresented
                )
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var isSearchPresented: Binding<Bool>?
        private var eventMonitor: Any?

        func update(window: NSWindow?, isSearchPresented: Binding<Bool>) {
            self.isSearchPresented = isSearchPresented
            guard self.window !== window else { return }
            stop()
            self.window = window
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window != nil,
                      self.isSearchPresented?.wrappedValue == true else { return event }

                if event.window === window,
                   Self.isInsideSearchField(event, in: window) {
                    return event
                }

                DispatchQueue.main.async { [weak self, weak window] in
                    self?.isSearchPresented?.wrappedValue = false
                    window?.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            window = nil
        }

        private static func isInsideSearchField(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let root = window.contentView?.superview else { return false }
            let point = root.convert(event.locationInWindow, from: nil)
            var hitView = root.hitTest(point)
            while let view = hitView {
                if view is NSSearchField { return true }
                hitView = view.superview
            }
            return false
        }
    }
}

private struct SongRow: View {
    let track: Track
    let context: [Track]
    var caption: String? = nil

    private var isPlayable: Bool { track.streamURL != nil }

    @State private var artwork: NSImage?

    private var displayedArtwork: NSImage? {
        if let artwork { return artwork }
        guard let url = track.artworkURL else { return nil }
        return ArtworkCache.shared.cachedImage(for: url, variant: .standard)
    }

    var body: some View {
        Button {
            guard isPlayable else { return }
            Task { await MacPlayback.play(track, in: context) }
        } label: {
            SCTrackRow(
                title: track.title,
                subtitle: caption ?? track.user.displayName,
                artworkImage: displayedArtwork.map { Image(nsImage: $0) },
                artIdentity: track.id,
                isAvailable: isPlayable,
                crownUser: track.user,
                crownContext: track.title,
                style: .mac
            ) {
                Menu {
                    MacTrackContextMenu(track: track, context: context)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .macHoverRowHighlight()
        .help(isPlayable ? "Play" : "Not playable on this account")
        .macTrackAccessibility(track: track, context: context)
        .trackDragSource(track)
        .contextMenu { MacTrackContextMenu(track: track, context: context) }
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

