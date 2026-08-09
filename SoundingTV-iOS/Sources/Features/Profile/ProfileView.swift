import SwiftUI
import os

private enum ProfileLoadState: Equatable {
    case loading
    case failed(LoadFailure)
}

struct ProfileView: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var peopleSheet: ProfilePeopleKind?
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
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(ProfilePeopleKind.allCases) { kind in
                                    Button {
                                        peopleSheet = kind
                                    } label: {
                                        Label(kind.rawValue, systemImage: kind.symbol)
                                    }
                                }
                            } label: {
                                Image(systemName: "person.2")
                            }
                            .accessibilityLabel("Followers and Following")
                        }
                    }
                    .sheet(item: $peopleSheet) { kind in
                        NavigationStack {
                            ProfilePeopleListView(userId: user.id, kind: kind)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { peopleSheet = nil }
                                    }
                                }
                        }
                    }
    }

    private func loadProfile() async {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        credentials.refreshFromStore()
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
        LoadingState(message: "Loading your profile…")
            .background(Color.scBgBase.ignoresSafeArea())
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
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ProfilePeopleKind: String, CaseIterable, Identifiable {
    case followers = "Followers"
    case following = "Following"

    var id: Self { self }
    var symbol: String { self == .followers ? "person.2.fill" : "person.crop.circle.badge.checkmark" }
}

private struct ProfilePeopleListView: View {
    let userId: String
    let kind: ProfilePeopleKind

    @StateObject private var viewModel = ProfilePeopleListViewModel()

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load(userId: userId, kind: kind) }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingState(message: kind == .followers ? "Loading followers…" : "Loading who you follow…")
        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: kind.rawValue.lowercased()),
                actionTitle: "Try Again",
                action: { Task { await viewModel.load(userId: userId, kind: kind, forceRefresh: true) } },
                style: .phone
            )
        case .empty:
            SCEmptyState(
                icon: kind.symbol,
                title: kind == .followers ? "No Followers Yet" : "Not Following Anyone",
                message: kind == .followers
                    ? "People who follow you will appear here."
                    : "Artists you follow will appear here.",
                style: .phone
            )
        case .loaded:
            List {
                ForEach(viewModel.users) { user in
                    NavigationLink { ArtistDetailView(user: user) } label: { UserRow(user: user) }
                        .onAppear {
                            guard viewModel.users.isNearEnd(user, lead: 10) else { return }
                            Task { await viewModel.loadMore() }
                        }
                }
                if viewModel.isLoadingMore {
                    LoadingMoreRow()
                }
            }
            .listStyle(.plain)
        }
    }
}

@MainActor
private final class ProfilePeopleListViewModel: ObservableObject {
    enum State: Equatable { case loading, loaded, empty, failed(LoadFailure) }

    @Published private(set) var state: State = .loading
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoadingMore = false

    private let api = SoundCloudAPI.shared
    private var cursor = PageCursor<User>()
    private var loadedOnce = false

    func load(userId: String, kind: ProfilePeopleKind, forceRefresh: Bool = false) async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            users = VisualFixtures.artists
            state = .loaded
            loadedOnce = true
            return
        }
        #endif
        guard !loadedOnce || forceRefresh else { return }
        loadedOnce = true
        state = .loading

        do {
            let page: Page<User>
            switch kind {
            case .followers:
                page = try await api.getUserFollowers(userId: userId, limit: 50)
            case .following:
                page = try await api.getUserFollowings(userId: userId, limit: 50)
            }
            users = page.collection
            cursor.advance(to: page)
            state = users.isEmpty ? .empty : .loaded
        } catch {
            if error.isTaskCancellation {
                loadedOnce = false
                return
            }
            state = .failed(LoadFailure.classify(error))
        }
    }

    func loadMore() async {
        guard !isLoadingMore, cursor.canLoadMore, let page = cursor.lastPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = try await api.getNextPage(page)
            cursor.advance(to: next)
            users.appendUnique(contentsOf: next.collection)
        } catch {
            Log.api.error("Profile people load-more error: \(error, privacy: .public)")
        }
    }
}

struct AccountAvatarButton: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isShowingAccount = false

    var body: some View {
        Group {
            if opensProfileDirectly {
                NavigationLink {
                    ProfileView()
                } label: {
                    avatarLabel
                }
            } else {
                Button {
                    isShowingAccount = true
                } label: {
                    avatarLabel
                }
            }
        }
        .accessibilityLabel(
            presentedUser.map { "Account, \($0.displayName)" }
                ?? (credentials.isSignedOut ? "Account, signed out" : "Account")
        )
        .sheet(isPresented: $isShowingAccount) {
            AccountSheetView()
        }
        .onAppear {
            if Self.debugOpensSheet, !opensProfileDirectly { isShowingAccount = true }
        }
    }

    @ViewBuilder
    private var avatarLabel: some View {
        if presentedUser == nil, credentials.isSignedOut {
            Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.scAccent)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
        } else {
            ArtworkThumbnail(
                url: presentedUser?.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 40,
                identity: presentedUser?.displayName ?? "SoundCloud account"
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(accountStatusColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 2))
            }
            .frame(width: 44, height: 44)
        }
    }

    private var opensProfileDirectly: Bool {
        #if DEBUG
        if VisualFixtures.isEnabled { return true }
        #endif
        return !credentials.isSignedOut && !credentials.isSessionRejected
    }

    private var presentedUser: User? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser }
        #endif
        return credentials.currentUser
    }

    private var accountStatusColor: Color {
        #if DEBUG
        if VisualFixtures.isEnabled { return .green }
        #endif
        if credentials.isSessionRejected { return .red }
        if credentials.isSignedOut { return .secondary }
        return .green
    }

    private static var debugOpensSheet: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_ACCOUNT_SHEET"] == "1"
        #else
        false
        #endif
    }
}

struct AccountSheetView: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var isShowingSignIn = false

    var body: some View {
        NavigationStack {
            List {
                if credentials.isSignedOut {
                    signedOutSection
                } else if credentials.isSessionRejected {
                    recoverySection
                } else {
                    identitySection
                    settingsSection
                    signOutSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign Out of SoundCloud", isPresented: $showingSignOutConfirmation) {
                Button("Sign Out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign in again to browse or play music on this iPhone. Your other devices stay signed in.")
            }
            .sheet(isPresented: $isShowingSignIn) { signInSheet }
        }
    }

    private var identitySection: some View {
        Section {
            if let user = credentials.currentUser {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(
                            url: user.avatarURL,
                            systemImage: "person.fill",
                            isCircle: true,
                            size: 56,
                            crownUser: user,
                            crownContext: user.displayName
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.headline)
                            Text("@\(user.username)")
                                .font(.subheadline)
                                .foregroundStyle(Color.scTextSecondary)
                            Text("View Profile")
                                .font(.footnote)
                                .foregroundStyle(Color.scAccent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                NavigationLink("View Profile") { ProfileView() }
            }
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                PhoneSettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showingSignOutConfirmation = true
            }
            .disabled(isSigningOut)
        } footer: {
            Text("Signs this iPhone out and clears its stored authentication and account content. Your Apple TV and other devices stay signed in.")
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var signedOutSection: some View {
        Section {
            Button("Sign In to SoundCloud") { isShowingSignIn = true }
        } footer: {
            Text("Sign in to browse your library, your Stream, and play music on this iPhone.")
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var recoverySection: some View {
        Section {
            Button("Reauthenticate") { isShowingSignIn = true }
        } header: {
            Text("Sign-In Expired")
        } footer: {
            Text("Sign in again to access your profile and account content.")
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var signInSheet: some View {
        NavigationStack {
            SoundCloudLoginView.standalone {
                isShowingSignIn = false
            }
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await credentials.signOut()
            isSigningOut = false
            dismiss()
        }
    }
}
