import SwiftUI

struct RemoteMusicShelf: View {
    let tracks: [Track]
    var identifierPrefix = "library.yourMusic"

    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @EnvironmentObject var playerService: PlayerService

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    RemoteMusicTile(
                        track: track,
                        subtitle: remoteMusic.sourceLabel(for: track),
                        isAvailable: remoteMusic.isAvailable(track)
                    ) {
                        Task { await playerService.play(track, in: tracks.filter(remoteMusic.isAvailable)) }
                    }
                    .frame(width: SCBrowseMetrics.tileEdge)
                    .accessibilityIdentifier("\(identifierPrefix).card.\(index)")
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
        .focusEffectDisabled()
        .prefetchArtwork(tracks.compactMap(\.artworkURL))
    }
}

struct RemoteMusicTile: View {
    let track: Track
    let subtitle: String?
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if isAvailable { action() }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: subtitle,
                    artworkImage: image,
                    artIdentity: track.id,
                    isAvailable: isAvailable,
                    style: SCBrowseMetrics.tile
                )
            }
        }
        .accessibilityLabel(TrackAccessibility.label(
            title: track.title,
            artist: [track.user.displayName, subtitle].compactMap { $0 }.joined(separator: ", "),
            duration: track.formattedDuration,
            isUnavailable: !isAvailable
        ))
    }
}

struct RemoteMusicDetailView: View {
    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @State private var isLinking = false
    @Environment(\.libraryGridColumns) private var columns
    #if DEBUG
    @MainActor private static var didAutoplay = false
    #endif

    var body: some View {
        Group {
            if remoteMusic.allTracks.isEmpty {
                if remoteMusic.loadingDeviceIds.isEmpty {
                    statePage {
                        ContentUnavailableView {
                            Label(LibraryFilter.yourMusic.emptyTitle, systemImage: LibraryFilter.yourMusic.icon)
                        } description: {
                            Text(LibraryFilter.yourMusic.emptyMessage)
                        } actions: {
                            stateActions
                        }
                    }
                } else {
                    TVLibraryPage(
                        title: LibraryFilter.yourMusic.label,
                        state: .loading(.columns(columns, spacing: SCBrowseMetrics.gutter))
                    ) {
                        EmptyView()
                    }
                }
            } else if remoteMusic.availableTracks.isEmpty {
                statePage { offline }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            remoteMusic.refreshIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_MUSIC_PLAY"] == "1", !Self.didAutoplay,
               !remoteMusic.availableTracks.isEmpty {
                Self.didAutoplay = true
                Task { await PlayActions.play(tracks: remoteMusic.availableTracks, collectionId: nil) }
            }
            #endif
        }
        .fullScreenCover(isPresented: $isLinking) {
            QRCodeLoginView(onClose: { isLinking = false }, purpose: .companion)
        }
    }

    private func statePage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.section) {
            LibraryDetailHeader(title: LibraryFilter.yourMusic.label, subtitle: nil)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, SCBrowseMetrics.contentTopInset)
    }

    @ViewBuilder
    private var stateActions: some View {
        Button("Link a Device") { isLinking = true }
            .accessibilityIdentifier("library.yourMusic.link")
        if !authService.isAuthenticated {
            Button("Sign In to SoundCloud") { navigationState.isSigningIn = true }
                .accessibilityIdentifier("library.yourMusic.signIn")
        }
    }

    @ViewBuilder
    private var offline: some View {
        let devices = remoteMusic.orderedDevices.filter { !($0.catalog?.tracks.isEmpty ?? true) }
        if devices.count == 1, let device = devices.first {
            ContentUnavailableView {
                Label(device.unavailableTitle, systemImage: device.symbolName)
            } description: {
                Text(device.unavailableMessage)
            } actions: {
                stateActions
            }
        } else {
            ContentUnavailableView {
                Label("Your Devices Aren't Available", systemImage: "music.note.house")
            } description: {
                Text("Open Sounding on your Mac, iPhone or iPad on this network.")
            } actions: {
                stateActions
            }
        }
    }

    private var content: some View {
        TVLibraryPage(title: LibraryFilter.yourMusic.label, subtitle: total, state: .ready) {
            HStack(spacing: Space.base) {
                Button {
                    Task { await PlayActions.play(tracks: remoteMusic.availableTracks, collectionId: nil) }
                } label: {
                    TVGlassPillLabel(title: "Play", systemImage: "play.fill")
                }
                .buttonStyle(TVGlassPillStyle(isProminent: true))
                .accessibilityIdentifier("library.yourMusic.play")

                Button {
                    Task { await PlayActions.shufflePlay(tracks: remoteMusic.availableTracks, collectionId: nil) }
                } label: {
                    TVGlassPillLabel(title: "Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityIdentifier("library.yourMusic.shuffle")
            }
            .focusSection()
        } content: {
            ForEach(remoteMusic.orderedDevices) { device in
                section(device)
            }
        }
    }

    @ViewBuilder
    private func section(_ device: RemoteLocalMusic.Device) -> some View {
        let tracks = remoteMusic.tracksByDevice[device.id] ?? []
        let available = remoteMusic.isAvailable(device)
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Label(device.sourceLabel, systemImage: device.symbolName)
                        .font(SCBrowseMetrics.header.fontTitle)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(available ? countText(tracks.count) : device.unavailableMessage)
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                }
                LazyVGrid(columns: LibraryPageMetrics.grid(columns), alignment: .leading, spacing: Space.section) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        let playable = available || remoteMusic.isAvailable(track)
                        RemoteMusicTile(track: track, subtitle: track.user.displayName, isAvailable: playable) {
                            Task { await playerService.play(track, in: tracks.filter(remoteMusic.isAvailable)) }
                        }
                        .accessibilityIdentifier("library.yourMusic.\(device.deviceClass?.rawValue ?? device.id).card.\(index)")
                    }
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                .focusEffectDisabled()
            }
            .focusSection()
        }
    }

    private var total: String {
        countText(remoteMusic.allTracks.count)
    }

    private func countText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "track" : "tracks")"
    }
}

struct TVMusicStepView: View {
    let onContinue: () -> Void

    @EnvironmentObject private var authService: AuthenticationService
    @FocusState private var focusesContinue: Bool

    private var account: OnboardingAccount? {
        guard authService.isAuthenticated, let user = authService.currentUser else { return nil }
        return OnboardingAccount(user: user)
    }

    var body: some View {
        OnboardingFeaturePage(
            account: account,
            symbol: "music.note.house",
            title: "Your Own Music",
            features: OnboardingFeature.tvOwnMusic
        ) {
            Button(action: onContinue) {
                Text("OK").frame(maxWidth: .infinity)
            }
            .focused($focusesContinue)
            .accessibilityIdentifier("musicStep.ok")
        }
        .background { BrowseBackdrop().ignoresSafeArea() }
        .defaultFocus($focusesContinue, true)
    }
}
