import SwiftUI

extension LibraryFilter {
    var queryStorageKey: String { "library.\(rawValue).query" }

    var naturalQuery: TrackCollectionQuery {
        switch self {
        case .songs, .downloads: return .collectionOrder
        default: return .newestFirst
        }
    }

    var naturalOrderLabel: String? {
        switch self {
        case .songs: return "Recently Added"
        case .downloads: return "Recently Downloaded"
        default: return nil
        }
    }

    var dateLabel: String {
        switch self {
        case .likes, .sets, .setlists: return "Date Liked"
        default: return "Date Added"
        }
    }

    var trackFilters: [TrackFilter] {
        switch self {
        case .sets: return TrackFilter.allCases.filter { $0 != .sets }
        case .downloads: return TrackFilter.allCases.filter { $0 != .downloaded }
        default: return TrackFilter.allCases
        }
    }
}

extension SCTrackListMetrics {
    static let tvDense = SCTrackListMetrics(
        artworkSize: 44,
        artworkCorner: 6,
        numberWidth: 56,
        minHeight: 60,
        spacing: Space.base,
        verticalPadding: 4,
        horizontalPadding: Space.base,
        titleFont: .tvBody,
        subtitleFont: .tvBody,
        detailFont: .tvCaption.monospacedDigit(),
        numberFont: .tvCaption,
        indicatorFont: .tvCalloutEmph,
        durationMinWidth: 110,
        isSingleLine: true,
        invertsOnFocus: true,
        primary: .scTextPrimary,
        secondary: .scTextSecondary,
        tertiary: .scTextTertiary,
        focusedPrimary: .scChromeFocusOn,
        focusedSecondary: Color.scChromeFocusOn.opacity(0.7)
    )
}

struct TVTrackRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
            configuration.label
                .background { shape.fill(isFocused ? Color.scChromeFocus : Color.clear) }
                .contentShape(shape)
                .scaleEffect(isFocused ? 1.02 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct LibraryTrackGrid: View {
    let filter: LibraryFilter
    let tracks: [Track]
    let total: String?
    let isLoading: Bool
    let error: String?
    let paging: TVPaging?
    let dateAdded: (Track) -> Date
    let loadAll: (() async -> Void)?
    let retry: () -> Void

    @EnvironmentObject private var playerService: PlayerService
    @Environment(\.libraryGridColumns) private var columns
    @AppStorage private var query: TrackCollectionQuery
    @AppStorage private var showsColumns: Bool
    @AppStorage(TrackColumnLayout.storageKey, store: .sounding) private var layout = TrackColumnLayout.standard
    @StateObject private var analysis = TrackAnalysisStore()
    @State private var visible: [Track] = []
    @State private var hasComputed = false

    init(
        filter: LibraryFilter,
        tracks: [Track],
        total: String?,
        isLoading: Bool,
        error: String?,
        paging: TVPaging?,
        dateAdded: @escaping (Track) -> Date,
        loadAll: (() async -> Void)? = nil,
        retry: @escaping () -> Void
    ) {
        self.filter = filter
        self.tracks = tracks
        self.total = total
        self.isLoading = isLoading
        self.error = error
        self.paging = paging
        self.dateAdded = dateAdded
        self.loadAll = loadAll
        self.retry = retry
        _query = AppStorage(wrappedValue: filter.naturalQuery, filter.queryStorageKey, store: .sounding)
        TrackListColumnsPreference.migrate(filter.rawValue)
        _showsColumns = AppStorage(wrappedValue: false, TrackListColumnsPreference.storageKey(filter.rawValue), store: .sounding)
    }

    private var isReordered: Bool {
        TrackCollection.needsFullCollection(query, naturalOrder: filter.naturalQuery)
    }

    var body: some View {
        TVLibraryPage(
            title: filter.label,
            subtitle: subtitle,
            showsSyncLine: filter != .downloads,
            state: state
        ) {
            controls
        } content: {
            grid
        }
        .onAppear(perform: recompute)
        .onChange(of: tracks.count) { _, _ in recompute() }
        .onChange(of: tracks.first?.id) { _, _ in recompute() }
        .onChange(of: query) { _, _ in
            recompute()
            loadAllIfNeeded()
        }
        .onChange(of: analysis.summaries.count) { _, _ in recompute() }
        .task(id: tracks.count) { await analysis.load(for: tracks) }
        .task { loadAllIfNeeded() }
    }

    private var state: LibraryPageState {
        if isLoading || (!hasComputed && !tracks.isEmpty) {
            return .loading(placeholderStyle)
        }
        if let error, tracks.isEmpty {
            return .message(.failure(filter, message: error, retry: retry))
        }
        if tracks.isEmpty {
            return .message(.empty(filter))
        }
        if visible.isEmpty {
            var message = LibraryPageMessage(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matches",
                message: "Nothing in \(filter.label) matches these filters."
            )
            if query.isFiltering {
                let binding = $query
                message.actionTitle = "Clear Filters"
                message.action = { binding.wrappedValue.clearFilters() }
            }
            return .message(message)
        }
        return .ready
    }

    @ViewBuilder
    private var controls: some View {
        if !tracks.isEmpty {
            HStack(spacing: Space.base) {
                Button {
                    Task { await PlayActions.play(tracks: playable, collectionId: collectionId) }
                } label: {
                    TVGlassPillLabel(title: "Play", systemImage: "play.fill")
                }
                .buttonStyle(TVGlassPillStyle(isProminent: true))
                .accessibilityIdentifier("library.detail.play")

                Button {
                    Task { await PlayActions.shufflePlay(tracks: playable, collectionId: collectionId) }
                } label: {
                    TVGlassPillLabel(title: "Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityIdentifier("library.detail.shuffle")

                Menu {
                    TrackCollectionMenuItems(
                        query: $query,
                        showsColumns: $showsColumns,
                        sortKeys: TrackCollection.availableSortKeys(for: tracks, analysis: analysis.summaries),
                        dateLabel: filter.dateLabel,
                        naturalOrderLabel: filter.naturalOrderLabel,
                        filters: filter.trackFilters
                    )
                } label: {
                    TVGlassPillLabel(
                        title: sortMenuTitle,
                        systemImage: query.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "arrow.up.arrow.down"
                    )
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityLabel("Sort and Filter")
                .accessibilityValue(sortMenuValue)
                .accessibilityIdentifier("library.detail.sort")

                if filter == .likes {
                    CollectionDownloadButton(collectionId: CollectionPolicyID.likedTracks, tracks: { tracks })
                        .font(.tvBodyEmph)
                        .buttonStyle(TVGlassPillStyle(diameter: 76))
                        .accessibilityIdentifier("library.detail.download")
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private var grid: some View {
        if !showsColumns {
            LazyVGrid(columns: LibraryPageMetrics.grid(columns), alignment: .leading, spacing: Space.section) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                    tile(track, index: index)
                }
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .focusEffectDisabled()
        } else {
            LazyVStack(spacing: Space.hair) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                    denseRow(track, index: index)
                }
            }
            .focusSection()
        }

        if let paging, !isReordered {
            TVPagedFooter(paging: paging)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var placeholderStyle: LoadingPlaceholderStyle {
        showsColumns ? .trackList(.tvDense) : .columns(columns, spacing: SCBrowseMetrics.gutter)
    }

    private func tile(_ track: Track, index: Int) -> some View {
        Button {
            guard track.streamURL != nil else { return }
            Task { await playerService.play(track, in: visible, collectionId: collectionId) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: tileSubtitle(track),
                    artworkImage: image,
                    artIdentity: track.id,
                    isAvailable: track.streamURL != nil,
                    style: SCBrowseMetrics.tile
                )
            }
        }
        .contextMenu { TVTrackMenuItems(track: track) }
        .prewarmPlaybackOnFocus(track.streamURL == nil ? nil : track)
        .accessibilityIdentifier("library.detail.card.\(index)")
        .accessibilityLabel(TrackAccessibility.label(
            title: track.title,
            artist: track.user.displayName,
            duration: track.formattedDuration,
            isUnavailable: track.streamURL == nil
        ))
        .onAppear { rowAppeared(track, index: index, lead: columns * 3) }
    }

    private func denseRow(_ track: Track, index: Int) -> some View {
        let item = denseItem(track)
        return Button {
            guard track.streamURL != nil else { return }
            Task { await playerService.play(track, in: visible, collectionId: collectionId) }
        } label: {
            SCTrackListRow(
                item: item,
                leading: .artwork,
                activity: activity(for: track),
                metrics: .tvDense,
                crownUser: track.user
            )
        }
        .buttonStyle(TVTrackRowStyle())
        .contextMenu { TVTrackMenuItems(track: track) }
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier("library.detail.row.\(index)")
        .prewarmPlaybackOnFocus(track.streamURL == nil ? nil : track)
        .onAppear { rowAppeared(track, index: index, lead: 12) }
    }

    private func denseItem(_ track: Track) -> SCTrackListItem {
        let summary = analysis.summaries[track.id]
        let parts = layout.denseExtras
            .map { TrackValueFormat.value($0, track: track, analysis: summary, dateAdded: dateAdded(track)) }
            .filter { $0 != TrackValueFormat.missing }
        return SCTrackListItem(track: track, analysis: summary, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    private func tileSubtitle(_ track: Track) -> String {
        switch query.sortKey {
        case .plays?, .energy?, .source?, .genre?, .bpm?, .key?:
            guard let value = TrackSort.sortValue(for: track, key: query.sortKey, analysis: analysis.summaries[track.id]) else { break }
            return "\(track.user.displayName) · \(value)"
        default:
            break
        }
        return track.user.displayName
    }

    private func rowAppeared(_ track: Track, index: Int, lead: Int) {
        if !isReordered, visible.isNearEnd(track, lead: lead) { paging?.loadMore() }
        let end = min(index + columns * 2, visible.count)
        if index < end { ArtworkCache.shared.prefetch(visible[index..<end].compactMap(\.artworkURL)) }
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }

    private var subtitle: String? {
        guard let total, !tracks.isEmpty else { return nil }
        if !query.isFiltering { return total }
        return "\(visible.count.formatted()) shown · \(total)"
    }

    private var sortMenuTitle: String {
        guard let key = query.sortKey else { return filter.naturalOrderLabel ?? "Sort & Filter" }
        return key.title(dateLabel: filter.dateLabel)
    }

    private var sortMenuValue: String {
        let order = query.sortKey == nil ? "" : (query.ascending ? ", ascending" : ", descending")
        let filters = query.isFiltering ? ", \(query.activeFilterCount) filters on" : ""
        return sortMenuTitle + order + filters
    }

    private var collectionId: String? {
        filter == .likes ? CollectionPolicyID.likedTracks : nil
    }

    private var playable: [Track] {
        visible.filter { $0.streamURL != nil }
    }

    private func loadAllIfNeeded() {
        guard isReordered, let loadAll else { return }
        Task { await loadAll() }
    }

    private func recompute() {
        var effective = query
        if !isReordered { effective.sortKey = nil }
        visible = TrackCollection.apply(
            tracks,
            query: effective,
            analysis: analysis.summaries,
            context: TrackCollectionLoader.context(),
            dateAdded: dateAdded
        )
        hasComputed = true
    }
}
