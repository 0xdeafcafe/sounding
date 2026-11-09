import SwiftUI

struct SignedOutLibraryView: View {
    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @EnvironmentObject private var navigationState: NavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLinking = false
    @FocusState private var focusesSignIn: Bool

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                    hero

                    VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                        if !remoteMusic.allTracks.isEmpty {
                            VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                                LibraryShelfHeader(filter: .yourMusic, count: nil)
                                RemoteMusicShelf(tracks: Array(remoteMusic.allTracks.prefix(LibraryShelfMetrics.shelfLimit)))
                                    .frame(height: LibraryShelfMetrics.tileShelfHeight, alignment: .top)
                            }
                            .focusSection()
                        }

                        ForEach(SoundCloudSignInTopic.librarySections) { topic in
                            SignedOutShelf(topic: topic) { navigationState.isSigningIn = true }
                        }
                    }
                    .padding(.leading, proxy.safeAreaInsets.leading)
                    .padding(.trailing, proxy.safeAreaInsets.trailing)
                }
                .padding(.bottom, Space.section)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .navigationDestination(for: LibraryFilter.self) { filter in
            if let topic = filter.signInTopic {
                SoundCloudSectionGate(topic, isSignedIn: false) { EmptyView() }
            } else {
                RemoteMusicDetailView()
            }
        }
        .fullScreenCover(isPresented: $isLinking) {
            QRCodeLoginView(onClose: { isLinking = false }, purpose: .companion)
        }
        .defaultFocus($focusesSignIn, true)
        .onAppear { remoteMusic.refreshIfNeeded() }
    }

    private var hero: some View {
        VStack(spacing: Space.roomy) {
            SoundingWelcomeHero(seed: 0x54_56_4C_42, style: .banner, loop: .once, isActive: !reduceMotion, fadeFrom: 0.5, colorScheme: .dark)
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .padding(.bottom, -Space.section * 3)

            SoundingWelcomeTitle(
                titleFont: .tvLargeTitle,
                messageFont: .tvBody,
                messageStyle: AnyShapeStyle(Color.scTextSecondary),
                spacing: Space.snug
            )
            .foregroundStyle(Color.scTextPrimary)

            HStack(spacing: Space.base) {
                Button { navigationState.isSigningIn = true } label: {
                    TVGlassPillLabel(title: "Sign In to SoundCloud")
                }
                .buttonStyle(SignInGlassPillStyle())
                .focused($focusesSignIn)
                .accessibilityIdentifier("library.signedOut.signIn")

                Button { isLinking = true } label: {
                    TVGlassPillLabel(title: "Link a Device", systemImage: "link")
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityIdentifier("library.signedOut.link")
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }
}

private struct SignedOutShelf: View {
    let topic: SoundCloudSignInTopic
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            if let filter = LibraryFilter(signInTopic: topic) {
                LibraryShelfHeader(filter: filter, count: nil)
            }
            HStack(alignment: .center, spacing: Space.section) {
                Button(action: signIn) {
                    SCMediaCard(
                        title: "Sign In",
                        subtitle: nil,
                        artworkImage: nil,
                        artIdentity: "library.signedOut.\(topic.rawValue)",
                        artSubject: topic == .following ? .person : .collection,
                        style: SCBrowseMetrics.tile
                    )
                    .frame(width: SCBrowseMetrics.tileEdge)
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                .focusEffectDisabled()
                .accessibilityLabel(topic.prompt)
                .accessibilityIdentifier("library.signedOut.\(topic.rawValue)")

                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(topic.prompt)
                        .font(.tvHeadline)
                        .foregroundStyle(Color.scTextPrimary)
                    Text(topic.message)
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                }
                .accessibilityHidden(true)
            }
        }
        .focusSection()
    }
}

extension LibraryFilter {
    init?(signInTopic topic: SoundCloudSignInTopic) {
        switch topic {
        case .likes: self = .likes
        case .sets: self = .sets
        case .playlists: self = .playlists
        case .following: self = .following
        case .recentlyAdded: self = .recentlyAdded
        default: return nil
        }
    }

    var signInTopic: SoundCloudSignInTopic? {
        switch self {
        case .likes, .songs, .setlists, .history: .likes
        case .sets: .sets
        case .playlists, .albums: .playlists
        case .following: .following
        case .recentlyAdded: .recentlyAdded
        case .downloads, .yourMusic, .artists, .mixes: nil
        }
    }
}

extension View {
    func soundCloudSignIn(isPresented: Binding<Bool>) -> some View {
        modifier(TVSoundCloudSignIn(isPresented: isPresented))
    }
}

private struct TVSoundCloudSignIn: ViewModifier {
    @Binding var isPresented: Bool
    @EnvironmentObject private var navigationState: NavigationState

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { _, presented in
            guard presented else { return }
            isPresented = false
            navigationState.isSigningIn = true
        }
    }
}

private struct SignInGlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.white)
                .background {
                    Capsule()
                        .fill(Color.scChromeFocus)
                        .opacity(isFocused ? 1 : 0)
                }
                .liquidGlass(in: Capsule(), tint: SoundingWelcome.signInTint)
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}
