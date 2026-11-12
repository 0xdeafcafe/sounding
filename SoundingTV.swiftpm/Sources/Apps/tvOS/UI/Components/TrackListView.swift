import SwiftUI

struct TrackListView: View {
    let tracks: [Track]
    var collectionId: String? = nil
    var dateAdded: (Track) -> Date = { $0.createdAt }
    var emptyIcon = "music.note.list"
    var emptyTitle = "No tracks"
    var paging: TVPaging?
    var toolbarActions: AnyView? = nil
    var toolbarHeaderOverlap: CGFloat = 0

    private var playerService: PlayerService { .shared }
    @StateObject private var analysisStore = TrackAnalysisStore()
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    @State private var searchText = ""
    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false
    @State private var setlistTrack: Track?
    @State private var cachedVisibleTracks: [Track] = []
    @FocusState private var toolbarFocus: ToolbarFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        tracks: [Track],
        collectionId: String? = nil,
        dateAdded: @escaping (Track) -> Date = { $0.createdAt },
        emptyIcon: String = "music.note.list",
        emptyTitle: String = "No tracks",
        paging: TVPaging? = nil,
        toolbarActions: AnyView? = nil,
        toolbarHeaderOverlap: CGFloat = 0
    ) {
        self.tracks = tracks
        self.collectionId = collectionId
        self.dateAdded = dateAdded
        self.emptyIcon = emptyIcon
        self.emptyTitle = emptyTitle
        self.paging = paging
        self.toolbarActions = toolbarActions
        self.toolbarHeaderOverlap = toolbarHeaderOverlap
        _cachedVisibleTracks = State(initialValue: TrackSort.sorted(
            tracks,
            by: .dateAdded,
            ascending: false,
            analysis: [:],
            dateAdded: dateAdded
        ))
    }

    private enum ToolbarFocus: Hashable { case search, sort, direction }

    private var searchIsExpanded: Bool {
        toolbarFocus == .search || !searchText.isEmpty
    }

    private static let artworkLookahead = 10

    var body: some View {
        let visible = cachedVisibleTracks

        VStack(alignment: .leading, spacing: Space.snug) {
            if tracks.count > 1 {
                toolbar
                    .offset(y: -toolbarHeaderOverlap)
                    .padding(.bottom, -toolbarHeaderOverlap)
            }

            if visible.isEmpty {
                StatusPanel(
                    kind: .empty,
                    icon: emptyIcon,
                    title: searchText.isEmpty ? emptyTitle : "No matches for \u{201C}\(searchText)\u{201D}",
                    minHeight: 320
                )
                if searchText.isEmpty, let paging {
                    TVPagedFooter(paging: paging)
                }
            } else {
                LazyVStack(spacing: Space.hair) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            analysis: analysisStore.summaries[track.id],
                            hasSetlist: DeckIdentityResolver.isLikelyMix(track)
                                || setlists.setlist(for: track.id) != nil,
                            action: { Task { await playerService.play(track, in: visible, collectionId: collectionId) } },
                            showSetlist: { setlistTrack = track }
                        )
                        .onAppear {
                            guard searchText.isEmpty, visible.isNearEnd(track, lead: 10) else { return }
                            paging?.loadMore()
                        }
                        .onAppear {
                            let lookahead = visible[index..<min(index + Self.artworkLookahead, visible.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
                        }
                    }

                    if searchText.isEmpty, let paging {
                        TVPagedFooter(paging: paging)
                    }
                }
                .focusSection()
            }
        }
        .task(id: tracks.map(\.id)) {
            await analysisStore.load(for: tracks)
            if let collectionId {
                DownloadManager.shared.applyCollectionPolicy(tracks: tracks, collectionId: collectionId)
            }
        }
        .onChange(of: tracks) { _, _ in recomputeVisibleTracks() }
        .onChange(of: searchText) { _, _ in recomputeVisibleTracks() }
        .onChange(of: sortKey) { _, _ in recomputeVisibleTracks() }
        .onChange(of: ascending) { _, _ in recomputeVisibleTracks() }
        .onReceive(analysisStore.$summaries) { _ in recomputeVisibleTracks() }
        .fullScreenCover(item: $setlistTrack) { track in
            SetlistEditorView(
                track: track,
                currentPosition: playerService.currentTrack?.id == track.id ? playerService.currentTime : 0,
                comments: [],
                localFileURL: playerService.localAudioURL(for: track),
                onSeek: { position in
                    Task {
                        if playerService.currentTrack?.id != track.id {
                            await playerService.play(track, in: [track])
                        }
                        playerService.seek(to: position)
                    }
                },
                onDownload: { DownloadManager.shared.download(track: track, confirmed: true) },
                onPlaySearchResult: { result in
                    Task { await playerService.play(result, in: [result]) }
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: Space.base) {
            Spacer(minLength: 0)

            if let toolbarActions {
                toolbarActions
            }

            HStack(spacing: Space.tight) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(toolbarFocus == .search ? Color.scChromeFocusOn : Color.scTextTertiary)
                TextField("Search this list", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.tvBody)
                    .foregroundStyle(toolbarFocus == .search ? Color.scChromeFocusOn : Color.scTextPrimary)
                    .opacity(searchIsExpanded ? 1 : 0)
                    .frame(width: searchIsExpanded ? 320 : 0)
            }
            .padding(.horizontal, 20)
            .frame(width: searchIsExpanded ? 404 : 68, height: 68, alignment: .leading)
            .background(
                toolbarFocus == .search ? Color.scChromeFocus : Color.white.opacity(0.10),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
            .focused($toolbarFocus, equals: .search)
            .scMotion(.easeInOut(duration: 0.20), reduceMotion: reduceMotion, value: searchIsExpanded)

            Menu {
                ForEach(TrackSortKey.menuCases) { key in
                    Button {
                        sortKey = key
                        ascending = key.defaultAscending
                    } label: {
                        Label(key.rawValue, systemImage: sortKey == key ? "checkmark" : key.icon)
                    }
                }
            } label: {
                toolbarCircle(icon: "line.3.horizontal.decrease", label: "Sort by", isFocused: toolbarFocus == .sort)
            }
            .buttonStyle(SCPlainButtonStyle())
            .focusEffectDisabled()
            .accessibilityIdentifier("tracklist.sort")
            .accessibilityLabel("Sort by")
            .accessibilityValue(sortKey.rawValue)
            .focused($toolbarFocus, equals: .sort)

            Button {
                ascending.toggle()
            } label: {
                toolbarCircle(
                    icon: ascending ? "arrow.up" : "arrow.down",
                    label: "Sort order",
                    isFocused: toolbarFocus == .direction
                )
            }
            .buttonStyle(SCPlainButtonStyle())
            .focusEffectDisabled()
            .focused($toolbarFocus, equals: .direction)
            .accessibilityLabel("Sort order")
            .accessibilityValue(ascending ? "Ascending" : "Descending")
            .accessibilityHint("Reverses the sort order")
        }
        .focusSection()
    }

    private func toolbarCircle(icon: String, label: String, isFocused: Bool) -> some View {
        Image(systemName: icon)
            .font(.body.weight(.semibold))
            .accessibilityLabel(label)
            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
            .frame(width: 68, height: 68)
            .background(isFocused ? Color.scChromeFocus : Color.white.opacity(0.10), in: Circle())
            .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 14, y: 7)
    }

    private func recomputeVisibleTracks() {
        let filtered: [Track]
        if searchText.isEmpty {
            filtered = tracks
        } else {
            let needle = searchText.lowercased()
            filtered = tracks.filter {
                $0.title.lowercased().contains(needle) || $0.user.displayName.lowercased().contains(needle)
            }
        }
        cachedVisibleTracks = TrackSort.sorted(
            filtered,
            by: sortKey,
            ascending: ascending,
            analysis: analysisStore.summaries,
            dateAdded: dateAdded
        )
    }
}

struct TVPlaybackPrewarmModifier: ViewModifier {
    let track: Track?
    private var playerService: PlayerService { .shared }
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.onChange(of: isFocused, initial: true) { _, focused in
            if focused, let track { playerService.preparePlayback(for: track) }
        }
    }
}

extension View {
    func prewarmPlaybackOnFocus(_ track: Track?) -> some View {
        modifier(TVPlaybackPrewarmModifier(track: track))
    }
}

private struct TrackRow: View {
    let track: Track
    let analysis: TrackAnalysisSummary?
    let hasSetlist: Bool
    let action: () -> Void
    let showSetlist: () -> Void

    var body: some View {
        let item = SCTrackListItem(track: track, analysis: analysis)
        Button {
            if item.isPlayable { action() }
        } label: {
            SCTrackListRow(item: item, leading: .artwork, metrics: .tv, crownUser: track.user)
        }
        .buttonStyle(TVTrackRowStyle())
        .contextMenu {
            StartStationMenuButton(track: track)
            if hasSetlist {
                Button(action: showSetlist) {
                    Label("View Setlist", systemImage: "list.number")
                }
            }
            TVTrackMenuItems(track: track)
        }
        .accessibilityActions {
            if hasSetlist {
                Button(action: showSetlist) {
                    Label("View Setlist", systemImage: "list.number")
                }
            }
        }
        .accessibilityLabel(item.accessibilityLabel)
        .prewarmPlaybackOnFocus(item.isPlayable ? track : nil)
    }
}
