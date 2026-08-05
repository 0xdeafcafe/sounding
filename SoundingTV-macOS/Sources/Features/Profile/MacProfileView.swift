import SwiftUI

struct MacProfileView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @State private var loadFailed = false
    @State private var attempt = 0
    @State private var isShowingReauthentication = false

    var body: some View {
        Group {
            if credentials.isSessionRejected {
                VStack(spacing: 0) {
                    MacPaneHeader(title: "Profile")
                    SCEmptyState(
                        kind: .error,
                        title: "Session Expired",
                        message: "Reauthenticate to load your profile. Cached account data is preserved.",
                        actionTitle: "Reauthenticate",
                        action: { isShowingReauthentication = true },
                        style: .mac
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if credentials.isSignedOut {
                VStack(spacing: 0) {
                    MacPaneHeader(title: "Profile")
                    MacSignedOutEmptyState(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Profile Needs an Account",
                        message: "This Mac shares its SoundCloud session with your iPhone or Apple TV. Home and Search work without one in the meantime.",
                        browsableRoute: .home
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let user = credentials.currentUser {
                MacArtistDetailView(user: user)
                    .id(user.id)
            } else if loadFailed {
                VStack(spacing: 0) {
                    MacPaneHeader(title: "Profile")
                    SCEmptyState(
                        kind: .error,
                        title: "Couldn\u{2019}t Load Your Profile",
                        message: "Check your connection and try again.",
                        actionTitle: "Try Again",
                        action: {
                            credentials.refreshFromStore()
                            attempt &+= 1
                        },
                        style: .mac
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    MacPaneHeader(title: "Profile")
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(credentials.currentUser.map { "@\($0.username)" } ?? "Profile")
        .task(id: attempt) {
            loadFailed = false
            guard !credentials.isSignedOut, credentials.currentUser == nil else { return }
            loadFailed = await credentials.waitForCurrentUser() == nil
        }
        .sheet(isPresented: $isShowingReauthentication) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: true) {
                credentials.didCompleteSignIn()
                isShowingReauthentication = false
                attempt &+= 1
            }
            .frame(minWidth: 720, minHeight: 620)
        }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            guard !isSignedOut else { return }
            attempt &+= 1
        }
    }
}
