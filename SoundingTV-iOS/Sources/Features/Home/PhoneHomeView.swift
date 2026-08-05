import SwiftUI

struct PhoneHomeView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @EnvironmentObject private var polyphony: PolyphonyController
    @StateObject private var source = DiscoveryHomeSource()
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var heroNamespace

    @State private var isSigningIn = false

    var body: some View {
        Group {
            if credentials.isSignedOut {
                signedOutContent
            } else {
                content
            }
        }
        .safeAreaInset(edge: .top) { AppleTVBanner() }
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PolyphonyView()
                } label: {
                    Image(systemName: polyphony.isSpeaker || polyphony.isLeading
                        ? "point.3.connected.trianglepath.dotted"
                        : "point.3.connected.trianglepath.dotted")
                }
                .accessibilityLabel("Polyphony")
            }
            ToolbarItem(placement: .topBarTrailing) {
                AccountAvatarButton()
            }
        }
        .fullScreenCover(isPresented: $isSigningIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isSigningIn = false
                }
            }
        }
        .task {
            credentials.refreshFromStore()
            await source.refreshIfStale(seed: seed)
        }
        .onChange(of: credentials.isSignedOut) { _, _ in
            Task { await source.load(seed: seed) }
        }
    }

    private var seed: DiscoveryHomeSource.Seed {
        guard let snapshot = coordinator.nowPlaying else { return .init() }
        return .init(trackID: snapshot.trackId, trackTitle: snapshot.title)
    }

    @ViewBuilder
    private var signedOutContent: some View {
        if source.shelves.isEmpty && source.isLoading {
            loadingState
        } else if source.shelves.isEmpty {
            SCEmptyState(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Explore as a Guest",
                message: "Search and public pages are available now. Please sign in for personalized picks and saving.",
                actionTitle: "Sign In",
                action: { isSigningIn = true },
                style: .phone
            )
        } else {
            shelfList
        }
    }

    private var signedOutBanner: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(alignment: .top, spacing: Space.snug) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Color.scTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browsing as a guest")
                        .font(.scHeadline)
                        .foregroundStyle(Color.scTextPrimary)
                    Text("Sign in for mixes made for you, your likes and what you were listening to.")
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                isSigningIn = true
            } label: {
                Text("Sign In with SoundCloud")
                    .font(.scHeadline)
                    .foregroundStyle(Color.scAccentOn)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.scAccentGradient, in: Capsule())
            }
            .buttonStyle(BouncyPressStyle(reduceMotion: reduceMotion))
            .accessibilityHint("Signs in to SoundCloud on this iPhone")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scCard()
        .padding(.horizontal, Space.roomy)
    }

    @ViewBuilder
    private var content: some View {
        if source.didFailForCredentials {
            SCEmptyState(
                kind: .error,
                title: "Signed Out by SoundCloud",
                message: "SoundCloud rejected this iPhone's sign-in, so nothing could load. If it keeps happening, sign in again from Settings.",
                actionTitle: "Try Again",
                action: { Task { await source.load(seed: seed) } },
                style: .phone
            )
        } else if source.didFailCompletely {
            SCEmptyState(
                kind: .error,
                title: "Couldn't Load Home",
                message: "Couldn't reach SoundCloud. Check your connection and try again.",
                actionTitle: "Try Again",
                action: { Task { await source.load(seed: seed) } },
                style: .phone
            )
        } else if source.shelves.isEmpty && source.isLoading {
            loadingState
        } else if source.shelves.isEmpty {
            SCEmptyState(
                icon: "sparkles",
                title: "Nothing Here Yet",
                message: "Play and like a few tracks and Home fills up with picks made for you.",
                style: .phone
            )
        } else {
            shelfList
        }
    }

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 60)
            ProgressView()
                .controlSize(.large)
            Text("Loading your picks…")
                .font(.scSubhead)
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    private var shelfList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Space.section) {
                if credentials.isSignedOut {
                    signedOutBanner
                }
                ForEach(source.shelves) { shelf in
                    HomeShelfView(shelf: shelf, heroNamespace: heroNamespace)
                }
            }
            .padding(.top, Space.tight)
            .padding(.bottom, PhoneChrome.floatingClearance)
        }
        .refreshable { await source.load(seed: seed) }
    }
}

private struct HomeShelfView: View {
    let shelf: DiscoveryShelf
    let heroNamespace: Namespace.ID

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    private static let tileSize: CGFloat = 157

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            VStack(alignment: .leading, spacing: 2) {
                SCSectionHeader(title: shelf.title, titleLineLimit: nil, style: .phoneSectionHeader)
                if let subtitle = shelf.subtitle {
                    Text(subtitle)
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, Space.roomy)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Space.snug) {
                    switch shelf.content {
                    case .tracks(let tracks):
                        ForEach(tracks) { track in
                            trackTile(track, context: tracks)
                        }
                    case .playlists(let playlists):
                        ForEach(playlists) { playlist in
                            playlistTile(playlist)
                        }
                    case .stations(let stations):
                        ForEach(stations.map(DiscoveryEntry.station)) { entry in
                            entryTile(entry)
                        }
                    case .users(let users):
                        ForEach(users) { user in
                            artistTile(user)
                        }
                    case .mixed(let entries):
                        ForEach(entries) { entry in
                            entryTile(entry)
                        }
                    }
                }
                .padding(.horizontal, Space.roomy)
            }
            .scrollClipDisabled()
            .prefetchArtwork(artworkURLs)
        }
    }

    private var artworkURLs: [URL] {
        switch shelf.content {
        case .tracks(let tracks):
            return tracks.compactMap(\.artworkURL)
        case .playlists(let playlists):
            return playlists.compactMap(\.artworkURL)
        case .stations(let stations):
            return stations.compactMap { DiscoveryEntry.station($0).artworkURL }
        case .users(let users):
            return users.compactMap { $0.largeAvatarURL ?? $0.avatarURL }
        case .mixed(let entries):
            return entries.compactMap(\.artworkURL)
        }
    }

    private func trackTile(_ track: Track, context: [Track]) -> some View {
        Button {
            Task { await coordinator.playHere(track, in: context) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkImage: image,
                    isAvailable: track.streamURL != nil,
                    style: .phone
                )
            }
            .kyleCrowned(user: track.user, context: track.title)
            .frame(width: Self.tileSize)
        }
        .buttonStyle(.plain)
        .disabled(track.streamURL == nil)
        .accessibilityLabel("\(track.title) by \(track.user.displayName)")
    }

    private func playlistTile(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist, heroNamespace: heroNamespace)
        } label: {
            SCArtworkResolver(url: playlist.artworkURL) { image in
                SCMediaCard(
                    title: playlist.title,
                    subtitle: playlist.user.displayName,
                    artworkImage: image,
                    style: .phone
                )
            }
            .kyleCrowned(user: playlist.user, context: playlist.title)
            .frame(width: Self.tileSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(playlist.title), playlist by \(playlist.user.displayName)")
    }

    @ViewBuilder
    private func entryTile(_ entry: DiscoveryEntry) -> some View {
        switch entry {
        case .playlist(let playlist): playlistTile(playlist)
        case .station(let station): StationTile(station: station, tileSize: Self.tileSize)
        case .user(let user): artistTile(user)
        }
    }

    private func artistTile(_ user: User) -> some View {
        NavigationLink {
            ArtistDetailView(user: user)
        } label: {
            SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
                SCArtistCard(
                    name: user.displayName,
                    subtitle: "\(user.formattedFollowers) followers",
                    avatarImage: image,
                    diameter: Self.tileSize,
                    style: .phone
                )
            }
            .kyleCrowned(user: user, context: user.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(user.displayName), artist")
    }
}

private struct StationTile: View {
    let station: SystemPlaylist
    let tileSize: CGFloat

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var isHydrating = false

    private var entry: DiscoveryEntry { .station(station) }

    var body: some View {
        Button {
            guard !isHydrating else { return }
            isHydrating = true
            Task {
                defer { isHydrating = false }
                guard let tracks = try? await SoundCloudAPI.shared
                    .getSystemPlaylistTracks(station, limit: 50),
                      let first = tracks.first(where: { $0.streamURL != nil }) else { return }
                await coordinator.playHere(first, in: tracks)
            }
        } label: {
            SCArtworkResolver(url: entry.artworkURL) { image in
                SCMediaCard(
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    artworkImage: image,
                    style: .phone
                )
            }
            .frame(width: tileSize)
            .overlay(alignment: .center) {
                if isHydrating { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.cardTitle), station")
    }
}
