import SwiftUI

enum TVGridMetrics {
    static let columns = 5
    static let rowSpacing: CGFloat = Space.section

    static func gridItems(_ count: Int = columns) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(SCBrowseMetrics.tileEdge), spacing: SCBrowseMetrics.gutter, alignment: .top),
            count: max(1, min(count, columns))
        )
    }
}

struct UserGridView: View {
    let users: [User]
    var columns: Int = TVGridMetrics.columns
    var paging: TVPaging?
    var emptyIcon = "person.2"
    var emptyTitle = "No artists"

    private static let artworkLookahead = 12

    var body: some View {
        if users.isEmpty {
            StatusPanel(kind: .empty, icon: emptyIcon, title: emptyTitle, minHeight: 520)
            if let paging {
                TVPagedFooter(paging: paging)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: Space.base) {
                LazyVGrid(columns: TVGridMetrics.gridItems(columns), alignment: .leading, spacing: TVGridMetrics.rowSpacing) {
                    ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                        TVUserLink(user: user) {
                            UserCard(user: user)
                        }
                        .onAppear {
                            guard users.isNearEnd(user, lead: 12) else { return }
                            paging?.loadMore()
                        }
                        .onAppear {
                            let lookahead = users[index..<min(index + Self.artworkLookahead, users.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
                        }
                    }
                }
                .buttonStyle(SCArtistCardButtonStyle())
                .focusEffectDisabled()

                if let paging {
                    TVPagedFooter(paging: paging)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UserCard: View {
    let user: User
    var caption: String?

    var body: some View {
        SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
            SCArtistCard(
                name: user.displayName,
                subtitle: caption ?? (user.followersCount > 0 ? "\(user.formattedFollowers) followers" : nil),
                avatarImage: image,
                identity: user.id,
                diameter: SCBrowseMetrics.tileEdge,
                crownUser: user,
                crownContext: user.displayName,
                style: SCBrowseMetrics.tile
            )
        }
    }
}

struct TVUserLink<Label: View>: View {
    let user: User
    @ViewBuilder let label: () -> Label

    @EnvironmentObject private var authService: AuthenticationService
    @EnvironmentObject private var navigationState: NavigationState

    var body: some View {
        if user.id == authService.currentUser?.id {
            Button {
                navigationState.showProfile()
            } label: {
                label()
            }
        } else {
            NavigationLink {
                ArtistDetailView(user: user)
            } label: {
                label()
            }
        }
    }
}
