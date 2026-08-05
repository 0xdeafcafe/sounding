import SwiftUI

struct PlaylistDetailView: View {
    let heroNamespace: Namespace.ID
    @StateObject private var viewModel: PlaylistDetailViewModel
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var analysisStore = TrackAnalysisStore()
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false
    @State private var isShowingCollectionPolicy = false

    init(playlist: Playlist, heroNamespace: Namespace.ID) {
        self.heroNamespace = heroNamespace
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaylistHero(playlist: viewModel.playlist, hasTracks: !viewModel.tracks.isEmpty, onPlay: play, onShuffle: shufflePlay)
            content
        }
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle(viewModel.playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !viewModel.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    TrackSortMenu(sortKey: $sortKey, ascending: $ascending)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Collection Settings", systemImage: "slider.horizontal.3") {
                    isShowingCollectionPolicy = true
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search this playlist")
        .task { await viewModel.loadIfNeeded() }
        .task(id: viewModel.tracks.map(\.id)) {
            await analysisStore.load(for: viewModel.tracks)
            DownloadManager.shared.applyCollectionPolicy(
                tracks: viewModel.tracks,
                collectionId: viewModel.playlist.id
            )
        }
        .task(id: searchText) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await loadRemainingForSearch()
        }
        .queueConfirmationOverlay(confirmation)
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: viewModel.playlist.id,
                collectionName: viewModel.playlist.title,
                collectionKind: CollectionKind.classify(playlist: viewModel.playlist),
                tracks: viewModel.tracks,
                applier: DownloadManager.shared
            )
        }
        .modifier(ZoomTransitionIfMotionAllowed(
            reduceMotion: reduceMotion, sourceID: viewModel.playlist.id, namespace: heroNamespace
        ))
    }

    private var visibleTracks: [Track] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return TrackSort.sorted(viewModel.tracks, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
        }
        let filtered = viewModel.tracks.filter {
            $0.title.scLocallyContains(needle) || $0.user.displayName.scLocallyContains(needle)
        }
        return TrackSort.sorted(filtered, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
    }

    private var isSearchIncomplete: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.tracks.count < viewModel.playlist.totalTrackCount
    }

    private func loadRemainingForSearch() async {
        var stall = 0
        while !Task.isCancelled, viewModel.tracks.count < viewModel.playlist.totalTrackCount {
            let before = viewModel.tracks.count
            await viewModel.loadMore()
            if viewModel.tracks.count == before {
                stall += 1
                if stall >= 2 { return }
            } else {
                stall = 0
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.tracks.isEmpty {
            LoadingState(message: "Loading playlist…")
        } else if let error = viewModel.errorMessage, viewModel.tracks.isEmpty {
            SCEmptyState(
                kind: .error, title: "Couldn't Load", message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.load() } },
                style: .phone
            )
        } else if viewModel.tracks.isEmpty {
            SCEmptyState(icon: "music.note.list", title: "Empty Playlist",
                         message: "This playlist has no tracks.", style: .phone)
        } else if visibleTracks.isEmpty, isSearchIncomplete {
            LoadingState(message: "Searching the rest of the playlist…")
        } else if visibleTracks.isEmpty {
            SCEmptyState(
                icon: "magnifyingglass",
                title: "No Results",
                message: "Nothing matched \u{201C}\(searchText)\u{201D}.",
                style: .phone
            )
        } else {
            List {
                ForEach(visibleTracks) { track in
                    TrackListRow(
                        track: track,
                        analysis: analysisStore.summaries[track.id],
                        context: { visibleTracks },
                        collectionId: viewModel.playlist.id,
                        confirmation: confirmation
                    )
                    .onAppear {
                        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              viewModel.tracks.isNearEnd(track, lead: 10) else { return }
                        Task { await viewModel.loadMore() }
                    }
                }
                if viewModel.isLoadingMore {
                    LoadingMoreRow()
                }
            }
            .listStyle(.plain)
        }
    }

    private func play() {
        guard let first = viewModel.tracks.first else { return }
        Task { await coordinator.playHere(first, in: viewModel.tracks, collectionId: viewModel.playlist.id) }
    }

    private func shufflePlay() {
        guard !viewModel.tracks.isEmpty else { return }
        Task { await coordinator.playHere(shuffled: viewModel.tracks, collectionId: viewModel.playlist.id) }
    }
}

private struct PlaylistHero: View {
    let playlist: Playlist
    let hasTracks: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ArtworkThumbnail(
                    url: playlist.artworkURL,
                    systemImage: "music.note.list",
                    size: 84,
                    cornerRadius: Corner.thumb,
                    crownUser: playlist.user,
                    crownContext: playlist.title
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 7)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.scTitle)
                        .kerning(-0.3)
                        .lineLimit(2)
                    Text("\(playlist.totalTrackCount) tracks \u{00B7} \(playlist.user.displayName)")
                        .font(.scSubhead)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.sm) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.scAccent)

                Button(action: onShuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.scAccent)
            }
            .controlSize(.large)
            .disabled(!hasTracks)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }
}

private struct ZoomTransitionIfMotionAllowed: ViewModifier {
    let reduceMotion: Bool
    let sourceID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}
