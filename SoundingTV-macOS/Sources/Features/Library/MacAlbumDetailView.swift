import SwiftUI

struct MacAlbumDetailView: View {
    let album: Playlist

    var body: some View {
        MacCollectionDetailView(playlist: album, kind: .album)
    }
}

struct MacSetsPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacLibraryModel
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showsSetlists = false

    init(model: MacLibraryModel) {
        self.model = model
    }

    var body: some View {
        if showsSetlists {
            SavedSetlistsLibraryView()
                .scrollContentBackground(.hidden)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showsSetlists = false
                        } label: {
                            Label("Sets", systemImage: "chevron.backward")
                        }
                        .help("Back to Sets")
                    }
                }
        } else {
            setsContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    SavedSetlistsCount { count in
                        if count > 0 {
                            Button {
                                showsSetlists = true
                            } label: {
                                HStack(spacing: SCContentStyle.mac.spaceSnug) {
                                    SavedSetlistsLabel(count: count)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(MacSecondaryStyle())
                                }
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                            .padding(.vertical, 6)
                        }
                    }
                }
        }
    }

    private var setTracks: [Track] {
        GeneratedLibraryCollections.sets(
            from: model.tracks,
            minimumDuration: settings.setMinimumDurationSeconds
        )
    }

    private var rows: [MacLibraryRow] {
        setTracks.map { MacLibraryRow(track: $0, analysis: model.analysis[$0.id]) }
    }

    private var setsContent: some View {
        Group {
            if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "clock.arrow.2.circlepath",
                    title: "Sets Need an Account",
                    message: "Long-form tracks from your likes appear here after you sign in.",
                    browsableRoute: .search
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.tracks.isEmpty {
                LoadingPlaceholder(.trackList(.mac), showsSyncStatus: true)
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                ContentUnavailableView {
                    Label("Sets Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
                    }
                }
                .macFillsPane()
            } else if rows.isEmpty, model.canLoadMore, !model.paginator.didFailLoadingMore, !model.paginator.isPaused {
                LoadingPlaceholder(.trackList(.mac))
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Sets",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("Liked tracks lasting \(GeneratedLibraryCollections.durationLabel(settings.setMinimumDurationSeconds)) or more show up here.")
                )
                .macFillsPane()
            } else {
                MacLibraryTable(
                    rows: rows,
                    showsArtwork: true,
                    usesCompactRows: false,
                    onLoad: { track, deck in
                        Task { try? await MacMixLoader.load(track, into: deck) }
                    },
                    onDoubleClick: { track in
                        Task { try? await MacMixLoader.load(track, into: MacDeckTrackRegistry.shared.nextAvailableDeck()) }
                    },
                    onShowSetlist: { track in
                        MacRootSelection.shared.request(setlistPage: track)
                    },
                    onAnalysisChanged: { Task { await model.refreshAnalysis(rereadStore: false) } },
                    onNearEnd: { model.loadMore() },
                    pager: model.paginator
                )
            }
        }
        .navigationTitle("Sets")
        .navigationSubtitle(rows.isEmpty ? "" : "\(rows.count)\(model.canLoadMore ? "+" : "") set\(rows.count == 1 ? "" : "s")")
        .task {
            if model.tracks.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
        .task(id: model.paginator.hasLoadedFirst) {
            await model.loadLocalRemainder()
        }
        .task(id: model.tracks.count) {
            if rows.isEmpty, model.canLoadMore, !model.paginator.didFailLoadingMore, !model.paginator.isPaused { model.loadMore() }
        }
    }
}

struct MacSetlistPageView: View {
    let route: SetlistRoute

    @ObservedObject private var store = SetlistIntelligenceStore.shared

    private var title: String {
        if let setlist = store.setlist(for: route.trackId) { return SetlistText.normalized(setlist.trackTitle) }
        return route.track?.title ?? "Setlist"
    }

    var body: some View {
        SetlistPage(route: route)
            .environment(\.setlistPlaybackActions, MacSetlistPlayback.actions)
            .scrollContentBackground(.hidden)
            .toolbar(removing: .title)
            .toolbar { MacScrolledPageTitle(title: title) }
            .onAppear { MacPageTitleVisibility.shared.isShowingPushedTitle = true }
            .onDisappear { MacPageTitleVisibility.shared.isShowingPushedTitle = false }
    }
}

@MainActor
enum MacSetlistPlayback {
    static var actions: SetlistPlaybackActions {
        SetlistPlaybackActions(
            play: { track, context in
                Task { await MacPlayback.play(track, in: context) }
            },
            playSet: { track, position in
                Task {
                    if MacNowPlayingModel.shared.track?.id != track.id {
                        await MacPlayback.play(track, in: [track])
                    }
                    MacPlaybackTimeline.shared.seek(to: position)
                }
            },
            position: { track in
                MacNowPlayingModel.shared.track?.id == track.id ? MacPlaybackTimeline.shared.position() : nil
            }
        )
    }
}
