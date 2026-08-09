import SwiftUI
import AppKit

struct MacHomeView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var source: DiscoveryHomeSource
    @ObservedObject private var feedModel: FeedViewModel
    @ObservedObject private var player = PlayerService.shared
    @State private var hasLoadedOnce = false
    @State private var homeSurface: HomeSurface = .forYou

    private enum HomeSurface: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case following = "Following"
        var id: Self { self }
    }

    init(source: DiscoveryHomeSource, feedModel: FeedViewModel) {
        self.source = source
        self.feedModel = feedModel
    }

    var body: some View {
        Group {
            switch homeSurface {
            case .forYou:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        homeTitleRow

                        content
                            .padding(.top, SCContentStyle.mac.spaceBase)
                            .padding(.bottom, 32)
                    }
                }
            case .following:
                VStack(spacing: 0) {
                    homeTitleRow
                    MacFeedView(model: feedModel, showsHeader: false)
                }
            }
        }
        .navigationTitle("")
        .toolbar(removing: .title)
        .background(Color.primary.opacity(0.001))
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            await source.refreshIfStale(seed: seed)
        }
        .onChange(of: credentials.isSignedOut) { _, _ in
            Task { await source.load(seed: seed) }
        }
    }

    private var homeTitleRow: some View {
        HStack(alignment: .center, spacing: SCContentStyle.mac.spaceBase) {
            Text("Home")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 20)
            homeSurfacePicker
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    private var homeSurfacePicker: some View {
        HStack(spacing: 3) {
            ForEach(HomeSurface.allCases) { surface in
                Button {
                    homeSurface = surface
                } label: {
                    Text(surface.rawValue)
                        .font(.system(size: 12, weight: homeSurface == surface ? .semibold : .medium))
                        .foregroundStyle(homeSurface == surface ? Color.scAccentOn : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .background(
                            homeSurface == surface ? SCContentStyle.mac.accent.opacity(0.55) : .clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(width: 190)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home feed")
    }

    private var seed: DiscoveryHomeSource.Seed {
        guard let track = player.currentTrack else { return DiscoveryHomeSource.Seed() }
        return DiscoveryHomeSource.Seed(track: track)
    }

    @ViewBuilder
    private var content: some View {
        if source.shelves.isEmpty, source.isLoading || !hasLoadedOnce {
            loadingState
        } else if source.didFailCompletely {
            errorState
        } else if source.shelves.isEmpty {
            trulyEmptyState
        } else {
            VStack(alignment: .leading, spacing: 32) {
                if credentials.isSignedOut {
                    signedOutBanner
                }
                ForEach(source.shelves) { shelf in
                    shelfView(shelf)
                }
            }
        }
    }

    @ViewBuilder
    private func shelfView(_ shelf: DiscoveryShelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader(shelf)
            switch shelf.content {
            case .tracks(let tracks):
                trackRail(tracks)
            case .playlists(let playlists):
                playlistRail(playlists)
            case .stations(let stations):
                entryRail(stations.map(DiscoveryEntry.station))
            case .users(let users):
                artistRail(users)
            case .mixed(let entries):
                entryRail(entries)
            }
        }
    }

    private func shelfHeader(_ shelf: DiscoveryShelf) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SCSectionHeader(title: shelf.title, style: .mac)
            if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SCContentStyle.mac.fontCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
    }

    private func trackRail(_ tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(tracks) { track in
                    DiscoveryTrackTile(track: track, context: { tracks }, player: player)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(tracks.compactMap(\.artworkURL))
    }

    private func playlistRail(_ playlists: [Playlist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(playlists) { playlist in
                    DiscoveryPlaylistCard(playlist: playlist)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(playlists.compactMap(\.displayArtworkURL))
    }

    @ViewBuilder
    private func entryRail(_ entries: [DiscoveryEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(entries) { entry in
                    switch entry {
                    case .playlist(let playlist):
                        DiscoveryPlaylistCard(playlist: playlist)
                    case .station(let station):
                        DiscoveryStationTile(station: station, player: player)
                    case .user(let user):
                        DiscoveryArtistTile(user: user)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(entries.compactMap(\.artworkURL))
    }

    private func artistRail(_ users: [User]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(users) { user in
                    DiscoveryArtistTile(user: user)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(users.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
    }

    private var signedOutBanner: some View {
        HStack(alignment: .center, spacing: SCContentStyle.mac.spaceSnug) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Browsing as a guest")
                    .font(SCContentStyle.mac.fontBodyEmphasis)
                    .foregroundStyle(SCContentStyle.mac.textPrimary)
                Text("Pair with your iPhone to get your likes, your listening history, and mixes made for you.")
                    .font(SCContentStyle.mac.fontCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Open Account") { MacRootSelection.shared.request(.account) }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerControl, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

    private var loadingState: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private var errorState: some View {
        if source.didFailForCredentials {
            SCEmptyState(
                kind: .error,
                title: "Signed Out by SoundCloud",
                message: "SoundCloud rejected this Mac's sign-in, so nothing could load. Re-pair with your iPhone from the Account pane if it keeps happening.",
                actionTitle: "Open Account",
                action: { MacRootSelection.shared.request(.account) },
                style: .mac
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load Home",
                message: "Couldn't reach SoundCloud's discovery feed. Check your connection and try again.",
                actionTitle: "Try Again",
                action: { Task { await source.load(seed: seed) } },
                style: .mac
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private var trulyEmptyState: some View {
        SCEmptyState(
            icon: "sparkles",
            title: "Nothing Here Yet",
            message: "SoundCloud didn\u{2019}t return anything to discover right now.",
            actionTitle: "Search SoundCloud",
            action: { MacRootSelection.shared.request(.search) },
            style: .mac
        )
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct DiscoveryTrackTile: View {
    let track: Track
    let context: () -> [Track]
    @ObservedObject var player: PlayerService

    private static let side: CGFloat = 160

    private var isPlayable: Bool { track.streamURL != nil }
    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        Button {
            guard isPlayable else { return }
            Task { await player.play(track, in: context()) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkImage: image,
                    isAvailable: isPlayable,
                    crownUser: track.user,
                    crownContext: track.title,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if isPlayable, isCurrent, player.isPlaying {
                    nowPlayingBadge
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .macHoverLift()
        .onHover { hovering in
            // Resolve while the user is deciding, not after their click.
            // This stays entirely separate from download storage and is
            // deduplicated by PlayerService.
            if hovering, isPlayable { player.warmStreamURL(for: track) }
        }
        .contextMenu { contextMenuItems }
        .help(isPlayable ? "" : "No playable source for this track on this account.")
    }

    private var nowPlayingBadge: some View {
        Image(systemName: "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(SCContentStyle.mac.spaceTight)
            .background(.black.opacity(0.45), in: Circle())
            .padding(SCContentStyle.mac.spaceTight)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isPlayable {
            Button("Play") { Task { await player.play(track, in: context()) } }
            Button("Add to Up Next") { player.addToQueue(track) }
            Divider()
        }
        Button("Copy SoundCloud Link") { copyToPasteboard(track.permalinkURL) }
    }
}

private struct DiscoveryStationTile: View {
    let station: SystemPlaylist
    @ObservedObject var player: PlayerService

    @State private var isHydrating = false

    private static let side: CGFloat = 160
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
                await PlayActions.play(tracks: tracks, startingAt: first)
            }
        } label: {
            SCArtworkResolver(url: entry.artworkURL) { image in
                SCMediaCard(
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    artworkImage: image,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
            .overlay(alignment: .center) {
                if isHydrating { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .contextMenu {
            if let url = station.permalinkURL {
                Button("Open on SoundCloud") { NSWorkspace.shared.open(url) }
                Button("Copy SoundCloud Link") { copyToPasteboard(url) }
            }
        }
    }
}

private struct DiscoveryArtistTile: View {
    let user: User

    private static let side: CGFloat = 160

    var body: some View {
        Button {
            MacRootSelection.shared.request(artist: user)
        } label: {
            SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
                SCArtistCard(
                    name: user.displayName,
                    subtitle: "\(user.formattedFollowers) followers",
                    avatarImage: image,
                    diameter: Self.side,
                    crownUser: user,
                    crownContext: user.displayName,
                    style: .mac
                )
            }
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .contextMenu {
            Button("Open on SoundCloud") { NSWorkspace.shared.open(user.permalinkURL) }
            Button("Copy SoundCloud Link") { copyToPasteboard(user.permalinkURL) }
        }
    }
}

private struct DiscoveryPlaylistCard: View {
    let playlist: Playlist

    /// Mixed rails (especially Recently Played) need one visual rhythm. A
    /// playlist should not suddenly turn into a hero tile merely because it
    /// has no cover image; that made generated fallback artwork look like a
    /// large coloured panel beside the normal 160pt cards.
    private static let side: CGFloat = 160

    private var subtitle: String {
        "\(playlist.user.displayName) · \(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")"
    }

    var body: some View {
        Button {
            MacRootSelection.shared.request(playlist: playlist)
        } label: {
            SCCollectionArtworkResolver(
                artworkURL: playlist.displayArtworkURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                variant: .standard
            ) { image in
                SCMediaCard(
                    title: playlist.title,
                    subtitle: subtitle,
                    artworkImage: image,
                    crownUser: playlist.user,
                    crownContext: playlist.title,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
        }
        .buttonStyle(.plain)
        .macHoverLift()
        .contextMenu {
            Button("Open on SoundCloud") { NSWorkspace.shared.open(playlist.permalinkURL) }
            Button("Copy SoundCloud Link") { copyToPasteboard(playlist.permalinkURL) }
        }
    }
}

enum MacCollectionCover {
    static func artworkURLs(for playlist: Playlist) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        if let own = playlist.displayArtworkURL { seen.insert(own); out.append(own) }
        for track in playlist.tracks ?? [] {
            guard let url = track.artworkURL, !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(url)
            if out.count >= 5 { break }
        }
        return out
    }

    static func artworkURLs(for activity: FeedActivity) -> [URL] {
        if let track = activity.track {
            return track.artworkURL.map { [$0] } ?? []
        }
        if let playlist = activity.playlist {
            return artworkURLs(for: playlist)
        }
        return []
    }
}

private func copyToPasteboard(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}
