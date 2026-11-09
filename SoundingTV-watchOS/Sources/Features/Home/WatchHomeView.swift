import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var credentials: WatchCredentialSource
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var source = HomeStore.shared.forYou
    @State private var hasLoadedOnce = false

    var body: some View {
        List {
            WatchContinueFromSection()
            ForEach(source.shelves) { shelf in
                WatchHomeShelf(shelf: shelf)
            }
        }
        .overlay {
            if source.shelves.isEmpty, link.continueOffer == nil {
                emptyContent
            }
        }
        .navigationTitle("Listen Now")
        .watchNavigationTint()
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            await source.refreshIfStale()
        }
        .refreshable {
            await source.load()
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if source.isLoading || !hasLoadedOnce {
            WatchLoadingState()
        } else if source.didFailForCredentials {
            ContentUnavailableView {
                Label("Signed Out", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text("Open Sounding on iPhone to sign in again.")
            } actions: {
                Button("Try Again") {
                    Task {
                        await credentials.adoptFromPhone()
                        await source.load()
                    }
                }
                .buttonStyle(.glass)
            }
        } else if source.didFailCompletely {
            WatchErrorState(message: "Check your connection.") {
                Task { await source.load() }
            }
        } else {
            ContentUnavailableView(
                "Nothing Yet",
                systemImage: "sparkles",
                description: Text("Play something on iPhone first.")
            )
        }
    }
}

private extension DiscoveryShelf.Content {
    var entries: [DiscoveryEntry] {
        switch self {
        case .tracks:
            return []
        case .playlists(let playlists):
            return playlists.map(DiscoveryEntry.playlist)
        case .stations(let stations):
            return stations.map(DiscoveryEntry.station)
        case .users(let users):
            return users.map(DiscoveryEntry.user)
        case .mixed(let entries):
            return entries
        }
    }
}

private struct WatchHomeShelf: View {
    let shelf: DiscoveryShelf

    var body: some View {
        Section(shelf.title) {
            switch shelf.content {
            case .tracks(let tracks):
                ForEach(tracks.prefix(5)) { track in
                    WatchHomeTrackRow(track: track)
                }
            default:
                ForEach(shelf.content.entries.prefix(5)) { entry in
                    WatchHomeEntryRow(entry: entry)
                }
            }
        }
    }
}

private struct WatchHomeTrackRow: View {
    let track: Track
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        Button {
            link.play(trackId: track.id)
        } label: {
            WatchTrackRow(
                title: track.title,
                subtitle: track.user.displayName,
                artIdentity: track.id,
                artworkURL: track.artworkURL,
                duration: track.duration,
                isPlaying: link.nowPlaying.trackId == track.id
            )
        }
        .watchQueueActions(trackId: track.id)
    }
}

private struct WatchHomeEntryRow: View {
    let entry: DiscoveryEntry
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        switch entry {
        case .playlist(let playlist):
            NavigationLink {
                WatchPlaylistDetailView(playlist: playlist)
            } label: {
                WatchTrackRow(
                    title: playlist.title,
                    subtitle: playlist.user.displayName,
                    artIdentity: playlist.id,
                    artworkURL: playlist.artworkURL
                )
            }
        case .station(let station):
            Button {
                link.play(collectionId: station.id)
            } label: {
                WatchTrackRow(
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle ?? "Station",
                    artworkURL: station.artworkURL
                )
            }
            .accessibilityHint("Plays this station")
        case .user(let user):
            NavigationLink {
                WatchArtistDetailView(user: user)
            } label: {
                WatchTrackRow(
                    title: user.displayName,
                    subtitle: "\(user.formattedFollowers) followers",
                    artIdentity: user.id,
                    artworkURL: user.largeAvatarURL ?? user.avatarURL,
                    isCircular: true
                )
            }
        }
    }
}
