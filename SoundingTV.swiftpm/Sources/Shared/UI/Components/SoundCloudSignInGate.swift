import SwiftUI

extension SoundCloudCredentialSource {
    var showsSoundCloudLibrary: Bool { hasAccount }
}

enum SoundCloudSignInTopic: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case likes
    case sets
    case playlists
    case following
    case artists
    case privateShares
    case profile
    case messages
    case followers
    case myTracks
    case stations
    case account

    static let librarySections: [SoundCloudSignInTopic] = [.playlists, .sets, .following]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .likes: "Likes"
        case .sets: "Sets"
        case .playlists: "Playlists"
        case .following: "Following"
        case .artists: "Artists"
        case .privateShares: "Private Shares"
        case .profile: "Profile"
        case .messages: "Messages"
        case .followers: "Followers"
        case .myTracks: "Your Tracks"
        case .stations: "Stations"
        case .account: "SoundCloud"
        }
    }

    var prompt: String {
        switch self {
        case .recentlyAdded: "Sign In to See Recently Added"
        case .likes: "Sign In to See Your Likes"
        case .sets: "Sign In to See Your Sets"
        case .playlists: "Sign In to See Your Playlists"
        case .following: "Sign In to See Who You Follow"
        case .artists: "Sign In to See Your Artists"
        case .privateShares: "Sign In to See Private Shares"
        case .profile: "Sign In to See Your Profile"
        case .messages: "Sign In to See Messages"
        case .followers: "Sign In to See Your Followers"
        case .myTracks: "Sign In to See Your Tracks"
        case .stations: "Sign In to See Your Stations"
        case .account: "Sign In to SoundCloud"
        }
    }

    var message: String {
        switch self {
        case .recentlyAdded: "Playlists you make or like on SoundCloud appear here."
        case .likes: "Tracks you like on SoundCloud appear here."
        case .sets: "Long mixes from your SoundCloud likes appear here."
        case .playlists: "Playlists you make or like on SoundCloud appear here."
        case .following: "Artists you follow on SoundCloud appear here."
        case .artists: "Artists from your SoundCloud likes appear here."
        case .privateShares: "Private tracks shared with you on SoundCloud appear here."
        case .profile: "Your SoundCloud profile appears here."
        case .messages: "Your SoundCloud messages appear here."
        case .followers: "People who follow you on SoundCloud appear here."
        case .myTracks: "Tracks you upload to SoundCloud appear here."
        case .stations: "Stations based on what you like and play appear here."
        case .account: "Your SoundCloud account appears here."
        }
    }

    var symbol: String {
        switch self {
        case .recentlyAdded: "clock"
        case .likes: "heart"
        case .sets: "clock.arrow.2.circlepath"
        case .playlists: "music.note.list"
        case .following, .artists: "person.2"
        case .privateShares: "lock"
        case .profile, .account: "person.crop.circle"
        case .messages: "message"
        case .followers: "person.3"
        case .myTracks: "waveform"
        case .stations: StationSymbol.name
        }
    }
}

struct SoundCloudSignInPrompt: View {
    let topic: SoundCloudSignInTopic
    var symbol: String?
    let signIn: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(topic.prompt, systemImage: symbol ?? topic.symbol)
        } description: {
            Text(topic.message)
        } actions: {
            signInButton
                .accessibilityIdentifier("library.signIn")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var signInButton: some View {
        #if os(macOS)
        Button("Sign In…", action: signIn)
            .buttonStyle(.borderedProminent)
            .tint(SoundingWelcome.signInTint)
            .controlSize(.large)
        #elseif os(tvOS)
        Button("Sign In", action: signIn)
        #else
        Button("Sign In", action: signIn)
            .buttonStyle(.borderedProminent)
        #endif
    }
}

struct SoundCloudSectionGate<Content: View>: View {
    let topic: SoundCloudSignInTopic
    var isSignedIn: Bool?
    var symbol: String?
    @ViewBuilder let content: () -> Content

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isSigningIn = false

    init(_ topic: SoundCloudSignInTopic, isSignedIn: Bool? = nil, symbol: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.topic = topic
        self.isSignedIn = isSignedIn
        self.symbol = symbol
        self.content = content
    }

    var body: some View {
        if isSignedIn ?? credentials.showsSoundCloudLibrary {
            content()
        } else {
            SoundCloudSignInPrompt(topic: topic, symbol: symbol) { isSigningIn = true }
                .soundCloudSectionTitle(topic.title)
                .soundCloudSignIn(isPresented: $isSigningIn)
        }
    }
}

extension View {
    @ViewBuilder
    func soundCloudSectionTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        #elseif os(macOS)
        navigationTitle(title)
        #else
        self
        #endif
    }
}
