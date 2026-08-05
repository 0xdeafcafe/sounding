import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("red.forbes.sounding.didSeeTVWelcome") private var didSeeWelcome = false

    var body: some View {
        content
            .onChange(of: playerService.currentTrack?.largeArtworkURL) { _, url in
                ArtworkColors.shared.update(for: url)
            }
            .onChange(of: playerService.currentTrack?.id) { _, newId in
                if newId != nil, let track = playerService.currentTrack {
                    TopShelfPublisher.notePlayed(track)
                }
            }
            .onChange(of: playerService.explicitPlayRequest) { _, _ in
                guard authService.isAuthenticated else { return }
                navigationState.selectedTab = .nowPlaying
            }
            .onChange(of: authService.isAuthenticated, initial: true) { _, isAuthenticated in
                guard !isAuthenticated else { return }
                playerService.clearQueue()
            }
            .ambientScreen(isEnabled: authService.isAuthenticated)
            .userActivity(
                HandoffActivityType.nowPlaying,
                isActive: authService.isAuthenticated && playerService.currentTrack != nil
            ) { activity in
                configureNowPlayingActivity(activity)
            }
    }

    private func configureNowPlayingActivity(_ activity: NSUserActivity) {
        guard let track = playerService.currentTrack else { return }
        activity.title = "Now Playing: \(track.title)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = [
            "trackId": track.id,
            "trackTitle": track.title,
            "artist": track.user.displayName,
        ]
        activity.requiredUserInfoKeys = ["trackId"]
    }

    @ViewBuilder
    private var content: some View {
        if authService.isAuthenticated {
            if didSeeWelcome {
                tabs
                    .tabViewStyle(.sidebarAdaptable)
                    .background(BrowseBackdrop())
                    .tabViewSidebarHeader { SidebarHeader(user: authService.currentUser) }
                    .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                        if navigationState.selectedTab != .nowPlaying {
                            PersistentNowPlayingBar()
                                .padding(.horizontal, Space.gutter)
                                .padding(.bottom, Space.snug)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .move(edge: .bottom).combined(with: .opacity)
                                )
                        }
                    }
                    .animation(reduceMotion ? nil : Motion.settle, value: navigationState.selectedTab)
            } else {
                TVWelcomeView { didSeeWelcome = true }
            }
        } else {
            QRCodeLoginView()
        }
    }

    private var tabs: some View {
        TabView(selection: $navigationState.selectedTab) {
            Tab("Home", systemImage: NavigationState.Tab.home.icon, value: .home) {
                TVHomeHub()
            }
            .accessibilityIdentifier("sidebar.tab.home")
            Tab(value: NavigationState.Tab.search, role: .search) {
                SearchView()
            }
            .accessibilityIdentifier("sidebar.tab.search")
            Tab("Library", systemImage: NavigationState.Tab.library.icon, value: .library) {
                LibraryView()
            }
            .accessibilityIdentifier("sidebar.tab.library")
            Tab("Now Playing", systemImage: NavigationState.Tab.nowPlaying.icon, value: .nowPlaying) {
                NowPlayingView()
            }
            .accessibilityIdentifier("sidebar.tab.nowPlaying")
            Tab("Polyphony", systemImage: NavigationState.Tab.polyphony.icon, value: .polyphony) {
                TVPolyphonyView()
            }
            .accessibilityIdentifier("sidebar.tab.polyphony")
            Tab("Companion", systemImage: NavigationState.Tab.companion.icon, value: .companion) {
                QRCodeLoginView(onClose: { navigationState.selectedTab = .home }, purpose: .companion)
            }
            .accessibilityIdentifier("sidebar.tab.companion")
            Tab("Profile", systemImage: NavigationState.Tab.profile.icon, value: .profile) {
                ProfileTabView()
            }
            .accessibilityIdentifier("sidebar.tab.profile")
            Tab("Settings", systemImage: NavigationState.Tab.settings.icon, value: .settings) {
                SettingsView()
            }
            .accessibilityIdentifier("sidebar.tab.settings")
        }
        .toolbarVisibility(.visible, for: .tabBar)
        .toolbar {
            // The system sidebar is gesture-driven and its compact Home chip
            // is not reliably focusable. Keep every destination one explicit
            // remote click away from any screen.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(NavigationState.Tab.allCases, id: \.self) { tab in
                        Button {
                            navigationState.selectedTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                    }
                } label: {
                    Label("Browse", systemImage: "rectangle.grid.2x2")
                }
                .accessibilityIdentifier("navigation.menu")
            }
        }
    }
}

private struct TVHomeHub: View {
    private enum Surface: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case following = "Following"
        var id: Self { self }
    }

    @State private var surface: Surface = .forYou

    var body: some View {
        VStack(spacing: 0) {
            Picker("Home", selection: $surface) {
                ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            .padding(.top, Space.tight)

            Group {
                switch surface {
                case .forYou: HomeView()
                case .following: FeedView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { BrowseBackdrop() }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct TVWelcomeView: View {
    let onContinue: () -> Void

    @FocusState private var continueIsFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                welcomeBackdrop

                HStack(spacing: 88) {
                    welcomeCopy
                        .frame(maxWidth: 780, alignment: .leading)

                    WelcomeArtworkStack()
                        .frame(
                            width: min(700, proxy.size.width * 0.40),
                            height: min(760, proxy.size.height * 0.76)
                        )
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 96)
                .padding(.vertical, 64)
            }
        }
        .defaultFocus($continueIsFocused, true)
    }

    private var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "SOUNDINGCLOUD ON TV", tint: .scAccent)

            Text("Your sound.\nFill the room.")
                .font(.tvDisplay)
                .foregroundStyle(Color.scTextPrimary)
                .tracking(-2.2)
                .padding(.top, Space.snug)

            Text("Your likes, playlists, and Stream are already here. Pick the first track, or let Auto DJ keep the night moving.")
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.top, Space.base)

            Button(action: onContinue) {
                HStack(spacing: Space.snug) {
                    Text("Start listening")
                        .font(.tvBodyEmph)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 25, weight: .bold))
                }
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, 18)
            }
            .buttonStyle(WelcomeActionButtonStyle())
            .focused($continueIsFocused)
            .padding(.top, Space.roomy)

            HStack(spacing: Space.roomy) {
                welcomeFeature(
                    icon: "dot.radiowaves.up.forward",
                    title: "Your Stream",
                    detail: "Fresh from who you follow"
                )
                welcomeFeature(
                    icon: "wand.and.stars",
                    title: "Auto DJ",
                    detail: "Continuous mixes, handled"
                )
                welcomeFeature(
                    icon: "iphone.and.arrow.forward",
                    title: "Companion",
                    detail: "Control it from iPhone or Mac"
                )
            }
            .padding(.top, 56)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func welcomeFeature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.scAccent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title)
                    .font(.tvCalloutEmph)
                    .foregroundStyle(Color.scTextPrimary)
                Text(detail)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(Color.scTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcomeBackdrop: some View {
        ZStack {
            BrowseBackdrop()
            RadialGradient(
                colors: [Color.scAccent.opacity(0.20), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 980
            )
            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct WelcomeActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusedButton(configuration: configuration)
    }

    private struct FocusedButton: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background(
                    isFocused ? Color.white : Color.white.opacity(0.12),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(isFocused ? 0 : 0.18), lineWidth: 1)
                }
                .shadow(color: isFocused ? Color.black.opacity(0.35) : .clear, radius: 28, y: 12)
                .scaleEffect(isFocused ? 1.06 : 1)
                .opacity(configuration.isPressed ? 0.82 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

private struct WelcomeArtworkStack: View {
    var body: some View {
        ZStack {
            artworkCard(
                identity: "SoundingCloud discovery",
                glyph: .sparkles,
                edge: 390
            )
            .rotationEffect(.degrees(-11))
            .offset(x: -116, y: -76)
            .opacity(0.62)

            artworkCard(
                identity: "SoundingCloud afterhours",
                glyph: .headphones,
                edge: 420
            )
            .rotationEffect(.degrees(10))
            .offset(x: 122, y: 92)
            .opacity(0.78)

            ZStack(alignment: .bottom) {
                artworkCard(
                    identity: "SoundingCloud live set",
                    glyph: .waveform,
                    edge: 510
                )

                HStack(spacing: Space.snug) {
                    ZStack {
                        Circle().fill(Color.scAccent)
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(Color.scAccentOn)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        Eyebrow(text: "AUTO DJ READY", tint: .scAccent)
                        Text("Takes it from here")
                            .font(.tvCalloutEmph)
                            .foregroundStyle(Color.scTextPrimary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "waveform")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(Color.scTextSecondary)
                        .symbolEffect(.variableColor.iterative)
                }
                .padding(Space.snug)
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous),
                    tint: .black.opacity(0.30)
                )
                .padding(Space.snug)
            }
            .frame(width: 510, height: 510)
            .shadow(color: .black.opacity(0.46), radius: 44, y: 26)
        }
        .accessibilityHidden(true)
    }

    private func artworkCard(
        identity: String,
        glyph: GeneratedArtworkGlyph,
        edge: CGFloat
    ) -> some View {
        GeneratedArtworkCard(
            identity: identity,
            glyphOverride: glyph
        )
        .frame(width: edge, height: edge)
        .overlay {
            RoundedRectangle(cornerRadius: SCContentStyle.tv.cornerCard, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct PersistentNowPlayingBar: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var navigation: NavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: Space.tight) {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.settle) {
                        navigation.selectedTab = .nowPlaying
                    }
                } label: {
                    HStack(spacing: Space.tight) {
                        ArtworkImage(url: track.artworkURL, variant: .standard)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))

                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(track.title)
                                .font(.tvCalloutEmph)
                                .foregroundStyle(Color.scTextPrimary)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                            Text(track.user.displayName)
                                .font(.tvCaption)
                                .foregroundStyle(Color.scTextSecondary)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .card))
                .accessibilityLabel("Now Playing, \(track.title) by \(track.user.displayName)")
                .accessibilityHint("Opens Now Playing")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 46, height: 46)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await player.playNext() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Next")
            }
            .padding(Space.tight)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous),
                tint: .black.opacity(0.18)
            )
            .overlay(alignment: .bottomLeading) {
                if player.duration > 0 {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.scAccent)
                            .frame(width: proxy.size.width * min(1, max(0, player.currentTime / player.duration)), height: 4)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, Space.tight)
                }
            }
            .id(track.id)
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.98).combined(with: .opacity)
            )
            .animation(reduceMotion ? nil : Motion.focus, value: player.isPlaying)
            .accessibilityIdentifier("persistentNowPlaying")
        }
    }
}

private struct SidebarHeader: View {
    let user: User?

    var body: some View {
        HStack(spacing: Space.snug) {
            avatar
            Text(user?.displayName ?? "Guest")
                .font(.tvBodyEmph)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder
    private var avatar: some View {
        ArtworkImage(url: user?.avatarURL) {
            Circle()
                .fill(Color.scBgRaised)
                .overlay(
                    Text(initials)
                        .font(.tvCalloutEmph)
                        .foregroundStyle(Color.scTextPrimary)
                )
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .kyleCrowned(user: user, context: user?.displayName)
    }

    private var initials: String {
        let name = user?.displayName ?? "Guest"
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
        .environmentObject(PlayerService.shared)
        .environmentObject(NavigationState())
}
