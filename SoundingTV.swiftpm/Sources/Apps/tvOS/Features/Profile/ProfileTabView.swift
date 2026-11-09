import SwiftUI

struct ProfileTabView: View {
    @EnvironmentObject var authService: AuthenticationService
    @State private var fetchedUser: User?
    @State private var loadFailed = false
    @State private var attempt = 0

    private let embedsNavigationStack: Bool

    init(embedsNavigationStack: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { page }
            } else {
                page
            }
        }
        .task(id: attempt) { await resolveUser() }
    }

    private var page: some View {
        Group {
            if !authService.isAuthenticated {
                StatusPanel(
                    kind: .empty,
                    icon: "person.crop.circle.dashed",
                    title: "Not Signed In",
                    message: "Sign in with your iPhone to see your profile.",
                    actionTitle: "Sign In",
                    action: { Task { await authService.logout() } }
                )
            } else if let user = authService.currentUser ?? fetchedUser {
                ArtistDetailView(user: user, isOwnProfile: true)
                    .id(user.id)
            } else if loadFailed {
                StatusPanel(
                    kind: .error,
                    title: "Couldn\u{2019}t Load Your Profile",
                    message: "Couldn\u{2019}t reach SoundCloud. Check this Apple TV\u{2019}s network connection.",
                    actionTitle: "Try Again",
                    action: { attempt &+= 1 }
                )
            } else {
                StatusPanel(kind: .loading, title: "Loading Your Profile\u{2026}")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolveUser() async {
        loadFailed = false
        guard authService.isAuthenticated, authService.currentUser == nil, fetchedUser == nil else { return }
        if await authService.waitForCurrentUser() != nil { return }
        do {
            fetchedUser = try await SoundCloudAPI.shared.getCurrentUser()
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
