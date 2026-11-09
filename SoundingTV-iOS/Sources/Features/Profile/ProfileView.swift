import SwiftUI
import os

private enum ProfileLoadState: Equatable {
    case loading
    case failed(LoadFailure)
}

struct ProfileView: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var loadState: ProfileLoadState = .loading
    @State private var isShowingSignIn = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let user = presentedUser {
                profile(for: user)
            } else if credentials.needsSignIn {
                failureState(.credentialFailure())
            } else {
                switch loadState {
                case .loading:
                    loadingState
                case .failed(let failure):
                    failureState(failure)
                }
            }
        }
        .task(id: attempt) { await loadProfile() }
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    credentials.refreshFromStore()
                    attempt &+= 1
                }
            }
        }
    }

    private var presentedUser: User? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser }
        #endif
        return credentials.currentUser
    }

    @ViewBuilder
    private func profile(for user: User) -> some View {
        ArtistDetailView(user: user)
    }

    private func loadProfile() async {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        await credentials.prepareStoreAtLaunch()
        guard credentials.currentUser == nil else { return }

        loadState = .loading

        guard credentials.accessToken != nil else {
            loadState = .failed(LoadFailure.credentialFailure())
            return
        }

        if await credentials.waitForCurrentUser() != nil { return }

        do {
            _ = try await SoundCloudAPI.shared.getCurrentUser()
            if await credentials.waitForCurrentUser() == nil {
                loadState = .failed(.unknown("account details unavailable"))
            }
        } catch {
            guard !error.isTaskCancellation else { return }
            loadState = .failed(LoadFailure.classify(error))
        }
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func failureState(_ failure: LoadFailure) -> some View {
        SCEmptyState(
            kind: failure.isFault ? .error : .empty,
            icon: failure.icon,
            title: failure.title,
            message: failure.message(subject: "your profile"),
            actionTitle: failure.actionTitle,
            action: {
                switch failure.recovery {
                case .signIn: isShowingSignIn = true
                case .retry:  attempt &+= 1
                }
            },
            style: .phone
        )
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AccountAvatarButton()
        }
    }
}

struct AccountAvatarButton: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var poller = SoundCloudActivityPoller.shared
    @Environment(\.artistRouter) private var router
    @State private var isShowingSettings = false
    @State private var presentedSection: SocialSection?

    var body: some View {
        Group {
            if isSignedOut {
                Button {
                    isShowingSettings = true
                } label: {
                    avatarLabel
                }
                .accessibilityHint("Opens Settings")
            } else {
                Menu {
                    Section {
                        menuButton(.profile)
                        menuButton(.activity)
                    }
                    Section {
                        menuButton(.following)
                        menuButton(.followers)
                    }
                    if !PadLayout.isPad {
                        Section {
                            Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                        }
                    }
                } label: {
                    avatarLabel
                }
                .menuIndicator(.hidden)
            }
        }
        .accessibilityLabel(accountAccessibilityLabel)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheetView()
        }
        .sheet(item: $presentedSection) { section in
            NavigationStack {
                SocialSectionView(section: section)
                    .appNavigationDestinations()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .close) { presentedSection = nil }
                        }
                    }
            }
            .addToPlaylistHost()
        }
        .onAppear {
            if Self.debugOpensSheet { isShowingSettings = true }
        }
    }

    private var isSignedOut: Bool { presentedUser == nil && credentials.isSignedOut }

    private func menuButton(_ section: SocialSection) -> some View {
        Button {
            open(section)
        } label: {
            if section == .activity, poller.unreadCount > 0 {
                Label("\(section.title) (\(poller.unreadCount))", systemImage: "bell.badge")
            } else {
                Label(section.title, systemImage: section.symbol)
            }
        }
    }

    private func open(_ section: SocialSection) {
        if let router {
            router.open(social: section)
        } else {
            presentedSection = section
        }
    }

    private var accountAccessibilityLabel: String {
        if credentials.isSessionRejected, !usesVisualFixtures { return "Account, needs sign-in" }
        if let presentedUser {
            return poller.unreadCount > 0 ? "Account, \(presentedUser.displayName), \(poller.unreadCount) unread" : "Account, \(presentedUser.displayName)"
        }
        return credentials.isSignedOut ? "Account, signed out" : "Account"
    }

    private var usesVisualFixtures: Bool {
        #if DEBUG
        VisualFixtures.isEnabled
        #else
        false
        #endif
    }

    @ViewBuilder
    private var avatarLabel: some View {
        if isSignedOut {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .frame(width: 44, height: 44)
        } else {
            ArtworkThumbnail(
                url: presentedUser?.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 36,
                identity: presentedUser?.id ?? "SoundCloud account"
            )
            .overlay(alignment: .topTrailing) {
                if poller.unreadCount > 0, !credentials.isSessionRejected {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5) }
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if credentials.isSessionRejected, !usesVisualFixtures {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
                }
            }
            .frame(width: 44, height: 44)
        }
    }

    private var presentedUser: User? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser }
        #endif
        return credentials.accountUser
    }

    private static var debugOpensSheet: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_ACCOUNT_SHEET"] == "1"
        #else
        false
        #endif
    }
}

struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhoneSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct AccountSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountSettingsDetail()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
