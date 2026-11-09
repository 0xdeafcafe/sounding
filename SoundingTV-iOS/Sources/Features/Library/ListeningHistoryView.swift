import SwiftUI

struct ListeningHistoryView: View {
    @ObservedObject private var history = ListeningHistory.shared
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var confirmation = QueueConfirmationController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @Namespace private var heroNamespace

    private var visible: [ListeningHistoryEntry] {
        ListeningHistoryMerge.filtered(history.entries, search: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let visible = self.visible
        content(visible)
            .navigationTitle("History")
            .libraryPageTitleDisplayMode()
            .libraryPageSearchable(text: $searchText, prompt: "Search History")
            .toolbar { toolbar(visible) }
            .task { await history.load() }
            .queueConfirmationOverlay(confirmation)
    }

    @ToolbarContentBuilder
    private func toolbar(_ visible: [ListeningHistoryEntry]) -> some ToolbarContent {
        let queue = ListeningHistoryMerge.queue(visible).filter { $0.streamURL != nil }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                play(queue.first, in: queue)
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .disabled(queue.isEmpty)

            Button {
                shuffle(queue)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(queue.count < 2)
        }
    }

    @ViewBuilder
    private func content(_ visible: [ListeningHistoryEntry]) -> some View {
        if history.entries.isEmpty {
            ListeningHistoryStatusView(phase: history.phase) {
                Task { await history.load(force: true) }
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if !isSearching, !history.collections.isEmpty {
                    Section {
                        collectionsShelf
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Space.section, trailing: 0))
                            .listRowSeparator(.hidden)
                    } header: {
                        PhoneSectionTitle(title: "Recently Played Collections")
                    }
                    .headerProminence(.increased)
                }

                ForEach(ListeningHistoryMerge.days(visible)) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            ListeningHistoryRow(entry: entry, queue: { ListeningHistoryMerge.queue(visible) }, confirmation: confirmation)
                                .onAppear { rowAppeared(entry, in: visible) }
                        }
                    } header: {
                        PhoneSectionTitle(title: day.title)
                    }
                    .headerProminence(.increased)
                }

                if history.hasMore, !isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .onAppear { history.loadMore() }
                }
            }
            .listStyle(.plain)
            .animation(reduceMotion ? nil : .snappy, value: history.revision)
            .refreshable { await history.load(force: true) }
        }
    }

    private var collectionsShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: PhoneLayout.tileGap) {
                ForEach(history.collections) { collection in
                    collectionTile(collection)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, PhoneLayout.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .prefetchArtwork(history.collections.compactMap(\.entry.artworkURL))
    }

    private var tileSide: CGFloat { dynamicTypeSize.isAccessibilitySize ? 220 : 150 }

    @ViewBuilder
    private func collectionTile(_ collection: ListeningHistoryCollection) -> some View {
        let card = ListeningHistoryCollectionCard(collection: collection, style: .phone, side: tileSide)
        switch collection.entry {
        case .playlist(let playlist):
            PlaylistLink(playlist, heroNamespace: heroNamespace) {
                card.matchedTransitionSource(id: playlist.id, in: heroNamespace)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
        case .station(let station):
            Button { playStation(station) } label: { card }
                .buttonStyle(.plain)
                .libraryTilePreviewShape()
                .contextMenu {
                    Button { playStation(station) } label: { Label("Play", systemImage: "play") }
                    if let url = station.permalinkURL {
                        ShareLink(item: url, preview: SharePreview(collection.entry.cardTitle)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .accessibilityHint("Plays the station")
        case .user(let user):
            NavigationLink(value: user) {
                card
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { UserContextMenu(user: user) }
        }
    }

    private func rowAppeared(_ entry: ListeningHistoryEntry, in visible: [ListeningHistoryEntry]) {
        if !isSearching, visible.isNearEnd(entry, lead: 10) { history.loadMore() }
        if let index = visible.firstIndex(of: entry) {
            let ahead = visible[index..<min(index + 10, visible.count)]
            ArtworkCache.shared.prefetch(ahead.compactMap(\.track.artworkURL), variant: .thumbnail)
        }
    }

    private func play(_ track: Track?, in queue: [Track]) {
        guard let track else { return }
        ListeningHistory.notePlayback()
        Task {
            if let message = await coordinator.play(track, in: queue, collectionId: ListeningHistory.collectionID) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func shuffle(_ queue: [Track]) {
        guard !queue.isEmpty else { return }
        ListeningHistory.notePlayback()
        Task {
            if let message = await coordinator.play(shuffled: queue, collectionId: ListeningHistory.collectionID) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func playStation(_ station: SystemPlaylist) {
        Task {
            guard let tracks = try? await ListeningHistory.stationTracks(station),
                  let first = tracks.first(where: { $0.streamURL != nil }) else { return }
            if let message = await coordinator.play(first, in: tracks, collectionId: station.id) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }
}

private struct ListeningHistoryRow: View {
    let entry: ListeningHistoryEntry
    let queue: () -> [Track]
    @ObservedObject var confirmation: QueueConfirmationController

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var setlistTrack: Track?
    @State private var trimTrack: Track?

    private var track: Track { entry.track }
    private var isPlayable: Bool { track.streamURL != nil }

    private var item: SCTrackListItem {
        var item = SCTrackListItem(track: track)
        item.artist = track.publisher?.artist ?? track.user.displayName
        if let time = entry.timeText {
            item.duration = time
            item.accessibilityLabel += ", played \(time)"
        }
        return item
    }

    private var activity: SCTrackActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            Button(action: play) {
                SCTrackListRow(item: item, leading: .artwork, activity: activity, metrics: .phone, crownUser: track.user) {
                    TrackSourceMark(track: track)
                    if isPlayable {
                        TrackDownloadStatusGlyph(trackId: track.id)
                    }
                }
                .contentShape(.hoverEffect, .rect(cornerRadius: Radius.sm))
                .hoverEffect(.highlight)
            }
            .disabled(!isPlayable)
            .buttonStyle(WarmStreamOnPressButtonStyle(track: track))

            SCTrackListMoreMenu(title: track.title) {
                menuItems
                share
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in SCTrackListMetrics.phone.artworkSize + SCTrackListMetrics.phone.spacing }
        .trackDragSource(track)
        .libraryRowPreviewShape()
        .contextMenu {
            menuItems
            share
        }
        .trackActionSheets(setlist: $setlistTrack, trim: $trimTrack)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isPlayable {
                Button(action: addToQueue) {
                    Label("Add to Up Next", systemImage: "text.append")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isPlayable {
                TrackDownloadSwipeAction(track: track)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions { menuItems }
    }

    private var share: some View {
        ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private var menuItems: some View {
        TrackActionMenuItems(
            track: track,
            addToQueue: addToQueue,
            playOn: { device in
                Task {
                    if let message = await coordinator.play(track, in: queue(), on: device) {
                        confirmation.show(message, icon: "exclamationmark.triangle.fill")
                    }
                }
            },
            showSetlist: { setlistTrack = track },
            editTrim: { trimTrack = track }
        )
    }

    private func play() {
        ListeningHistory.notePlayback()
        Task {
            if let message = await coordinator.play(track, in: queue(), collectionId: ListeningHistory.collectionID) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func addToQueue() {
        coordinator.addToQueue(track)
        confirmation.show("Added \u{201C}\(track.title)\u{201D} to Up Next")
    }
}
