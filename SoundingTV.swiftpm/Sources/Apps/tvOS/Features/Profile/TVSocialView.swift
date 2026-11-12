import SwiftUI

struct TVSocialPage: View {
    let section: SocialSection

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, section == .profile ? 0 : SCBrowseMetrics.contentTopInset)
            .background { BrowseBackdrop().ignoresSafeArea() }
            .navigationTitle(section.title)
            .accessibilityIdentifier("social.\(section.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .following:
            TVOwnConnections(kind: .following)
        case .followers:
            TVOwnConnections(kind: .followers)
        case .profile:
            ProfileTabView(embedsNavigationStack: false)
        case .activity:
            FeedView(embedsNavigationStack: false)
        }
    }
}

struct TVAccountMenu: View {
    let open: (SocialSection) -> Void

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var poller = SoundCloudActivityPoller.shared

    private var user: User? { credentials.currentUser }

    var body: some View {
        Menu {
            Section {
                item(.profile)
                item(.activity)
            }
            Section {
                item(.following)
                item(.followers)
            }
        } label: {
            HStack(spacing: Space.snug) {
                ArtworkImage(
                    url: user?.avatarURL,
                    icon: "person.crop.circle.fill",
                    identity: user?.id ?? "account"
                )
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if poller.unreadCount > 0 {
                        Circle()
                            .fill(Color.scAccent)
                            .frame(width: 16, height: 16)
                    }
                }
                Text(user?.displayName ?? "Account")
                    .font(.tvBodyEmph)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.leading, Space.tight)
            .padding(.trailing, Space.base)
            .padding(.vertical, Space.tight)
        }
        .buttonStyle(TVGlassPillStyle())
        .accessibilityIdentifier("library.account")
        .accessibilityLabel(poller.unreadCount > 0 ? "Account, \(user?.displayName ?? ""), \(poller.unreadCount) unread" : "Account, \(user?.displayName ?? "")")
    }

    private func item(_ section: SocialSection) -> some View {
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
}

private struct TVOwnConnections: View {
    let kind: ArtistConnectionKind

    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @StateObject private var model: PeopleDirectoryModel

    init(kind: ArtistConnectionKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: PeopleDirectoryModel(kind: kind))
    }

    var body: some View {
        if authService.isAuthenticated {
            TVPeopleDirectory(model: model)
        } else {
            StatusPanel(
                kind: .empty,
                icon: kind.systemImage,
                title: "Sign In to See \(kind.rawValue)",
                message: "Sign in with SoundCloud to see who you follow and who follows you.",
                actionTitle: "Sign In",
                action: { navigationState.isSigningIn = true }
            )
        }
    }
}

private struct TVPeopleDirectory: View {
    @ObservedObject var model: PeopleDirectoryModel
    var isSearchPage = false
    @State private var query = ""
    @State private var showsSearch = false

    private static let artworkLookahead = 12

    var body: some View {
        let people = model.visible(matching: query)
        ScrollView(.vertical) {
            Group {
                if model.showsLoading {
                    LoadingPlaceholder(
                        .columns(TVGridMetrics.columns, spacing: SCBrowseMetrics.gutter, circular: true),
                        count: TVGridMetrics.columns * 2,
                        insets: false
                    )
                    .frame(minHeight: 600, alignment: .top)
                } else if model.entries.isEmpty {
                    StatusPanel(
                        kind: .empty,
                        icon: model.kind.systemImage,
                        title: model.emptyTitle,
                        message: model.emptyMessage,
                        minHeight: 600
                    )
                } else if people.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, minHeight: 600)
                        .focusable()
                        .focusEffectDisabled()
                } else {
                    VStack(alignment: .leading, spacing: Space.section) {
                        HStack(spacing: Space.snug) {
                            PeopleSortMenu(model: model, showsSelection: true)
                            if !isSearchPage {
                                Button {
                                    showsSearch = true
                                } label: {
                                    Label("Search", systemImage: "magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .accessibilityIdentifier("social.search")
                            }
                        }
                        .focusSection()
                        grid(people)
                    }
                }
            }
            .padding(.bottom, Space.section)
        }
        .scrollClipDisabled()
        .tvListSearchable(isSearchPage, text: $query, prompt: "Search \(model.kind.rawValue)")
        .tvListSearchCover(isPresented: $showsSearch) {
            TVPeopleDirectory(model: model, isSearchPage: true)
                .padding(.top, SCBrowseMetrics.contentTopInset)
        }
        .peopleActionAlert(model)
        .task { await model.load() }
    }

    private func grid(_ people: [PersonEntry]) -> some View {
        LazyVGrid(columns: TVGridMetrics.gridItems(), alignment: .leading, spacing: TVGridMetrics.rowSpacing) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                VStack(spacing: Space.base) {
                    TVUserLink(user: person.user) {
                        SCArtworkResolver(url: person.user.largeAvatarURL ?? person.user.avatarURL) { image in
                            SCArtistCard(
                                name: person.user.displayName,
                                subtitle: person.followedLabel ?? person.followerCountLabel,
                                avatarImage: image,
                                identity: person.user.id,
                                diameter: SCBrowseMetrics.tileEdge,
                                crownUser: person.user,
                                crownContext: person.user.displayName,
                                style: SCBrowseMetrics.tile
                            )
                        }
                    }
                    .buttonStyle(SCArtistCardButtonStyle())
                    .focusEffectDisabled()

                    PersonFollowButton(user: person.user, model: model)
                }
                .onAppear {
                    let lookahead = people[index..<min(index + Self.artworkLookahead, people.count)]
                    ArtworkCache.shared.prefetch(lookahead.compactMap { $0.user.largeAvatarURL ?? $0.user.avatarURL })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
