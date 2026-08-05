import SwiftUI

struct ProfileTabView: View {
    @EnvironmentObject var authService: AuthenticationService
    @State private var fetchedUser: User?
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if !authService.isAuthenticated {
                    StatusPanel(
                        kind: .empty,
                        icon: "person.crop.circle.dashed",
                        title: "Not Signed In",
                        message: "Pair with your iPhone to sign in to SoundCloud."
                    )
                } else if let user = authService.currentUser ?? fetchedUser {
                    ProfileContent(user: user)
                } else if loadFailed {
                    StatusPanel(
                        kind: .error,
                        title: "Couldn't Load Your Profile",
                        message: "Couldn't reach SoundCloud. Check this Apple TV's network connection.",
                        actionTitle: "Try Again",
                        action: { attempt &+= 1 }
                    )
                } else {
                    ProfileBootLoading()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: attempt) { await resolveUser() }
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

private enum ProfileSection: String, CaseIterable {
    case tracks    = "Tracks"
    case playlists = "Playlists"
    case reposts   = "Reposts"
    case likes     = "Likes"
    case following = "Following"

    var detailSection: ArtistDetailSection? {
        switch self {
        case .tracks:    return .tracks
        case .playlists: return .playlists
        case .reposts:   return .reposts
        case .likes:     return .likes
        case .following: return nil
        }
    }
}

private struct ProfileContent: View {
    let user: User

    @EnvironmentObject var authService: AuthenticationService
    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var followingModel: ProfileFollowingViewModel
    @State private var section: ProfileSection = .tracks
    @State private var showingSignOutConfirmation = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case play, shuffle, refresh, picker }

    init(user: User) {
        self.user = user
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
        _followingModel = StateObject(wrappedValue: ProfileFollowingViewModel(userId: user.id))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.roomy) {
                header

                Picker("Section", selection: $section) {
                    ForEach(ProfileSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 1100)
                .focused($focus, equals: .picker)
                .focusSection()
                .accessibilityIdentifier("profile.sectionPicker")

                content
            }
            .padding(.vertical, Space.gutter)
            .padding(.horizontal, SCBrowseMetrics.pageInset)
        }
        .scrollClipDisabled()
        .defaultFocus($focus, .picker)
        .onAppear { DispatchQueue.main.async { focus = .picker } }
        .task { await load() }
        .onChange(of: section) { _, _ in
            Task { await load() }
        }
        .confirmationDialog("Sign Out", isPresented: $showingSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                Task {
                    SessionSyncBookkeeping.recordLocalSignOut()
                    await authService.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to pair with your iPhone again to sign back in.")
        }
    }

    private func load() async {
        if let mapped = section.detailSection {
            viewModel.selectedSection = mapped
            await viewModel.loadIfNeeded()
        } else {
            await followingModel.loadIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.roomy) {
            ArtworkImage(url: user.largeAvatarURL ?? user.avatarURL) {
                Circle().fill(Color.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 80, weight: .light))
                            .foregroundStyle(Color.scTextTertiary)
                    }
            }
            .frame(width: 220, height: 220)
            .clipShape(Circle())
            .kyleCrowned(user: user, context: user.displayName)

            VStack(alignment: .leading, spacing: 0) {
                Text(user.displayName)
                    .font(.tvDisplay)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(identityLine)
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                Text(statsLine)
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                if let description = user.description, !description.isEmpty {
                    Text(description)
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextTertiary)
                    .lineLimit(2)
                }
            }

            Spacer(minLength: Space.roomy)

            VStack(alignment: .trailing, spacing: Space.snug) {
                HStack(spacing: Space.snug) {
                    Button {
                        Task { await PlayActions.play(tracks: viewModel.tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .focused($focus, equals: .play)

                    Button {
                        Task { await PlayActions.shufflePlay(tracks: viewModel.tracks) }
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .focused($focus, equals: .shuffle)
                }
                .disabled(viewModel.tracks.isEmpty)

                HStack(spacing: Space.snug) {
                    Button {
                        Task {
                            if let detailSection = section.detailSection {
                                await viewModel.reload(section: detailSection)
                            } else {
                                await followingModel.reload()
                            }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .focused($focus, equals: .refresh)
                    .disabled(isRefreshingSection)

                    Button("Sign Out") {
                        showingSignOutConfirmation = true
                    }
                    .buttonBorderShape(.capsule)
                    .tint(Color.scBgRaised)
                    .foregroundStyle(Color.scTextPrimary)
                    .accessibilityIdentifier("profile.signOut")
                }
            }
        }
        .focusSection()
    }

    private var isRefreshingSection: Bool {
        guard let detailSection = section.detailSection else {
            return followingModel.isLoading
        }
        return viewModel.isLoading(detailSection)
    }

    private var identityLine: String {
        let location = [user.city, user.country]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        return location.isEmpty ? "@\(user.username)" : "@\(user.username) \u{00B7} \(location)"
    }

    private var statsLine: String {
        [
            "\(user.formattedFollowers) followers",
            "\(user.formattedTracks) tracks",
            "\(formatCount(user.playlistCount)) playlists",
            "\(formatCount(user.followingsCount)) following",
        ].joined(separator: " \u{00B7} ")
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000     { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .tracks:
            detailBody(.tracks, isEmpty: viewModel.tracks.isEmpty) {
                TrackListView(
                    tracks: viewModel.tracks,
                    emptyIcon: "music.note",
                    emptyTitle: "You haven't uploaded any tracks",
                    onNearEnd: { Task { await viewModel.loadMore(section: .tracks) } },
                    isLoadingMore: viewModel.loadingMore.contains(.tracks)
                )
            }
        case .playlists:
            detailBody(.playlists, isEmpty: viewModel.playlists.isEmpty) {
                PlaylistGridView(
                    playlists: viewModel.playlists,
                    onNearEnd: { Task { await viewModel.loadMore(section: .playlists) } },
                    isLoadingMore: viewModel.loadingMore.contains(.playlists),
                    emptyTitle: "You haven't published any playlists"
                )
            }
        case .reposts:
            detailBody(.reposts, isEmpty: viewModel.repostedTracks.isEmpty && viewModel.repostedPlaylists.isEmpty) {
                repostsContent
            }
        case .likes:
            detailBody(.likes, isEmpty: viewModel.likedTracks.isEmpty) {
                TrackListView(
                    tracks: viewModel.likedTracks,
                    emptyIcon: "heart",
                    emptyTitle: "You haven't liked any tracks",
                    onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                    isLoadingMore: viewModel.loadingMore.contains(.likes)
                )
            }
        case .following:
            followingContent
        }
    }

    @ViewBuilder
    private var repostsContent: some View {
        if viewModel.repostedTracks.isEmpty, viewModel.repostedPlaylists.isEmpty {
            StatusPanel(
                kind: .empty,
                icon: "arrow.2.squarepath",
                title: "You haven't reposted anything",
                actionTitle: "Refresh",
                action: { Task { await viewModel.reload(section: .reposts) } },
                minHeight: 360
            )
        } else {
            VStack(alignment: .leading, spacing: Space.roomy) {
                if !viewModel.repostedPlaylists.isEmpty {
                    PlaylistGridView(playlists: viewModel.repostedPlaylists, emptyTitle: "")
                }
                if !viewModel.repostedTracks.isEmpty {
                    TrackListView(
                        tracks: viewModel.repostedTracks,
                        emptyIcon: "arrow.2.squarepath",
                        emptyTitle: "No reposted tracks",
                        onNearEnd: { Task { await viewModel.loadMore(section: .reposts) } },
                        isLoadingMore: viewModel.loadingMore.contains(.reposts)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var followingContent: some View {
        if followingModel.isLoading, followingModel.users.isEmpty {
            ProfileSectionLoading(title: "Loading people you follow…")
        } else if let error = followingModel.errorMessage, followingModel.users.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn't load this",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await followingModel.reload() } },
                minHeight: 360
            )
        } else {
            UserGridView(
                users: followingModel.users,
                onNearEnd: { Task { await followingModel.loadMore() } },
                isLoadingMore: followingModel.isLoadingMore,
                emptyIcon: "person.2",
                emptyTitle: "You aren't following anyone yet"
            )
        }
    }

    @ViewBuilder
    private func detailBody<Content: View>(
        _ section: ArtistDetailSection,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if viewModel.isLoading(section), isEmpty {
            ProfileSectionLoading(title: "Loading \(section.rawValue.lowercased())…")
        } else if let error = viewModel.errorMessage(section), isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn't load this",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: section) } },
                minHeight: 360
            )
        } else {
            content()
        }
    }
}

private struct ProfileBootLoading: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.roomy) {
                HStack(spacing: Space.roomy) {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: Space.snug) {
                        Capsule().fill(Color.white.opacity(0.16)).frame(width: 460, height: 44)
                        Capsule().fill(Color.white.opacity(0.10)).frame(width: 280, height: 24)
                        Capsule().fill(Color.white.opacity(0.08)).frame(width: 560, height: 24)
                    }
                }

                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 880, height: 60)

                ProfileSectionLoading(title: "Loading your profile…")
            }
            .padding(.vertical, Space.gutter)
            .padding(.horizontal, SCBrowseMetrics.pageInset)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your profile")
    }
}

private struct ProfileSectionLoading: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack(spacing: Space.snug) {
                ProgressView().tint(Color.scAccent)
                Text(title)
                    .font(.tvCalloutEmph)
                    .foregroundStyle(Color.scTextSecondary)
            }

            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: Space.snug) {
                    RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 12) {
                        Capsule().fill(Color.white.opacity(0.16)).frame(width: index == 2 ? 360 : 500, height: 22)
                        Capsule().fill(Color.white.opacity(0.09)).frame(width: 220, height: 16)
                    }
                    Spacer()
                }
                .padding(Space.snug)
                .background(Color.scBgRaised.opacity(0.65), in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
            }
        }
        .padding(Space.roomy)
        .opacity(glow ? 1 : 0.64)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glow)
        .onAppear { glow = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

@MainActor
final class ProfileFollowingViewModel: ObservableObject {
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let userId: String
    private let api = SoundCloudAPI.shared
    private var cursor = PageCursor<User>()
    private var loadedOnce = false

    init(userId: String) {
        self.userId = userId
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await api.getUserFollowings(userId: userId, limit: 50)
            users = page.collection
            cursor.advance(to: page)
            loadedOnce = true
        } catch {
            errorMessage = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
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
            print("Profile following load-more error: \(error)")
        }
    }
}
