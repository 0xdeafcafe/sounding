import SwiftUI

struct WatchHomeView: View {
    @StateObject private var source = DiscoveryHomeSource()
    @State private var hasLoadedOnce = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WatchStyle.style.spaceSection) {
                if source.shelves.isEmpty {
                    emptyContent
                } else {
                    ForEach(source.shelves) { shelf in
                        WatchHomeShelf(shelf: shelf)
                    }
                }
            }
            .padding(.horizontal, WatchStyle.style.spaceSnug)
            .padding(.bottom, WatchStyle.style.spaceRoomy)
        }
        .navigationTitle("Listen Now")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
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
            WatchLoadingRow()
        } else if source.didFailForCredentials {
            WatchEmptyState(
                systemImage: "person.crop.circle.badge.xmark",
                title: "Signed Out",
                message: "SoundCloud dropped this session. Re-link from Settings."
            )
        } else if source.didFailCompletely {
            WatchEmptyState(
                systemImage: "wifi.slash",
                title: "Couldn't Load",
                message: "Check your connection and try again."
            )
        } else {
            WatchEmptyState(
                systemImage: "sparkles",
                title: "Nothing Here Yet",
                message: "Play something on iPhone to get picks."
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
        VStack(alignment: .leading, spacing: WatchStyle.style.spaceTight) {
            WatchSectionHeader(title: shelf.title)

            switch shelf.content {
            case .tracks(let tracks):
                ForEach(tracks.prefix(6)) { track in
                    WatchHomeTrackCard(track: track)
                }
            default:
                ForEach(shelf.content.entries.prefix(6)) { entry in
                    WatchHomeEntryCard(entry: entry)
                }
            }
        }
    }
}

private struct WatchHomeTrackCard: View {
    let track: Track
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        Button {
            link.play(trackId: track.id)
        } label: {
            WatchHomeCard(
                artworkURL: track.largeArtworkURL ?? track.artworkURL,
                title: track.title,
                subtitle: track.user.displayName,
                trailingSystemImage: link.nowPlaying.trackId == track.id ? "waveform" : "play.fill"
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WatchHomeEntryCard: View {
    let entry: DiscoveryEntry
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        switch entry {
        case .playlist(let playlist):
            Button {
                link.play(collectionId: playlist.id)
            } label: {
                WatchHomeCard(
                    artworkURL: playlist.largeArtworkURL ?? playlist.artworkURL,
                    title: playlist.title,
                    subtitle: playlist.user.displayName,
                    trailingSystemImage: "play.fill"
                )
            }
            .buttonStyle(.plain)
        case .station(let station):
            Button {
                link.play(collectionId: station.id)
            } label: {
                WatchHomeCard(
                    artworkURL: station.artworkURL,
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    trailingSystemImage: "dot.radiowaves.left.and.right"
                )
            }
            .buttonStyle(.plain)
        case .user(let user):
            NavigationLink {
                WatchArtistDetailView(user: user)
            } label: {
                WatchHomeCard(
                    artworkURL: user.largeAvatarURL ?? user.avatarURL,
                    title: user.displayName,
                    subtitle: "\(user.formattedFollowers) followers"
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct WatchHomeCard: View {
    let artworkURL: URL?
    let title: String
    let subtitle: String?
    var trailingSystemImage: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SCArtworkResolver(url: artworkURL) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(WatchStyle.style.bgOverlay)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(WatchStyle.style.textTertiary)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0)],
                startPoint: .bottom,
                endPoint: .center
            )

            HStack(alignment: .bottom, spacing: WatchStyle.style.spaceTight) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(WatchStyle.style.fontBodyEmphasis)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(WatchStyle.style.fontCaption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(WatchStyle.style.spaceSnug)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.4, contentMode: .fit)
        .background(WatchStyle.style.bgOverlay)
        .clipShape(RoundedRectangle(cornerRadius: WatchStyle.style.cornerHero, style: .continuous))
    }
}
