import SwiftUI

struct MacProfileView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if credentials.isSessionRejected {
                MacAccountRecoveryEmptyState(sectionName: "Profile")
            } else if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Profile Needs an Account",
                    message: "Sign in on this Mac to see your profile. Home and Search work without an account.",
                    browsableRoute: .home
                )
            } else if let user = credentials.currentUser {
                MacArtistDetailView(user: user)
                    .id(user.id)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Load Your Profile", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") {
                        credentials.refreshFromStore()
                        attempt &+= 1
                    }
                }
            } else {
                MacLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(
            credentials.needsSignIn
                ? "Profile"
                : credentials.currentUser.map { "@\($0.username)" } ?? "Profile"
        )
        .task(id: attempt) {
            loadFailed = false
            guard !credentials.isSignedOut, credentials.currentUser == nil else { return }
            loadFailed = await credentials.waitForCurrentUser() == nil
        }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            guard !isSignedOut else { return }
            attempt &+= 1
        }
    }
}
