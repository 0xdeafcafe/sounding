import SwiftUI
import AppKit

enum MacCollectionKind: Equatable {
    case playlist
    case album

    var noun: String { self == .playlist ? "Playlist" : "Album" }
}

struct MacPlaylistDetailView: View {
    let playlist: Playlist

    var body: some View {
        MacCollectionDetailView(playlist: playlist, kind: .playlist)
    }
}

struct MacCollectionDetailView: View {
    let kind: MacCollectionKind

    @StateObject private var viewModel: PlaylistDetailViewModel
    @StateObject private var suggestions = MacSuggestedTracksModel()
    @StateObject private var related = CollectionRelatedModel()
    @EnvironmentObject private var credentials: SoundCloudCredentialSource

    @State private var isDescriptionExpanded = false
    @State private var filterText = ""
    @State private var isShowingCollectionPolicy = false
    @State private var titleIsHidden = false
    @State private var backdropGone = false

    init(playlist: Playlist, kind: MacCollectionKind) {
        self.kind = kind
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    private var playlist: Playlist { viewModel.playlist }

    var body: some View {
        MacViewportScrollView(hidesContentUnderToolbar: backdropGone) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                hero
                    .macReportsScrolledAway($backdropGone)

                if case .loaded = state {
                    trackTable
                    if filterText.isEmpty, !viewModel.pager.hasMore {
                        relatedShelves
                        Color.clear.frame(height: 32)
                    }
                } else {
                    mainContent(for: state)
                        .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                        .padding(.bottom, 32)
                }
            }
            .collectionPageScheme()
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectHidden(!backdropGone, for: .top)
        .tracksCollectionOverscroll()
        .animation(.smooth, value: backdropGone)
        .animation(.smooth, value: titleIsHidden)
        .collectionPage(artworkURL: heroContent.artworkURL)
        .collectionAccent(from: playlist.largeDisplayArtworkURL ?? MacCollectionCover.artworkURLs(for: playlist).first)
        .navigationTitle(playlist.title)
        .toolbar(removing: .title)
        .toolbar {
            if titleIsHidden {
                MacScrolledPageTitle(title: playlist.title)
            }
        }
        .onChange(of: titleIsHidden) { _, hidden in MacPageTitleVisibility.shared.isShowingPushedTitle = hidden }
        .onDisappear { MacPageTitleVisibility.shared.isShowingPushedTitle = false }
        .searchable(
            text: $filterText,
            placement: .toolbar,
            prompt: "Find in \(kind.noun)"
        )
        .task {
            await viewModel.loadIfNeeded()
        }
        .task(id: viewModel.playlist.id) {
            await suggestions.load(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
        }
        .task(id: viewModel.tracks.map(\.id)) {
            DownloadManager.shared.applyCollectionPolicy(
                tracks: viewModel.tracks,
                collectionId: playlist.id
            )
        }
        .playlistEditing(viewModel) { MacRootSelection.shared.request(.playlists) }
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: playlist.id,
                collectionName: playlist.title,
                collectionKind: CollectionKind.classify(playlist: playlist),
                tracks: viewModel.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private enum State { case loading, error(String), empty, loaded }

    private var state: State {
        if viewModel.isLoading, viewModel.tracks.isEmpty { return .loading }
        if let error = viewModel.errorMessage, viewModel.tracks.isEmpty { return .error(error) }
        if viewModel.tracks.isEmpty { return .empty }
        return .loaded
    }

    @ViewBuilder
    private func mainContent(for state: State) -> some View {
        switch state {
        case .loading:
            LoadingPlaceholder(.trackList(.mac), count: 10)
        case .error(let message):
            ContentUnavailableView {
                Label("Couldn’t Load \(kind.noun)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await viewModel.load() } }
            }
            .macFillsPane()
        case .empty:
            emptyState
        case .loaded:
            trackTable
        }
    }

    private var heroContent: CollectionHeroContent {
        var content = CollectionHeroContent(playlist: playlist, loadedTrackCount: viewModel.tracks.count)
        if content.artworkURL == nil {
            content.artworkURL = MacCollectionCover.artworkURLs(for: playlist).first
        }
        return content
    }

    private var hero: some View {
        CollectionHero(
            content: heroContent,
            metrics: .macFullBleed,
            onSubtitle: { MacRootSelection.shared.request(artist: playlist.user) }
        ) {
            actionRow
                .padding(.top, SCContentStyle.mac.spaceTight)
        }
        .macReportsScrolledAway($titleIsHidden)
    }

    @ViewBuilder
    private var relatedShelves: some View {
        collectionFooter
            .padding(.horizontal, SCContentStyle.mac.spaceGutter)
            .padding(.top, SCContentStyle.mac.spaceBase)
            .onAppear {
                loadRelated(.artist)
                loadRelated(.moreByArtist)
            }

        if !related.moreByArtist.isEmpty {
            CollectionShelf(
                title: CollectionRelatedModel.moreTitle(for: related.artist ?? playlist.user),
                items: related.moreByArtist,
                style: .mac,
                tileWidth: 160,
                spacing: SCContentStyle.mac.spaceBase,
                inset: SCContentStyle.mac.spaceGutter
            ) { other in
                NavigationLink(value: other) {
                    ArtworkShelfCard(playlist: other, style: .mac)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, SCContentStyle.mac.spaceSection)
            .macFadesUnderToolbar()
        }

        if !related.similar.isEmpty {
            CollectionShelf(
                title: "You Might Also Like",
                items: related.similar,
                style: .mac,
                tileWidth: 160,
                spacing: SCContentStyle.mac.spaceBase,
                inset: SCContentStyle.mac.spaceGutter
            ) { track in
                Button {
                    let playable = related.similar.filter { $0.streamURL != nil }
                    Task { await MacPlayback.play(track, in: playable) }
                } label: {
                    ArtworkShelfCard(track: track, style: .mac)
                }
                .buttonStyle(.plain)
                .disabled(track.streamURL == nil)
                .contextMenu {
                    MacTrackContextMenu(track: track, context: related.similar)
                }
            }
            .padding(.top, SCContentStyle.mac.spaceSection)
            .macFadesUnderToolbar()
        } else if !related.hasFinished(.similar) {
            CollectionRelatedTrigger { loadRelated(.similar) }
        }
    }

    private var collectionFooter: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceRoomy) {
            CollectionReleaseFooter(
                info: CollectionReleaseInfo(playlist: playlist, tracks: viewModel.tracks, showsSummary: false),
                font: .subheadline
            )
            let artist = related.artist ?? playlist.user
            SoundCloudUploaderRow(user: artist, avatarSize: 56, spacing: SCContentStyle.mac.spaceBase, postsMusic: playlist.isAlbum) {
                MacRootSelection.shared.request(artist: artist)
            }
            .frame(maxWidth: 520, alignment: .leading)
            CollectionEngagementSection(playlist: playlist, openUser: { MacRootSelection.shared.request(artist: $0) })
                .frame(maxWidth: 520, alignment: .leading)
        }
        .macFadesUnderToolbar()
    }

    private func loadRelated(_ part: CollectionRelatedModel.Part) {
        let current = viewModel.playlist
        let tracks = viewModel.tracks
        Task { await related.load(part, for: current, tracks: tracks) }
    }

    private var actionRow: some View {
        HStack(spacing: SCContentStyle.mac.spaceSnug) {
            CollectionHeroPlayButtons(
                isEnabled: hasPlayableTrack,
                fills: false,
                isCompact: true,
                collectionID: playlist.id,
                prewarm: { CollectionPlayback.prewarm(viewModel.tracks, immediate: $0) },
                onPlay: play,
                onShuffle: shufflePlay
            )

            LibraryAlbumCounterpartLink(route: .playlist(playlist))

            CollectionDownloadButton(
                collectionId: playlist.id,
                playlist: playlist,
                tracks: { viewModel.tracks }
            )
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .disabled(!hasPlayableTrack)
            .help("Download")
            .accessibilityLabel("Download")

            Menu {
                collectionMenu
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .help("More")
            .accessibilityLabel("More")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var collectionMenu: some View {
        Button {
            playNext()
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(!hasPlayableTrack)

        Button {
            playLast()
        } label: {
            Label("Add to Up Next", systemImage: "text.badge.plus")
        }
        .disabled(!hasPlayableTrack)

        if playlist.isAlbum {
            LibraryAlbumLinkMenuItems(route: .playlist(playlist))
        }

        Divider()

        Button {
            isShowingCollectionPolicy = true
        } label: {
            Label("Collection Settings", systemImage: "slider.horizontal.3")
        }

        SidebarPinButton(playlist: playlist)

        Divider()

        Button {
            NSWorkspace.shared.open(playlist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(playlist.permalinkURL.absoluteString, forType: .string)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: playlist.permalinkURL, subject: Text(playlist.title), preview: SharePreview(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        PlaylistManagementMenuItems(playlist: playlist, tracks: viewModel.tracks)
    }

    private var hasPlayableTrack: Bool {
        viewModel.tracks.contains { $0.streamURL != nil }
    }

    private var emptyState: some View {
        VStack(spacing: SCContentStyle.mac.spaceRoomy) {
            AddTracksEmptyState(playlist: viewModel.playlist) {
                Task { await viewModel.load() }
            }
            .macFillsPane()

            suggestedSongsSection
        }
    }

    private var suggestedSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SCSectionHeader(title: "Suggested Tracks", style: .mac)
                    Text("From your Liked Tracks.")
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                }
                Spacer()
                Button {
                    Task { await suggestions.reload(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.link)
                .disabled(suggestions.isLoading)
            }

            suggestedSongsBody
        }
    }

    @ViewBuilder
    private var suggestedSongsBody: some View {
        if credentials.isSignedOut {
            Text("Sign in to see suggestions from your Liked Tracks.")
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .padding(.vertical, 8)
        } else if suggestions.isLoading, suggestions.tracks.isEmpty {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 12)
        } else if let error = suggestions.errorMessage, suggestions.tracks.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Suggestions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task {
                        await suggestions.reload(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
                    }
                }
            }
        } else if suggestions.tracks.isEmpty {
            Text("Like a few tracks on SoundCloud and they’ll show up here.")
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .padding(.vertical, 8)
        } else {
            let columns = [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
                ForEach(suggestions.tracks) { track in
                    SuggestedTrackRow(track: track, isAdding: suggestions.isAdding(track)) {
                        Task { await suggestions.add(track, to: playlist) { added in
                            viewModel.acceptSuggestedTrack(added)
                        } }
                    }
                }
            }
        }
    }

    private var visibleTracks: [Track] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return viewModel.tracks }
        return viewModel.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.user.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var trackTable: some View {
        MacCollectionTrackTable(
            tracks: visibleTracks,
            contextPlaylist: playlist,
            footer: filterText.isEmpty ? AnyView(MacPagedFooter(pager: viewModel.pager)) : nil,
            margin: SCContentStyle.mac.spaceGutter,
            onPlay: { track in
                let identity = LibraryIdentity.current
                let tracks = identity.preferringLocalCopies(viewModel.tracks)
                let start = identity.localCopy(of: track) ?? track
                Task { await MacPlayback.play(start, in: tracks, collectionId: playlist.id, source: PlaybackQueueSource(playlist: playlist)) }
            }
        )
        .playlistTrackDropTarget(playlist, cornerRadius: 0) {
            Task { await viewModel.load() }
        }
    }

    private func play() {
        let tracks = LibraryIdentity.current.preferringLocalCopies(viewModel.tracks)
        guard tracks.contains(where: { $0.streamURL != nil }) else { return }
        let playlist = playlist
        let known = viewModel.tracks.map(\.id)
        Task {
            await CollectionPlayback.start(playlist: playlist, loaded: tracks, alsoKnownIDs: known) { first, queue in
                await MacPlayback.play(first, in: queue, collectionId: playlist.id, source: PlaybackQueueSource(playlist: playlist))
            }
        }
    }

    private func shufflePlay() {
        guard hasPlayableTrack else { return }
        let tracks = LibraryIdentity.current.preferringLocalCopies(viewModel.tracks)
        Task { await MacPlayback.shuffle(tracks, collectionId: playlist.id, source: PlaybackQueueSource(playlist: playlist)) }
    }

    private func playNext() {
        MacPlayback.playNext(viewModel.tracks.filter { $0.streamURL != nil })
    }

    private func playLast() {
        MacPlayback.playLast(viewModel.tracks.filter { $0.streamURL != nil })
    }
}

private struct TruncatedText: View {
    let text: String
    @Binding var isExpanded: Bool

    init(_ text: String, isExpanded: Binding<Bool>) {
        self.text = text
        self._isExpanded = isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if !isExpanded {
                Button("More") { isExpanded = true }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }
}

enum MacTrackTableMetrics {
    static let pageMargin: CGFloat = SCContentStyle.mac.spaceGutter
    static let rowInset: CGFloat = 8
    static let rowHeight: CGFloat = 50
    static let headerHeight: CGFloat = 26
    static let artworkSize: CGFloat = 36
    static let artworkGap: CGFloat = 10
    static let columnGap: CGFloat = 16
    static let rowCorner: CGFloat = 8
}

extension TrackTableColumn {
    var macCollectionWidth: CGFloat? {
        self == .title ? nil : width.ideal
    }
}

struct MacCollectionTrackTable: View {
    let tracks: [Track]
    var contextPlaylist: Playlist? = nil
    var footer: AnyView? = nil
    var margin: CGFloat = 0
    let onPlay: (Track) -> Void

    @State private var selection: Track.ID?
    @State private var sortColumn: TrackTableColumn?
    @State private var sortAscending = true
    @AppStorage(TrackColumnLayout.storageKey) private var layout = TrackColumnLayout.standard

    private var visibleColumns: [TrackTableColumn] { layout.enabled }

    private var sortedTracks: [Track] {
        guard let sortColumn else { return tracks }
        let summaries = AnalysisSummaries.shared
        return TrackSort.sorted(
            tracks,
            by: sortColumn.sortKey,
            ascending: sortAscending,
            analysis: tracks.reduce(into: [String: TrackAnalysisSummary]()) { result, track in
                if let summary = summaries.summary(for: track.id) { result[track.id] = TrackAnalysisSummary(summary) }
            }
        )
    }

    var body: some View {
        Section {
            ForEach(sortedTracks) { track in
                row(track)
                    .padding(.horizontal, margin)
            }
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                if let footer {
                    footer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SCContentStyle.mac.spaceBase)
            .padding(.bottom, margin > 0 ? SCContentStyle.mac.spaceSection : 0)
            .padding(.horizontal, margin)
        } header: {
            header
                .padding(.horizontal, margin)
        }
    }

    private var header: some View {
        HStack(spacing: MacTrackTableMetrics.columnGap) {
            ForEach(visibleColumns) { column in
                headerButton(column)
            }
        }
        .padding(.horizontal, MacTrackTableMetrics.rowInset)
        .frame(height: MacTrackTableMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
                .padding(.horizontal, MacTrackTableMetrics.rowInset)
        }
        .padding(.horizontal, -MacTrackTableMetrics.rowInset)
        .contextMenu {
            ForEach(layout.movable) { column in
                Toggle(column.title(), isOn: visibilityBinding(column))
            }
        }
    }

    private func headerButton(_ column: TrackTableColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = !column.isNumeric
            }
        } label: {
            HStack(spacing: 3) {
                if column.isNumeric { sortIndicator(column) }
                Text(column.title())
                if !column.isNumeric { sortIndicator(column) }
            }
            .font(.subheadline.weight(sortColumn == column ? .semibold : .regular))
            .foregroundStyle(sortColumn == column ? .primary : .secondary)
            .padding(.leading, column == .title ? MacTrackTableMetrics.artworkSize + MacTrackTableMetrics.artworkGap : 0)
            .frame(maxWidth: column.macCollectionWidth ?? .infinity, alignment: column.isNumeric ? .trailing : .leading)
            .frame(width: column.macCollectionWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(column.title())")
        .accessibilityLabel("Sort by \(column.title())")
        .accessibilityValue(sortColumn == column ? (sortAscending ? "Ascending" : "Descending") : "")
    }

    @ViewBuilder
    private func sortIndicator(_ column: TrackTableColumn) -> some View {
        if sortColumn == column {
            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
        }
    }

    private func visibilityBinding(_ column: TrackTableColumn) -> Binding<Bool> {
        Binding(
            get: { layout.isVisible(column) },
            set: { visible in
                var next = layout
                next.setVisible(column, visible)
                layout = next
            }
        )
    }

    private func row(_ track: Track) -> some View {
        MacTrackTableRow(
            track: track,
            columns: visibleColumns,
            isSelected: selection == track.id,
            onPlay: { onPlay(track) }
        )
        .onTapGesture(count: 2) {
            guard track.streamURL != nil else { return }
            onPlay(track)
        }
        .simultaneousGesture(TapGesture().onEnded { selection = track.id })
        .playlistRowEditing(track, reorders: sortColumn == nil)
        .trackDragSource(track)
        .contextMenu {
            MacTrackContextMenu(track: track, contextPlaylist: contextPlaylist, context: sortedTracks)
        }
        .macFadesUnderToolbar(over: 20, below: MacTrackTableMetrics.headerHeight)
    }

    private var summary: String {
        let count = "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
        let total = tracks.reduce(0) { $0 + $1.duration }
        let duration = Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "\(count), \(duration)"
    }
}

private struct MacTrackTableRow: View {
    let track: Track
    let columns: [TrackTableColumn]
    let isSelected: Bool
    let onPlay: () -> Void

    @ObservedObject private var summaries = AnalysisSummaries.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: MacTrackTableMetrics.columnGap) {
            ForEach(columns) { column in
                cell(column)
            }
        }
        .padding(.horizontal, MacTrackTableMetrics.rowInset)
        .frame(height: MacTrackTableMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: MacTrackTableMetrics.rowCorner, style: .continuous)
                .fill(fill)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .padding(.horizontal, -MacTrackTableMetrics.rowInset)
    }

    private var fill: Color {
        if isSelected { return Color.scAccent.opacity(0.22) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder
    private func cell(_ column: TrackTableColumn) -> some View {
        switch column {
        case .title:
            MacCollectionTrackCell(track: track, onPlay: onPlay)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .source:
            Label(TrackValueFormat.sourceLabel(track), systemImage: TrackValueFormat.sourceSymbol(track))
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
                .frame(width: column.macCollectionWidth, alignment: .leading)
        case .bpm, .key:
            TrackAnalysisValueCell(
                track: track,
                kind: column == .bpm ? .bpm : .key,
                summary: summaries.summary(for: track.id).map(TrackAnalysisSummary.init)
            )
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(MacSecondaryStyle())
            .frame(width: column.macCollectionWidth, alignment: column.isNumeric ? .trailing : .leading)
        default:
            secondary(
                TrackValueFormat.value(column, track: track, analysis: summaries.summary(for: track.id).map(TrackAnalysisSummary.init)),
                column
            )
        }
    }

    private func secondary(_ text: String, _ column: TrackTableColumn) -> some View {
        Text(text)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(MacSecondaryStyle())
            .lineLimit(1)
            .frame(width: column.macCollectionWidth, alignment: column.isNumeric ? .trailing : .leading)
    }
}

struct MacTrackRows: View {
    let tracks: [Track]
    var contextPlaylist: Playlist? = nil
    let onPlay: (Track) -> Void

    private let playback = PlaybackIndicatorStore.shared
    @State private var selection: Track.ID?
    @State private var hovered: Track.ID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tracks) { track in
                row(track)
                    .macFadesUnderToolbar(over: 20)
            }
        }
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playback.isCurrent(track.id) else { return .none }
        if playback.isLoading { return .loading }
        return playback.isPlaying ? .playing : .paused
    }

    private func row(_ track: Track) -> some View {
        HStack(spacing: SCContentStyle.mac.spaceTight) {
            SCTrackListRow(
                item: SCTrackListItem(track: track),
                leading: .artwork,
                activity: activity(for: track),
                metrics: .mac,
                crownUser: track.user
            )
            SCTrackListMoreMenu(title: track.title, size: 28) {
                MacTrackContextMenu(track: track, contextPlaylist: contextPlaylist, context: tracks)
            }
            .opacity(hovered == track.id || selection == track.id ? 1 : 0)
        }
        .padding(.horizontal, MacTrackTableMetrics.rowInset)
        .background {
            RoundedRectangle(cornerRadius: MacTrackTableMetrics.rowCorner, style: .continuous)
                .fill(fill(for: track))
        }
        .contentShape(Rectangle())
        .onHover { hovering in hovered = hovering ? track.id : (hovered == track.id ? nil : hovered) }
        .padding(.horizontal, -MacTrackTableMetrics.rowInset)
        .onTapGesture(count: 2) {
            guard track.streamURL != nil else { return }
            onPlay(track)
        }
        .simultaneousGesture(TapGesture().onEnded { selection = track.id })
        .trackDragSource(track)
        .contextMenu {
            MacTrackContextMenu(track: track, contextPlaylist: contextPlaylist, context: tracks)
        }
        .accessibilityElement(children: .combine)
        .macTrackAccessibility(track: track, isCurrent: playback.isCurrent(track.id))
    }

    private func fill(for track: Track) -> Color {
        if selection == track.id { return Color.scAccent.opacity(0.22) }
        return hovered == track.id ? Color.primary.opacity(0.06) : .clear
    }
}

private struct MacCollectionTrackCell: View {
    let track: Track
    let onPlay: () -> Void

    private let playback = PlaybackIndicatorStore.shared
    @State private var isHovering = false

    private var isPlayable: Bool { track.streamURL != nil }
    private var isCurrentTrack: Bool { playback.isCurrent(track.id) }

    var body: some View {
        HStack(spacing: MacTrackTableMetrics.artworkGap) {
            ZStack {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.id,
                    size: MacTrackTableMetrics.artworkSize,
                    cornerRadius: 4,
                    isAvailable: isPlayable,
                    crownUser: track.user,
                    crownContext: track.title
                )

                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.44))
                    if playback.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .accessibilityLabel("Loading")
                    } else {
                        Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .accessibilityLabel(playback.isPlaying ? "Now playing" : "Paused")
                    }
                } else if isHovering, isPlayable {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.40))
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: MacTrackTableMetrics.artworkSize, height: MacTrackTableMetrics.artworkSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play")
                    .accessibilityLabel("Play \(track.title)")
                }
            }
            .frame(width: MacTrackTableMetrics.artworkSize, height: MacTrackTableMetrics.artworkSize)
            .onHover { isHovering = $0 }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .foregroundStyle(isPlayable ? .primary : .secondary)
                        .lineLimit(1)
                    if track.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(MacSecondaryStyle())
                            .help("Private track")
                            .accessibilityLabel("Private")
                    }
                    SoundCloudTrackBadge(track: track)
                }
                Text(track.user.displayName)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .macTrackAccessibility(track: track, isCurrent: isCurrentTrack)
    }
}

@MainActor
final class MacSuggestedTracksModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var addingTrackIDs: Set<String> = []

    private var loadTask: Task<Void, Never>?

    func isAdding(_ track: Track) -> Bool { addingTrackIDs.contains(track.id) }

    func load(excluding playlist: Playlist, currentUserId: String?, isSignedOut: Bool) async {
        guard tracks.isEmpty, !isSignedOut else { return }
        await fetch(excluding: playlist)
    }

    func reload(excluding playlist: Playlist, currentUserId: String?, isSignedOut: Bool) async {
        guard !isSignedOut else { return }
        await fetch(excluding: playlist)
    }

    private func fetch(excluding playlist: Playlist) async {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 50)
            guard !Task.isCancelled else { return }
            let existing = Set(playlist.trackIDs ?? playlist.loadedTracks.map(\.id))
            let candidates = page.collection.map(\.item).filter { !existing.contains($0.id) }
            tracks = Array(candidates.shuffled().prefix(6))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn\u{2019}t load your Liked Tracks to suggest from."
        }
    }

    func add(_ track: Track, to playlist: Playlist, onAdded: @escaping (Track) -> Void) async {
        guard !addingTrackIDs.contains(track.id) else { return }
        addingTrackIDs.insert(track.id)
        defer { addingTrackIDs.remove(track.id) }

        do {
            try await SoundCloudAPI.shared.addTrack(track.id, toPlaylist: playlist.id)
            tracks.removeAll { $0.id == track.id }
            onAdded(track)
        } catch {
            errorMessage = "Couldn\u{2019}t add \u{201C}\(track.title)\u{201D}. Check your connection and try again."
        }
    }
}

private struct SuggestedTrackRow: View {
    let track: Track
    let isAdding: Bool
    let onAdd: () -> Void

    var body: some View {
        SCArtworkResolver(url: track.artworkURL, variant: .standard) { artwork in
            row(artwork: artwork)
        }
    }

    private func row(artwork: Image?) -> some View {
        SCTrackRow(
            title: track.title,
            subtitle: track.user.displayName,
            artworkImage: artwork,
            artIdentity: track.id,
            isAvailable: track.streamURL != nil,
            crownUser: track.user,
            crownContext: track.title,
            style: .mac
        ) {
            Button(action: onAdd) {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.scAccent)
                }
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
            .help("Add to this playlist")
            .accessibilityLabel("Add \(track.title) to this playlist")
        }
    }
}

extension PlaylistDetailViewModel {
    @MainActor
    func acceptSuggestedTrack(_ track: Track) {
        tracks.appendUnique(contentsOf: [track])
    }
}
