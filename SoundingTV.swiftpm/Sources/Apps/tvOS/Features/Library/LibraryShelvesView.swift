import SwiftUI

enum LibraryShelfMetrics {
    static let tileShelfHeight: CGFloat = SCBrowseMetrics.tileEdge + 96
    static let gridColumns = 6
    static let collectionColumns = 5
    static let shelfLimit = 24
}

enum LibraryPageMetrics {
    static let sidebarWidth: CGFloat = 360
    static let columnGap: CGFloat = 60
    static let rowHeight: CGFloat = 60
    static let embeddedColumns = 4
    static let pushedColumns = LibraryShelfMetrics.gridColumns

    static func grid(_ columns: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: SCBrowseMetrics.gutter, alignment: .top),
            count: max(1, columns)
        )
    }
}

private struct LibraryGridColumnsKey: EnvironmentKey {
    static let defaultValue = LibraryPageMetrics.pushedColumns
}

extension EnvironmentValues {
    var libraryGridColumns: Int {
        get { self[LibraryGridColumnsKey.self] }
        set { self[LibraryGridColumnsKey.self] = newValue }
    }
}

// MARK: - Split

struct LibrarySplitView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var page: LibraryFilter
    let openSocial: (SocialSection) -> Void

    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @FocusState private var focusedRow: LibraryFilter?
    @State private var focusedPage: LibraryFilter?

    private var pages: [LibraryFilter] {
        LibraryFilter.sidebarOrder.filter { $0 != .yourMusic || showsYourMusic }
    }

    private var showsYourMusic: Bool {
        remoteMusic.hasMusic || !remoteMusic.allTracks.isEmpty || !remoteMusic.loadingDeviceIds.isEmpty
    }

    private var current: LibraryFilter {
        pages.contains(page) ? page : .recentlyAdded
    }

    var body: some View {
        HStack(alignment: .top, spacing: LibraryPageMetrics.columnGap) {
            sidebar

            LibraryDetailView(filter: current, viewModel: viewModel)
                .id(current)
                .environment(\.libraryGridColumns, LibraryPageMetrics.embeddedColumns)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
                .onExitCommand { focusedRow = current }
        }
        .defaultFocus($focusedRow, current, priority: .userInitiated)
        .onAppear { remoteMusic.refreshIfNeeded() }
        .task {
            for filter in [LibraryFilter.likes, .playlists] {
                await viewModel.load(filter: filter)
            }
        }
    }

    private var sidebar: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.hair) {
                TVAccountMenu(open: openSocial)
                    .padding(.bottom, Space.base)
                ForEach(pages) { filter in
                    Button {
                        select(filter)
                    } label: {
                        LibrarySidebarLabel(filter: filter)
                    }
                    .buttonStyle(LibrarySidebarRowStyle(isSelected: filter == current))
                    .focused($focusedRow, equals: filter)
                    .accessibilityIdentifier("library.sidebar.\(filter.rawValue)")
                    .accessibilityAddTraits(filter == current ? [.isSelected] : [])
                }
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.bottom, Space.base)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .frame(width: LibraryPageMetrics.sidebarWidth)
        .focusSection()
        .defaultFocus($focusedRow, current, priority: .userInitiated)
        .onChange(of: focusedRow) { _, row in
            if let row { focusedPage = row }
        }
        .task(id: focusedPage) {
            guard let target = focusedPage, target != current else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            page = target
        }
    }

    private func select(_ filter: LibraryFilter) {
        focusedPage = filter
        page = filter
    }
}

private struct LibrarySidebarLabel: View {
    let filter: LibraryFilter

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: filter.icon)
                .font(.tvCalloutEmph)
                .frame(width: 44)
                .accessibilityHidden(true)
            Text(filter.label)
                .lineLimit(1)
        }
    }
}

struct LibrarySidebarRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSelected: isSelected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var fill: Color {
            if isFocused { return .scChromeFocus }
            return isSelected ? Color.white.opacity(0.14) : .clear
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
            configuration.label
                .font(isSelected ? .tvBodyEmph : .tvBody)
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .padding(.horizontal, Space.snug)
                .frame(maxWidth: .infinity, minHeight: LibraryPageMetrics.rowHeight, alignment: .leading)
                .background { shape.fill(fill) }
                .contentShape(shape)
                .scaleEffect(isFocused ? 1.04 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

// MARK: - Page

struct LibraryPageMessage {
    var kind: StatusPanel.Kind = .empty
    var icon: String
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    static func empty(_ filter: LibraryFilter) -> LibraryPageMessage {
        LibraryPageMessage(icon: filter.icon, title: filter.emptyTitle, message: filter.emptyMessage)
    }

    static func failure(_ filter: LibraryFilter, message: String, retry: @escaping () -> Void) -> LibraryPageMessage {
        LibraryPageMessage(
            kind: .error,
            icon: "exclamationmark.triangle",
            title: "Couldn't Load \(filter.label)",
            message: message,
            actionTitle: "Try Again",
            action: retry
        )
    }
}

enum LibraryPageState {
    case ready
    case loading(LoadingPlaceholderStyle)
    case message(LibraryPageMessage)
}

struct TVLibraryPage<Controls: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var showsSyncLine: Bool
    let state: LibraryPageState
    let controls: () -> Controls
    let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        showsSyncLine: Bool = false,
        state: LibraryPageState,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsSyncLine = showsSyncLine
        self.state = state
        self.controls = controls
        self.content = content
    }

    var body: some View {
        switch state {
        case .ready:
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.section) {
                    header(showsSyncLine: showsSyncLine)
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SCBrowseMetrics.contentTopInset)
                .padding(.bottom, Space.section)
            }
            .scrollClipDisabled()
        case .loading(let style):
            VStack(alignment: .leading, spacing: Space.section) {
                header(showsSyncLine: showsSyncLine)
                LoadingPlaceholder(style, showsSyncStatus: false, insets: false)
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .message(let message):
            VStack(alignment: .leading, spacing: Space.section) {
                header(showsSyncLine: showsSyncLine)
                StatusPanel(
                    kind: message.kind,
                    icon: message.icon,
                    title: message.title,
                    message: message.message,
                    actionTitle: message.actionTitle,
                    action: message.action,
                    minHeight: 0
                )
                .frame(maxHeight: .infinity)
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(showsSyncLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            LibraryDetailHeader(title: title, subtitle: subtitle, showsSyncLine: showsSyncLine)
            controls()
        }
    }
}

extension TVLibraryPage where Controls == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        showsSyncLine: Bool = false,
        state: LibraryPageState,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            showsSyncLine: showsSyncLine,
            state: state,
            controls: { EmptyView() },
            content: content
        )
    }
}

struct LibraryDetailHeader: View {
    let title: String
    let subtitle: String?
    var showsSyncLine = false

    @ObservedObject private var engine = LibrarySyncEngine.shared

    private var detailLine: String? {
        guard showsSyncLine else { return subtitle }
        let parts = [subtitle, engine.isBackfilling ? "Syncing…" : nil].compactMap { $0 }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(title)
                .font(.tvTitle)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let detailLine {
                Text(detailLine)
                    .font(.tvCallout)
                    .monospacedDigit()
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Likes

struct TVLikesPlaylistTile: View {
    var identifier = "library.playlists.likes"

    @EnvironmentObject private var navigationState: NavigationState

    var body: some View {
        Button {
            LibraryRouter.shared.open(.likes, navigationState: navigationState)
        } label: {
            LikesPlaylistCard(style: SCBrowseMetrics.tile)
                .frame(width: SCBrowseMetrics.tileEdge)
        }
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Shelf header

struct LibraryShelfHeader: View {
    let filter: LibraryFilter
    let count: String?

    var body: some View {
        NavigationLink(value: filter) {
            HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                Text(filter.label)
                    .font(SCBrowseMetrics.header.fontTitle)
                Image(systemName: "chevron.right")
                    .font(SCBrowseMetrics.header.fontTitle)
                    .imageScale(.small)
                if let count {
                    Text(count)
                        .font(.tvCallout)
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
        }
        .buttonStyle(LibraryChromeButtonStyle())
        .accessibilityIdentifier("library.shelf.\(filter.rawValue)")
        .accessibilityLabel([filter.label, count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

struct LibraryChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .padding(.horizontal, Space.base)
                .padding(.vertical, Space.tight)
                .background(isFocused ? Color.scChromeFocus : .clear, in: Capsule(style: .continuous))
                .padding(.leading, -Space.base)
                .scaleEffect(isFocused ? 1.05 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        }
    }
}

extension LibraryItem {
    var libraryShelfID: String {
        if let track { return "track:\(track.id)" }
        if let playlist { return "playlist:\(playlist.id)" }
        if let systemPlaylist { return "system:\(systemPlaylist.id)" }
        return "unknown:\(createdAt.timeIntervalSince1970)"
    }
}

// MARK: - Detail

struct LibraryDetailView: View {
    let filter: LibraryFilter
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.libraryGridColumns) private var columns

    var body: some View {
        Group {
            switch filter {
            case .recentlyAdded:
                RecentlyAddedTVGrid(
                    model: viewModel.recentlyAddedFeed,
                    isLoading: viewModel.isFirstPageLoading(filter),
                    error: viewModel.pageError(filter),
                    retry: retry
                )
            case .likes, .songs, .sets, .setlists, .downloads:
                LibraryTrackGrid(
                    filter: filter,
                    tracks: tracks,
                    total: viewModel.totalText(filter, count: tracks.count),
                    isLoading: viewModel.isFirstPageLoading(filter) && tracks.isEmpty,
                    error: tracks.isEmpty ? viewModel.pageError(filter) : nil,
                    paging: paging,
                    dateAdded: { viewModel.likedAtByTrackID[$0.id] ?? $0.createdAt },
                    loadAll: filter == .downloads ? nil : { await viewModel.loadAllLikes() },
                    retry: retry
                )
            case .playlists:
                playlistsPage
            case .albums:
                itemPage(viewModel.albumItems)
            case .artists:
                itemPage(viewModel.artistItems)
            case .following:
                peoplePage
            case .yourMusic:
                RemoteMusicDetailView()
            case .mixes:
                TVMixGrid()
            case .history:
                TVHistoryView()
            }
        }
        .task {
            await viewModel.load(filter: filter)
            switch filter {
            case .sets, .setlists, .songs: await viewModel.loadAllLikes()
            case .albums: await viewModel.loadAllCollections()
            default: break
            }
        }
    }

    private var tracks: [Track] {
        switch filter {
        case .likes: return viewModel.likedTracks
        case .songs: return viewModel.librarySongTracks
        case .sets: return viewModel.sets(minimumDuration: settings.setMinimumDurationSeconds)
        case .setlists: return viewModel.likedTracks.filter { setlists.setlist(for: $0.id) != nil }
        case .downloads:
            return downloads.entries.values.filter(\.isDownloaded).sorted { $0.addedAt > $1.addedAt }.map(\.track)
        default: return []
        }
    }

    private var paging: TVPaging? {
        switch filter {
        case .likes, .sets, .songs, .setlists: return viewModel.likesPaging
        default: return nil
        }
    }

    private func retry() {
        Task { await viewModel.reloadAllShelves() }
    }

    private var playlistsPage: some View {
        let playlists = viewModel.libraryPlaylists
        let loading = viewModel.isFirstPageLoading(filter) && playlists.isEmpty
        return TVLibraryPage(
            title: filter.label,
            subtitle: playlists.isEmpty ? nil : viewModel.totalText(filter, count: playlists.count),
            showsSyncLine: true,
            state: loading ? .loading(.columns(columns, spacing: SCBrowseMetrics.gutter)) : .ready
        ) {
            PlaylistGridView(
                playlists: playlists,
                columns: columns,
                paging: viewModel.collectionsPaging,
                emptyIcon: filter.icon,
                emptyTitle: filter.emptyMessage,
                pinsLikes: true
            )
        }
    }

    private func itemPage(_ items: [LibraryGridItem]) -> some View {
        TVLibraryPage(
            title: filter.label,
            subtitle: items.isEmpty ? nil : viewModel.totalText(filter, count: items.count),
            showsSyncLine: filter == .albums,
            state: itemState(items)
        ) {
            LibraryCollectionTVGrid(
                items: items,
                columns: columns,
                emptyIcon: filter.icon,
                emptyTitle: filter.emptyMessage
            )
        }
    }

    private func itemState(_ items: [LibraryGridItem]) -> LibraryPageState {
        guard items.isEmpty else { return .ready }
        let devicesLoading = !remoteMusic.loadingDeviceIds.isEmpty
        let awaiting = filter == .albums ? viewModel.isFirstPageLoading(filter) || devicesLoading : devicesLoading
        if awaiting {
            return .loading(.columns(columns, spacing: SCBrowseMetrics.gutter, circular: filter == .artists))
        }
        if let error = viewModel.pageError(filter) {
            return .message(.failure(filter, message: error, retry: retry))
        }
        return .message(.empty(filter))
    }

    private var peoplePage: some View {
        let users = viewModel.following
        return TVLibraryPage(
            title: filter.label,
            subtitle: viewModel.totalText(filter, count: users.count),
            state: peopleState(users)
        ) {
            UserGridView(
                users: users,
                columns: columns,
                paging: viewModel.followingPaging,
                emptyIcon: filter.icon,
                emptyTitle: filter.emptyMessage
            )
        }
    }

    private func peopleState(_ users: [User]) -> LibraryPageState {
        guard users.isEmpty else { return .ready }
        if viewModel.isFirstPageLoading(filter) {
            return .loading(.columns(columns, spacing: SCBrowseMetrics.gutter, circular: true))
        }
        if let error = viewModel.pageError(filter) {
            return .message(.failure(filter, message: error, retry: retry))
        }
        return .message(.empty(filter))
    }
}

// MARK: - Mixes

struct TVMixGrid: View {
    @Environment(\.libraryGridColumns) private var columns

    private static let limit = 200

    var body: some View {
        let store = MixHistoryStore.shared
        let items = store.shelfItems(limit: Self.limit)
        TVLibraryPage(
            title: LibraryFilter.mixes.label,
            subtitle: items.isEmpty ? nil : countText(store.collectedCount),
            state: items.isEmpty ? .message(.empty(.mixes)) : .ready
        ) {
            if !items.isEmpty {
                NavigationLink {
                    MixHistoryView()
                } label: {
                    TVGlassPillLabel(title: "All Mixes", systemImage: "list.bullet")
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityIdentifier("library.mixes.all")
                .focusSection()
            }
        } content: {
            LazyVGrid(columns: LibraryPageMetrics.grid(columns), alignment: .leading, spacing: Space.section) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        destination(item)
                    } label: {
                        TVMixCard(item: item)
                    }
                    .accessibilityIdentifier("library.mixes.card.\(index)")
                    .accessibilityLabel("\(item.title), \(item.detail)")
                }
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .focusEffectDisabled()
            .prefetchArtwork(items.prefix(24).flatMap { [$0.outgoing.artworkURL, $0.incoming.artworkURL] }.compactMap { $0 })
        }
    }

    private func countText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "mix" : "mixes")"
    }

    @ViewBuilder
    private func destination(_ item: MixShelfItem) -> some View {
        switch item.kind {
        case .mix(let entry):
            MixTransitionDetailView(entry: entry)
        case .set(let session):
            MixSetOverviewView(session: session, name: item.title)
        }
    }
}

struct TVMixCard: View {
    let item: MixShelfItem
    private let style = SCBrowseMetrics.tile

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceTight) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let side = proxy.size.width
                        ZStack(alignment: .bottomTrailing) {
                            artwork(item.outgoing)
                                .frame(width: side, height: side)
                            artwork(item.incoming)
                                .frame(width: side * 0.46, height: side * 0.46)
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                                .padding(Space.snug)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(1)
                Label(item.detail, systemImage: item.isSaved ? "bookmark.fill" : "arrow.triangle.merge")
                    .font(style.fontCaption)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(_ track: Track) -> some View {
        SCArtworkResolver(url: track.artworkURL) { image in
            SCArtwork(image: image, identity: track.id, style: style)
        }
    }
}
