import SwiftUI

struct TVHistoryView: View {
    var isSearchPage = false

    @ObservedObject private var history = ListeningHistory.shared
    @EnvironmentObject private var playerService: PlayerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var showsSearch = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let visible = ListeningHistoryMerge.filtered(history.entries, search: searchText)
        let queue = ListeningHistoryMerge.queue(visible)
        Group {
            if history.entries.isEmpty {
                VStack(alignment: .leading, spacing: Space.section) {
                    LibraryDetailHeader(title: LibraryFilter.history.label, subtitle: nil)
                    ListeningHistoryStatusView(phase: history.phase) {
                        Task { await history.load(force: true) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, SCBrowseMetrics.contentTopInset)
                .padding(.bottom, Space.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Space.section) {
                        header(queue: queue.filter { $0.streamURL != nil })
                        content(visible, queue: queue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, SCBrowseMetrics.contentTopInset)
                    .padding(.bottom, Space.section)
                    .animation(reduceMotion ? nil : .snappy, value: history.revision)
                }
                .scrollClipDisabled()
            }
        }
        .tvListSearchable(isSearchPage, text: $searchText, prompt: "Search History")
        .tvListSearchCover(isPresented: $showsSearch) {
            TVHistoryView(isSearchPage: true)
        }
        .task { await history.load() }
    }

    private func header(queue: [Track]) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            LibraryDetailHeader(title: LibraryFilter.history.label, subtitle: nil)
            HStack(spacing: Space.snug) {
                if !queue.isEmpty {
                    Button {
                        ListeningHistory.notePlayback()
                        Task { await PlayActions.play(tracks: queue, collectionId: ListeningHistory.collectionID) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("history.play")

                    Button {
                        ListeningHistory.notePlayback()
                        Task { await PlayActions.shufflePlay(tracks: queue, collectionId: ListeningHistory.collectionID) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .accessibilityIdentifier("history.shuffle")
                }
                if !isSearchPage {
                    Button {
                        showsSearch = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("history.search")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .focusSection()
        }
    }

    @ViewBuilder
    private func content(_ visible: [ListeningHistoryEntry], queue: [Track]) -> some View {
        if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 600)
                .remoteFocusTarget()
        } else {
            if !isSearching, !history.collections.isEmpty {
                VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                    Text("Recently Played Collections")
                        .font(.tvSection)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    EntryShelf(entries: history.collections.map(\.entry), identifierPrefix: "history.collections")
                        .frame(height: LibraryShelfMetrics.tileShelfHeight, alignment: .top)
                }
                .focusSection()
            }

            ForEach(ListeningHistoryMerge.days(visible)) { day in
                VStack(alignment: .leading, spacing: Space.snug) {
                    Text(day.title)
                        .font(.tvSection)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(spacing: Space.hair) {
                        ForEach(day.entries) { entry in
                            row(entry, queue: queue, visible: visible)
                        }
                    }
                }
                .focusSection()
            }

            if history.hasMore, !isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .onAppear { history.loadMore() }
            }
        }
    }

    private func row(_ entry: ListeningHistoryEntry, queue: [Track], visible: [ListeningHistoryEntry]) -> some View {
        let track = entry.track
        var item = SCTrackListItem(track: track)
        item.artist = track.publisher?.artist ?? track.user.displayName
        if let time = entry.timeText {
            item.duration = time
            item.accessibilityLabel += ", played \(time)"
        }
        return Button {
            guard track.streamURL != nil else { return }
            ListeningHistory.notePlayback()
            Task { await playerService.play(track, in: queue, collectionId: ListeningHistory.collectionID, source: ListeningHistory.queueSource) }
        } label: {
            SCTrackListRow(item: item, leading: .artwork, activity: activity(for: track), metrics: .tvDense, crownUser: track.user)
        }
        .buttonStyle(TVCollectionRowStyle())
        .accessibilityLabel(item.accessibilityLabel)
        .prewarmPlaybackOnFocus(track)
        .onAppear {
            if !isSearching, visible.isNearEnd(entry, lead: 12) { history.loadMore() }
        }
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }
}
