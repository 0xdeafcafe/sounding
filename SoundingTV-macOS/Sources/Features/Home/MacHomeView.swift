import SwiftUI
import AppKit

struct MacHomeView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var source: DiscoveryHomeSource
    @ObservedObject private var feedModel: FeedViewModel
    private let player = PlayerService.shared
    @State private var hasLoadedOnce = false
    @SceneStorage("home.surface") private var homeSurface: HomeSurface = .forYou
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var continueFrom = ContinueFrom.shared
    @State private var isShowingSignIn = false
    @State private var isHeroUnderBar = true

    private var showsContinueHero: Bool {
        homeSurface == .forYou && showsShelves && continueFrom.offer != nil
    }

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
                MacViewportScrollView {
                    if showsShelves {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            homeTitleRow
                                .padding(.bottom, SCContentStyle.mac.spaceBase)
                                .collectionScrollBackdropLead()

                            shelves
                                .padding(.bottom, 32)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            homeTitleRow

                            paneState
                        }
                    }
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .collectionScrollBackdrop(
                    url: continueFrom.offer?.session.artworkURL,
                    identity: continueFrom.offer?.session.trackID,
                    fade: Self.continueMetrics.backdropFade,
                    isPresent: showsContinueHero
                )
                .scrollEdgeEffectHidden(showsContinueHero && isHeroUnderBar, for: .top)
                .toolbarColorScheme(showsContinueHero && isHeroUnderBar ? .dark : nil, for: .windowToolbar)
            case .following:
                VStack(spacing: 0) {
                    homeTitleRow
                    MacFeedView(model: feedModel, showsHeader: false)
                }
            }
        }
        .navigationTitle("Home")
        .toolbar(removing: .title)
        .background(Color.primary.opacity(0.001))
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            await source.refreshIfStale(seed: seed)
        }
        .onChange(of: credentials.isSignedOut) { _, _ in
            Task { await source.refreshIfStale(seed: seed) }
        }
        .sheet(isPresented: $isShowingSignIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false) {
                isShowingSignIn = false
            }
        }
    }

    private var homeTitleRow: some View {
        HStack(alignment: .center, spacing: SCContentStyle.mac.spaceBase) {
            Text("Home")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 20)
            MacGlassTabs(
                "Home Feed",
                selection: $homeSurface,
                options: Array(HomeSurface.allCases),
                title: \.rawValue
            )
        }
        .macFadesUnderToolbar(over: 18)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .environment(\.colorScheme, showsContinueHero ? .dark : colorScheme)
    }

    private var seed: DiscoveryHomeSource.Seed {
        guard let track = player.currentTrack else { return DiscoveryHomeSource.Seed() }
        return DiscoveryHomeSource.Seed(track: track)
    }

    private var showsShelves: Bool {
        !source.shelves.isEmpty
    }

    @ViewBuilder
    private var paneState: some View {
        if source.isLoading || !hasLoadedOnce {
            loadingState
        } else if source.didFailCompletely {
            errorState
        } else {
            trulyEmptyState
        }
    }

    private static let continueMetrics: CollectionHeroMetrics = {
        var metrics = CollectionHeroMetrics.mac
        metrics.artworkSide = 160
        metrics.backdropFade = 96
        return metrics
    }()

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 32) {
            ContinueFromHero(metrics: Self.continueMetrics, horizontalPadding: 20)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.height > 0 && proxy.frame(in: .scrollView).maxY - Self.continueMetrics.backdropFade > 60
                } action: { isHeroUnderBar = $0 }
                .padding(.bottom, showsContinueHero ? -32 : 0)
            if showsSignedOutBanner {
                signedOutBanner
            }
            ForEach(source.shelves) { shelf in
                shelfView(shelf)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: source.shelves.map(\.id))
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
            if shelf.kind == .recent {
                SCSectionHeader(title: shelf.title, showChevron: true, action: { MacHistoryRoute.shared.open() }, style: .mac)
                    .accessibilityHint("Shows your listening history")
            } else {
                SCSectionHeader(title: shelf.title, style: .mac)
            }
            if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SCContentStyle.mac.fontCaption)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(2)
            }
        }
        .macFadesUnderToolbar()
        .padding(.horizontal, 20)
    }

    private func trackRail(_ tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(tracks) { track in
                    DiscoveryTrackTile(track: track, context: { tracks })
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(tracks.compactMap(\.artworkURL))
    }

    private func playlistRail(_ playlists: [Playlist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
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
            LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(entries) { entry in
                    switch entry {
                    case .playlist(let playlist):
                        DiscoveryPlaylistCard(playlist: playlist)
                    case .station(let station):
                        DiscoveryStationTile(station: station)
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
            LazyHStack(alignment: .top, spacing: SCContentStyle.mac.spaceGutter) {
                ForEach(users) { user in
                    DiscoveryArtistTile(user: user)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
        .prefetchArtwork(users.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
    }

    private var showsSignedOutBanner: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_WELCOME"] == "1" { return true }
        #endif
        return credentials.isSignedOut
    }

    private var signedOutBanner: some View {
        MacWelcomeHero(isActive: !isShowingSignIn) { isShowingSignIn = true }
            .padding(.horizontal, 20)
    }

    private var loadingState: some View {
        MacLoadingView()
    }

    @ViewBuilder
    private var errorState: some View {
        if source.didFailForCredentials {
            ContentUnavailableView {
                Label("Signed Out by SoundCloud", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("SoundCloud rejected this Mac’s sign-in. Sign in again to continue.")
            } actions: {
                Button("Open Account") { MacRootSelection.shared.request(.account) }
            }
            .macFillsPane()
        } else {
            ContentUnavailableView {
                Label("Couldn’t Load Home", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await source.load(seed: seed) } }
            }
            .macFillsPane()
        }
    }

    private var trulyEmptyState: some View {
        ContentUnavailableView {
            Label("Nothing Here Yet", systemImage: "sparkles")
        } description: {
            Text("SoundCloud didn’t return anything to discover right now.")
        } actions: {
            Button("Search SoundCloud") { MacRootSelection.shared.request(.search) }
        }
        .macFillsPane()
    }
}

private struct DiscoveryTrackTile: View {
    let track: Track
    let context: () -> [Track]
    private let player = PlayerService.shared
    private let playback = PlaybackIndicatorStore.shared

    private static let side: CGFloat = 160

    private var isPlayable: Bool { track.streamURL != nil }
    private var isCurrent: Bool { playback.isCurrent(track.id) }

    var body: some View {
        Button {
            guard isPlayable else { return }
            Task { await MacPlayback.play(track, in: context()) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkImage: image,
                    artIdentity: track.id,
                    isAvailable: isPlayable,
                    crownUser: track.user,
                    crownContext: track.title,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if isPlayable, isCurrent, playback.isPlaying {
                    nowPlayingBadge
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .macCardHover(
            artworkURL: track.artworkURL,
            play: isPlayable ? { Task { await MacPlayback.play(track, in: context()) } } : nil
        ) {
            MacTrackContextMenu(track: track, context: context())
        }
        .onHover { hovering in
            if hovering, isPlayable { player.preparePlayback(for: track) }
        }
        .help(isPlayable ? "" : "No playable source for this track on this account.")
        .macTrackAccessibility(track: track, context: context(), isCurrent: isCurrent && playback.isPlaying)
    }

    private var nowPlayingBadge: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(SCContentStyle.mac.spaceTight)
            .background(.black.opacity(0.45), in: Circle())
            .padding(SCContentStyle.mac.spaceTight)
            .accessibilityHidden(true)
    }
}

private struct DiscoveryStationTile: View {
    let station: SystemPlaylist

    @State private var isHydrating = false

    private static let side: CGFloat = 160
    private var entry: DiscoveryEntry { .station(station) }

    private func playStation() {
        guard !isHydrating else { return }
        isHydrating = true
        Task {
            defer { isHydrating = false }
            guard let tracks = try? await SoundCloudAPI.shared
                .getSystemPlaylistTracks(station, limit: 50),
                  let first = tracks.first(where: { $0.streamURL != nil }) else { return }
            StationLibrary.shared.record(station)
            await MacPlayback.play(first, in: tracks, collectionId: station.id, source: PlaybackQueueSource(station: station))
        }
    }

    var body: some View {
        Button(action: playStation) {
            SCArtworkResolver(url: entry.artworkURL) { image in
                SCMediaCard(
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    artworkImage: image,
                    artIdentity: entry.artIdentity,
                    artSubject: .station,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
            .overlay(alignment: .center) {
                if isHydrating { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .macCardHover(play: playStation) {
            if let url = station.permalinkURL {
                Button("Open on SoundCloud") { NSWorkspace.shared.open(url) }
                Button("Copy SoundCloud Link") { copyToPasteboard(url) }
            }
        }
        .accessibilityLabel("\(entry.cardTitle), station, \(entry.cardSubtitle)")
        .accessibilityHint("Plays the station")
        .accessibilityValue(isHydrating ? "Loading" : "")
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
                    identity: user.id,
                    diameter: Self.side,
                    crownUser: user,
                    crownContext: user.displayName,
                    style: .mac
                )
            }
        }
        .buttonStyle(.plain)
        .macCardHover(shape: .circle, play: { Task { await MacPlayback.play(user: user) } }) {
            MacArtistContextMenu(artist: user)
        }
        .accessibilityLabel("\(user.displayName), \(user.formattedFollowers) followers")
        .accessibilityHint("Opens the artist")
    }
}

private struct DiscoveryPlaylistCard: View {
    let playlist: Playlist

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
                    artIdentity: playlist.id,
                    artSubject: .collection,
                    crownUser: playlist.user,
                    crownContext: playlist.title,
                    style: .mac
                )
            }
            .frame(width: Self.side, alignment: .leading)
        }
        .buttonStyle(.plain)
        .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
            MacPlaylistContextMenu(playlist: playlist)
        }
        .accessibilityLabel("\(playlist.title), \(playlist.isAlbum ? "album" : "playlist"), \(subtitle)")
        .accessibilityHint("Opens the \(playlist.isAlbum ? "album" : "playlist")")
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

struct MacWelcomeHero: View {
    var isActive = true
    let onSignIn: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let ground = SoundingArtPalette.resolve(colorScheme).ground
        ZStack(alignment: .leading) {
            SoundingLineArt(seed: 0x4D_41_43_48, style: .banner, loop: .once, isActive: isActive && !reduceMotion)
                .accessibilityHidden(true)

            LinearGradient(
                stops: [
                    .init(color: ground, location: 0.28),
                    .init(color: ground.opacity(0), location: 0.62),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Plug in. Turn it up.")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Sign in for your likes, your listening history and mixes made for you.")
                    .font(.body)
                    .foregroundStyle(MacSecondaryStyle())
                    .fixedSize(horizontal: false, vertical: true)
                signInButton
                    .controlSize(.large)
                    .padding(.top, 10)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(28)
        }
        .frame(minHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerHero, style: .continuous))
    }

    @ViewBuilder
    private var signInButton: some View {
        if reduceTransparency {
            Button("Sign In…", action: onSignIn)
                .buttonStyle(.borderedProminent)
        } else {
            Button("Sign In…", action: onSignIn)
                .buttonStyle(.glassProminent)
        }
    }
}

struct MacOnboardingView: View {
    enum Step: Hashable {
        case welcome
        case music
    }

    let step: Step
    let onUseWithoutSoundCloud: () -> Void
    let onMusicAnswered: (_ addedFolder: Bool) -> Void

    @State private var isSigningIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let signInTint = MusicStepPage.tint

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                welcomePage
                    .transition(.push(from: .trailing))
            case .music:
                MusicStepPage(onAnswered: onMusicAnswered)
                    .frame(height: 600)
                    .transition(.push(from: .trailing))
            }
        }
        .frame(width: 520)
        .clipped()
        .animation(.smooth, value: step)
        .sheet(isPresented: $isSigningIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: false) {
                isSigningIn = false
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            SoundingWelcomeHero(seed: 0x4D_41_43_48, style: .banner, loop: .once, isActive: !reduceMotion && !isSigningIn, fadeFrom: 0.7)
                .frame(height: 210)

            welcome
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            SoundingWelcomeTitle(messageFont: .title3, messageStyle: AnyShapeStyle(MacSecondaryStyle()), spacing: 8)
            VStack(spacing: 10) {
                Button { isSigningIn = true } label: {
                    Text("Sign In with SoundCloud").frame(maxWidth: 280)
                }
                .buttonStyle(.glassProminent)
                .tint(Self.signInTint)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)

                Button(action: onUseWithoutSoundCloud) {
                    Text("Use Without SoundCloud")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Self.signInTint)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
    }
}
