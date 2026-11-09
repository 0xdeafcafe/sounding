import SwiftUI
import AppKit

@MainActor
final class MacHistoryRoute: ObservableObject {
    static let shared = MacHistoryRoute()

    @Published private(set) var requests = 0

    private init() {}

    func open() { requests &+= 1 }
}

struct MacHistoryView: View {
    @ObservedObject private var history = ListeningHistory.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var findFocus = MacFindFocus.shared
    @State private var searchText = ""
    @State private var isSearchPresented = false

    private static let tileSide: CGFloat = 160

    private var visible: [ListeningHistoryEntry] {
        ListeningHistoryMerge.filtered(history.entries, search: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let visible = self.visible
        Group {
            if history.entries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header(queue: [])
                        .padding(SCContentStyle.mac.spaceGutter)
                    ListeningHistoryStatusView(phase: history.phase) {
                        Task { await history.load(force: true) }
                    }
                }
            } else {
                MacViewportScrollView {
                    LazyVStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                        header(queue: ListeningHistoryMerge.queue(visible).filter { $0.streamURL != nil })
                        if visible.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .frame(maxWidth: .infinity, minHeight: 320)
                        } else {
                            if !isSearching, !history.collections.isEmpty {
                                collectionsShelf
                            }
                            ForEach(ListeningHistoryMerge.days(visible)) { day in
                                daySection(day, queue: ListeningHistoryMerge.queue(visible))
                            }
                            if history.hasMore, !isSearching {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .onAppear { history.loadMore() }
                            }
                        }
                    }
                    .padding(SCContentStyle.mac.spaceGutter)
                    .animation(reduceMotion ? nil : .snappy, value: history.revision)
                }
            }
        }
        .macFillsPane()
        .navigationTitle("History")
        .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Search History")
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .task { await history.load() }
    }

    private func header(queue: [Track]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("History")
                .font(.largeTitle.weight(.bold))
            Spacer(minLength: 12)
            GlassEffectContainer {
                HStack(spacing: 8) {
                    Button {
                        play(queue.first, in: queue)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(queue.isEmpty)

                    Button {
                        Task {
                            ListeningHistory.notePlayback()
                            await MacPlayback.shuffle(queue, collectionId: ListeningHistory.collectionID, source: ListeningHistory.queueSource)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.glass)
                    .disabled(queue.count < 2)
                }
            }
        }
        .macFadesUnderToolbar()
    }

    private var collectionsShelf: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
            SCSectionHeader(title: "Recently Played Collections", style: .mac)
                .macFadesUnderToolbar()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                    ForEach(history.collections) { collection in
                        collectionTile(collection)
                    }
                }
            }
            .scrollClipDisabled()
            .prefetchArtwork(history.collections.compactMap(\.entry.artworkURL))
        }
    }

    @ViewBuilder
    private func collectionTile(_ collection: ListeningHistoryCollection) -> some View {
        let card = ListeningHistoryCollectionCard(collection: collection, style: .mac, side: Self.tileSide)
        switch collection.entry {
        case .playlist(let playlist):
            Button {
                MacRootSelection.shared.request(playlist: playlist)
            } label: {
                card
            }
            .buttonStyle(.plain)
            .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                MacPlaylistContextMenu(playlist: playlist)
            }
        case .station(let station):
            Button { playStation(station) } label: { card }
                .buttonStyle(.plain)
                .macCardHover(play: { playStation(station) }) {
                    if let url = station.permalinkURL {
                        Button("Open on SoundCloud") { NSWorkspace.shared.open(url) }
                    }
                }
                .accessibilityHint("Plays the station")
        case .user(let user):
            Button {
                MacRootSelection.shared.request(artist: user)
            } label: {
                card
            }
            .buttonStyle(.plain)
            .macCardHover(shape: .circle, play: { Task { await MacPlayback.play(user: user) } }) {
                MacArtistContextMenu(artist: user)
            }
        }
    }

    private func daySection(_ day: ListeningHistoryDay, queue: [Track]) -> some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
            SCSectionHeader(title: day.title, style: .mac)
                .macFadesUnderToolbar()
            VStack(spacing: 0) {
                ForEach(day.entries) { entry in
                    MacHistoryRow(entry: entry, queue: queue)
                        .macFadesUnderToolbar(over: 20)
                }
            }
        }
    }

    private func play(_ track: Track?, in queue: [Track]) {
        guard let track else { return }
        ListeningHistory.notePlayback()
        Task { await MacPlayback.play(track, in: queue, collectionId: ListeningHistory.collectionID, source: ListeningHistory.queueSource) }
    }

    private func playStation(_ station: SystemPlaylist) {
        Task {
            guard let tracks = try? await ListeningHistory.stationTracks(station),
                  let first = tracks.first(where: { $0.streamURL != nil }) else { return }
            await MacPlayback.play(first, in: tracks, collectionId: station.id, source: PlaybackQueueSource(station: station))
        }
    }
}

private struct MacHistoryRow: View {
    let entry: ListeningHistoryEntry
    let queue: [Track]

    private let playback = PlaybackIndicatorStore.shared
    @State private var isHovered = false

    private var track: Track { entry.track }

    private var item: SCTrackListItem {
        var item = SCTrackListItem(track: track)
        item.artist = track.publisher?.artist ?? track.user.displayName
        if let time = entry.timeText { item.duration = time }
        return item
    }

    private var activity: SCTrackActivity {
        guard playback.isCurrent(track.id) else { return .none }
        if playback.isLoading { return .loading }
        return playback.isPlaying ? .playing : .paused
    }

    var body: some View {
        HStack(spacing: SCContentStyle.mac.spaceTight) {
            SCTrackListRow(item: item, leading: .artwork, activity: activity, metrics: .mac, crownUser: track.user)
            SCTrackListMoreMenu(title: track.title, size: 28) {
                MacTrackContextMenu(track: track, context: queue)
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, MacTrackTableMetrics.rowInset)
        .background {
            RoundedRectangle(cornerRadius: MacTrackTableMetrics.rowCorner, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .padding(.horizontal, -MacTrackTableMetrics.rowInset)
        .onTapGesture(count: 2) {
            guard track.streamURL != nil else { return }
            ListeningHistory.notePlayback()
            Task { await MacPlayback.play(track, in: queue, collectionId: ListeningHistory.collectionID, source: ListeningHistory.queueSource) }
        }
        .contextMenu {
            MacTrackContextMenu(track: track, context: queue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([macTrackAccessibilityLabel(track, isCurrent: playback.isCurrent(track.id)), entry.timeText.map { "played \($0)" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: "Play") {
            guard track.streamURL != nil else { return }
            Task { await MacPlayback.play(track, in: queue, collectionId: ListeningHistory.collectionID, source: ListeningHistory.queueSource) }
        }
    }
}
