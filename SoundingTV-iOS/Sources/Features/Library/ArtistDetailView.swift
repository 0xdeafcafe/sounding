import SwiftUI

struct ArtistDetailView: View {
    let user: User
    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var analysisStore = TrackAnalysisStore()
    @Namespace private var heroNamespace

    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false

    @State private var searchText = ""

    init(user: User) {
        self.user = user
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
    }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Picker("Section", selection: $viewModel.selectedSection) {
                ForEach(ArtistDetailSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .sensoryFeedback(.selection, trigger: viewModel.selectedSection)

            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSortMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    TrackSortMenu(sortKey: $sortKey, ascending: $ascending)
                }
            }
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        .task { await viewModel.loadIfNeeded() }
        .task(id: allVisibleTrackIDs) {
            await analysisStore.load(for: allVisibleTracks)
        }
        .task(id: "\(searchText)#\(viewModel.selectedSection.rawValue)") {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await loadRemainingForSearch(section: viewModel.selectedSection)
        }
        .onChange(of: viewModel.selectedSection) { _, _ in
            sortKey = .dateAdded
            ascending = false
            searchText = ""
            Task { await viewModel.loadIfNeeded() }
        }
        .queueConfirmationOverlay(confirmation)
    }

    private var searchPrompt: String {
        "Search \(viewModel.selectedSection.rawValue.lowercased())"
    }

    private func loadRemainingForSearch(section: ArtistDetailSection) async {
        var stall = 0
        while !Task.isCancelled {
            let before = sectionCount(section)
            await viewModel.loadMore(section: section)
            if sectionCount(section) == before {
                stall += 1
                if stall >= 2 { return }
            } else {
                stall = 0
            }
        }
    }

    private func sectionCount(_ section: ArtistDetailSection) -> Int {
        switch section {
        case .tracks:    return viewModel.tracks.count
        case .playlists: return viewModel.playlists.count
        case .reposts:   return viewModel.repostedTracks.count + viewModel.repostedPlaylists.count
        case .likes:     return viewModel.likedTracks.count
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                ArtworkThumbnail(
                    url: user.largeAvatarURL ?? user.avatarURL,
                    systemImage: "person.fill",
                    isCircle: true,
                    size: 76,
                    crownUser: user,
                    crownContext: user.displayName
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 7)

                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName)
                        .font(.scTitle)
                        .kerning(-0.3)
                        .lineLimit(2)
                    Text("\(user.formattedFollowers) followers \u{00B7} \(user.formattedTracks) tracks")
                        .font(.scSubhead)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let description = user.description, !description.isEmpty {
                Text(description)
                    .font(.scBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func searchAware<Content: View>(filteredEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        if !trimmedSearch.isEmpty, filteredEmpty {
            SCEmptyState(icon: "magnifyingglass", title: "No Results", message: "Nothing matched \u{201C}\(searchText)\u{201D}.", style: .phone)
        } else {
            content()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedSection {
        case .tracks:
            sectionBody(isEmpty: viewModel.tracks.isEmpty, section: .tracks) {
                searchAware(filteredEmpty: filteredTracks.isEmpty) {
                    trackRows(
                        filteredTracks,
                        onNearEnd: { Task { await viewModel.loadMore(section: .tracks) } },
                        isLoadingMore: viewModel.loadingMore.contains(.tracks)
                    )
                }
            }

        case .playlists:
            sectionBody(isEmpty: viewModel.playlists.isEmpty, section: .playlists) {
                searchAware(filteredEmpty: filteredPlaylists.isEmpty) {
                    playlistRows(
                        filteredPlaylists,
                        onNearEnd: { Task { await viewModel.loadMore(section: .playlists) } },
                        isLoadingMore: viewModel.loadingMore.contains(.playlists)
                    )
                }
            }

        case .reposts:
            sectionBody(
                isEmpty: viewModel.repostedTracks.isEmpty && viewModel.repostedPlaylists.isEmpty,
                section: .reposts
            ) {
                searchAware(filteredEmpty: filteredRepostedPlaylists.isEmpty && filteredRepostedTracks.isEmpty) {
                    if !filteredRepostedPlaylists.isEmpty {
                        playlistRows(filteredRepostedPlaylists)
                    }
                    if !filteredRepostedTracks.isEmpty {
                        trackRows(
                            filteredRepostedTracks,
                            onNearEnd: { Task { await viewModel.loadMore(section: .reposts) } },
                            isLoadingMore: viewModel.loadingMore.contains(.reposts)
                        )
                    }
                }
            }

        case .likes:
            sectionBody(isEmpty: viewModel.likedTracks.isEmpty, section: .likes) {
                searchAware(filteredEmpty: filteredLikedTracks.isEmpty) {
                    trackRows(
                        filteredLikedTracks,
                        onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                        isLoadingMore: viewModel.loadingMore.contains(.likes)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func sectionBody<Content: View>(
        isEmpty: Bool,
        section: ArtistDetailSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if viewModel.isLoading(section), isEmpty {
            LoadingState(message: "Loading \(section.rawValue.lowercased())…")
        } else if let error = viewModel.errorMessage(section), isEmpty {
            SCEmptyState(
                kind: .error, title: "Couldn't Load", message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: section) } },
                style: .phone
            )
        } else if isEmpty {
            SCEmptyState(
                icon: emptyIcon(for: section),
                title: section.rawValue,
                message: emptyMessage(for: section),
                style: .phone
            )
        } else {
            content()
        }
    }

    private func emptyIcon(for section: ArtistDetailSection) -> String {
        switch section {
        case .tracks:    return "music.note"
        case .playlists: return "music.note.list"
        case .reposts:   return "arrow.2.squarepath"
        case .likes:     return "heart"
        }
    }

    private func emptyMessage(for section: ArtistDetailSection) -> String {
        switch section {
        case .tracks:    return "\(user.displayName) hasn't uploaded any tracks."
        case .playlists: return "\(user.displayName) hasn't published any playlists."
        case .reposts:   return "\(user.displayName) hasn't reposted anything."
        case .likes:     return "\(user.displayName) hasn't publicly liked any tracks."
        }
    }

    @ViewBuilder
    private func trackRows(_ tracks: [Track], onNearEnd: @escaping () -> Void, isLoadingMore: Bool) -> some View {
        ForEach(tracks) { track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { tracks },
                confirmation: confirmation
            )
            .onAppear {
                guard trimmedSearch.isEmpty, unsortedSource(for: track).isNearEnd(track, lead: 10) else { return }
                onNearEnd()
            }
        }
        if isLoadingMore {
            LoadingMoreRow()
        }
    }

    private func unsortedSource(for track: Track) -> [Track] {
        switch viewModel.selectedSection {
        case .tracks:    return viewModel.tracks
        case .reposts:   return viewModel.repostedTracks
        case .likes:     return viewModel.likedTracks
        case .playlists: return []
        }
    }

    @ViewBuilder
    private func playlistRows(_ playlists: [Playlist], onNearEnd: (() -> Void)? = nil, isLoadingMore: Bool = false) -> some View {
        ForEach(playlists) { playlist in
            NavigationLink {
                PlaylistDetailView(playlist: playlist, heroNamespace: heroNamespace)
            } label: {
                PlaylistRow(playlist: playlist)
            }
            .matchedTransitionSource(id: playlist.id, in: heroNamespace)
            .onAppear {
                guard let onNearEnd, trimmedSearch.isEmpty, playlists.isNearEnd(playlist, lead: 10) else { return }
                onNearEnd()
            }
        }
        if isLoadingMore {
            LoadingMoreRow()
        }
    }

    private var showsSortMenu: Bool {
        switch viewModel.selectedSection {
        case .tracks: return !viewModel.tracks.isEmpty
        case .likes:  return !viewModel.likedTracks.isEmpty
        case .reposts: return !viewModel.repostedTracks.isEmpty
        case .playlists: return false
        }
    }

    private var sortedTracks: [Track] {
        TrackSort.sorted(viewModel.tracks, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
    }

    private var sortedLikedTracks: [Track] {
        TrackSort.sorted(viewModel.likedTracks, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
    }

    private var sortedRepostedTracks: [Track] {
        TrackSort.sorted(viewModel.repostedTracks, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
    }

    private func matchesTrackSearch(_ track: Track) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return track.title.scLocallyContains(trimmedSearch) || track.user.displayName.scLocallyContains(trimmedSearch)
    }

    private func matchesPlaylistSearch(_ playlist: Playlist) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return playlist.title.scLocallyContains(trimmedSearch)
    }

    private var filteredTracks: [Track] { sortedTracks.filter(matchesTrackSearch) }
    private var filteredLikedTracks: [Track] { sortedLikedTracks.filter(matchesTrackSearch) }
    private var filteredRepostedTracks: [Track] { sortedRepostedTracks.filter(matchesTrackSearch) }
    private var filteredPlaylists: [Playlist] { viewModel.playlists.filter(matchesPlaylistSearch) }
    private var filteredRepostedPlaylists: [Playlist] { viewModel.repostedPlaylists.filter(matchesPlaylistSearch) }

    private var allVisibleTracks: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for track in viewModel.tracks + viewModel.repostedTracks + viewModel.likedTracks
        where seen.insert(track.id).inserted {
            result.append(track)
        }
        return result
    }

    private var allVisibleTrackIDs: [String] { allVisibleTracks.map(\.id) }
}
