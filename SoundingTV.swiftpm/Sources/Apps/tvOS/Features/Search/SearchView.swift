import SwiftUI

private let gridColumns: [GridItem] = Array(repeating: .init(.flexible(), spacing: Space.gutter), count: 5)
private let browseColumns: [GridItem] = Array(repeating: .init(.flexible(), spacing: Space.gutter), count: 4)

struct SearchView: View {
    @StateObject private var model = UnifiedSearchModel()
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var authService: AuthenticationService
    @FocusState private var focus: Focus?
    @State private var destination: SearchHit?
    @State private var browseQuery: String?

    private enum Focus: Hashable { case firstBrowseTile }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(item: $destination) { hit in
                    switch hit {
                    case .artist(let user): ArtistDetailView(user: user)
                    case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
                    case .track: EmptyView()
                    }
                }
        }
        .onExitCommand(perform: browseExit)
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                if model.isSearching {
                    TVGlassTabs(
                        options: SearchScope.allCases.map { .init(value: $0, title: $0.title) },
                        selection: $model.scope
                    )
                    .padding(.horizontal, SCBrowseMetrics.pageInset)
                    resultsState
                } else {
                    idleState
                }
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.bottom, Space.gutter)
        }
        .scrollClipDisabled()
        .defaultFocus($focus, .firstBrowseTile)
        .searchable(text: $model.query, prompt: "Artists, sets and tracks")
        .searchSuggestions {
            ForEach(model.suggestions, id: \.self) { suggestion in
                Text(suggestion).searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { model.rememberCurrentQuery() }
        .onAppear {
            DispatchQueue.main.async { focus = .firstBrowseTile }
            applyPendingQuery()
            #if DEBUG
            if VisualFixtures.isEnabled, let query = ProcessInfo.processInfo.environment["SOUNDING_TV_UI_SEARCH"], model.query.isEmpty {
                model.search(query)
            }
            #endif
        }
        .onChange(of: navigationState.pendingSearchQuery) { _, _ in applyPendingQuery() }
    }

    private func browse(_ query: String) {
        browseQuery = query
        model.search(query)
    }

    private var browseExit: (() -> Void)? {
        guard destination == nil, let browseQuery, model.isSearching, model.query == browseQuery else { return nil }
        return {
            self.browseQuery = nil
            model.search("")
            DispatchQueue.main.async { focus = .firstBrowseTile }
        }
    }

    private func applyPendingQuery() {
        guard let query = navigationState.pendingSearchQuery else { return }
        navigationState.pendingSearchQuery = nil
        model.search(query)
    }

    // MARK: - States

    @ViewBuilder
    private var resultsState: some View {
        let results = model.results
        if !results.isEmpty {
            resultsSections(results)
        } else if model.phase == .failed {
            ContentUnavailableView {
                Label("Couldn’t Search SoundCloud", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check this Apple TV’s network connection.")
            } actions: {
                Button("Try Again") { model.retry() }
            }
            .frame(maxWidth: .infinity, minHeight: 520)
        } else if model.phase == .searching || model.isRemoteLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 520)
                .accessibilityLabel("Searching")
        } else if model.scope == .library {
            ContentUnavailableView {
                Label("Nothing in Your Library", systemImage: "music.note.list")
            } description: {
                Text("Try All to search SoundCloud too.")
            }
            .frame(maxWidth: .infinity, minHeight: 520)
        } else {
            ContentUnavailableView.search(text: model.trimmedQuery)
                .frame(maxWidth: .infinity, minHeight: 520)
        }
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
            if !model.recents.isEmpty {
                section("Recently Searched") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Space.base) {
                            ForEach(model.recents) { entry in
                                RecentSearchRow(entry: entry) { model.search(entry.query) }
                                    .frame(width: 560)
                                    .contextMenu {
                                        Button("Remove", systemImage: "xmark", role: .destructive) { model.removeRecent(entry) }
                                        Button("Clear Recent Searches", systemImage: "trash", role: .destructive) { model.clearRecents() }
                                    }
                            }
                        }
                        .padding(.horizontal, SCBrowseMetrics.pageInset)
                    }
                    .scrollClipDisabled()
                }
            }
            section("Browse") {
                LazyVGrid(columns: browseColumns, spacing: Space.gutter) {
                    ForEach(Array(SearchVibe.all.enumerated()), id: \.offset) { index, vibe in
                        let tile = VibeTileButton(vibe: vibe) { browse(vibe.query) }
                        if index == 0 {
                            tile.focused($focus, equals: .firstBrowseTile)
                        } else {
                            tile
                        }
                    }
                }
                .padding(.horizontal, SCBrowseMetrics.pageInset)
            }
        }
    }

    // MARK: - Results

    private func resultsSections(_ results: SearchResults) -> some View {
        let queue = results.playableTracks
        return LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
            if let top = results.topResult {
                section("Top Result") {
                    TopResultCard(hit: top, reason: results.topReason) { open(top, queue: queue) }
                        .padding(.horizontal, SCBrowseMetrics.pageInset)
                }
            }
            if !results.library.isEmpty {
                section("In Your Library") {
                    shelf(results.library) { hit in
                        SearchHitCard(hit: hit.hit, caption: hit.reason.title) { open(hit.hit, queue: queue) }
                    }
                }
            }
            if !results.tracks.isEmpty {
                section("Tracks") { trackGrid(results.tracks, queue: queue) }
            }
            if !results.sets.isEmpty {
                section("Sets") { trackGrid(results.sets, queue: queue) }
            }
            if !results.artists.isEmpty {
                section("Artists") {
                    shelf(results.artists) { user in
                        SearchHitCard(hit: .artist(user), caption: "\(user.formattedFollowers) followers") { open(.artist(user), queue: queue) }
                    }
                }
            }
            if !results.playlists.isEmpty {
                section("Playlists") {
                    shelf(results.playlists) { playlist in
                        SearchHitCard(hit: .playlist(playlist), caption: playlist.user.displayName) { open(.playlist(playlist), queue: queue) }
                    }
                }
            }
        }
        .prefetchArtwork(Array(queue.prefix(20)).compactMap(\.artworkURL))
    }

    private func trackGrid(_ tracks: [Track], queue: [Track]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: Space.gutter) {
            ForEach(tracks) { track in
                SearchHitCard(hit: .track(track), caption: track.user.displayName) { open(.track(track), queue: queue) }
                    .contextMenu { TVTrackMenuItems(track: track) }
            }
        }
        .padding(.horizontal, SCBrowseMetrics.pageInset)
        .focusSection()
    }

    private func shelf<Item: Identifiable, Cell: View>(_ items: [Item], @ViewBuilder cell: @escaping (Item) -> Cell) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Space.gutter) {
                ForEach(items) { item in
                    cell(item).frame(width: 300)
                }
            }
            .padding(.horizontal, SCBrowseMetrics.pageInset)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: title, style: SCBrowseMetrics.header)
                .padding(.horizontal, SCBrowseMetrics.pageInset)
            content()
        }
        .focusSection()
    }

    private func open(_ hit: SearchHit, queue: [Track]) {
        model.rememberCurrentQuery()
        switch hit {
        case .track(let track):
            Task { await playerService.play(track, in: queue) }
        case .artist(let user) where user.id == authService.currentUser?.id:
            navigationState.showProfile()
        case .artist, .playlist:
            destination = hit
        }
    }
}

private struct TopResultCard: View {
    let hit: SearchHit
    let reason: SearchLibraryReason?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.roomy) {
                artwork
                    .frame(width: 280, height: 280)
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(hit.title)
                        .font(.tvTitle)
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.base)
            .frame(maxWidth: 1100, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Corner.hero, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.hero, sizeClass: .hero))
        .focusEffectDisabled()
        .accessibilityLabel("\(hit.title), \(subtitle)")
    }

    @ViewBuilder
    private var artwork: some View {
        switch hit {
        case .artist(let user):
            ArtworkImage(url: user.largeAvatarURL ?? user.avatarURL, icon: "person.fill", identity: user.id)
                .clipShape(Circle())
        case .track(let track):
            ArtworkImage(url: track.largeArtworkURL ?? track.artworkURL, identity: track.id)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        case .playlist(let playlist):
            ArtworkImage(url: playlist.displayArtworkURL, icon: "music.note.list", identity: playlist.id)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        }
    }

    private var subtitle: String {
        var parts: [String]
        switch hit {
        case .artist(let user): parts = [user.kindLabel, user.followerCountText]
        case .track(let track): parts = [track.duration >= SettingsStore.shared.setMinimumDurationSeconds ? "Set" : "Track", track.user.displayName]
        case .playlist(let playlist): parts = [playlist.isAlbum ? "Album" : "Playlist", playlist.user.displayName]
        }
        if let reason { parts.append(reason.title) }
        return parts.joined(separator: " · ")
    }
}

private struct SearchHitCard: View {
    let hit: SearchHit
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: hit.isArtist ? .center : .leading, spacing: Space.tight) {
                artwork
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: hit.isArtist ? .center : .leading, spacing: 0) {
                    Text(hit.title)
                        .font(.tvBodyEmph)
                        .foregroundStyle(Color.scTextPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: hit.isArtist ? .center : .leading)
            }
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: hit.isArtist ? Corner.hero : Corner.control, sizeClass: .card))
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel)
        .modifier(PrewarmIfTrack(track: hit.track))
    }

    @ViewBuilder
    private var artwork: some View {
        switch hit {
        case .artist(let user):
            ArtworkImage(url: user.avatarURL, icon: "person.fill", identity: user.id)
                .clipShape(Circle())
        case .track(let track):
            ArtworkImage(url: track.artworkURL, identity: track.id)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .kyleCrowned(user: track.user, context: track.title)
        case .playlist(let playlist):
            ArtworkImage(url: playlist.displayArtworkURL, icon: "music.note.list", identity: playlist.id)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        }
    }

    private var accessibilityLabel: String {
        if let track = hit.track {
            return TrackAccessibility.label(title: track.title, artist: track.user.displayName, duration: track.formattedDuration, isUnavailable: track.streamURL == nil)
        }
        return "\(hit.title), \(caption)"
    }
}

private struct PrewarmIfTrack: ViewModifier {
    let track: Track?

    func body(content: Content) -> some View {
        if let track {
            content.prewarmPlaybackOnFocus(track)
        } else {
            content
        }
    }
}

private extension SearchHit {
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}

private struct RecentSearchRow: View {
    let entry: RecentSearchEntry
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.base) {
                ArtworkImage(url: entry.avatarURL) {
                    Circle().fill(Color.scBgRaised)
                        .overlay(
                            Image(systemName: "magnifyingglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.scTextTertiary)
                        )
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.query)
                        .font(.tvBodyEmph)
                        .foregroundStyle(focused ? Color.scChromeFocusOn : Color.scTextPrimary)
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.tvCaption)
                        .foregroundStyle(focused ? Color.scChromeFocusOn.opacity(0.65) : Color.scTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.snug)
            .padding(.trailing, Space.roomy)
            .padding(.vertical, Space.snug)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.scChromeFocus)
                    .opacity(focused ? 1 : 0)
            }
            .liquidGlass(in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(style: .continuous), sizeClass: .card))
        .focused($focused)
        .accessibilityLabel("\(entry.query), \(entry.subtitle)")
    }
}

private struct VibeTileButton: View {
    let vibe: SearchVibe
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SearchVibeArtwork(vibe: vibe, cornerRadius: Corner.control)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
        .accessibilityLabel(vibe.title)
        .accessibilityHint("Searches for \(vibe.query)")
    }
}
