import SwiftUI

private func userGridColumns(_ count: Int) -> [GridItem] {
    Array(repeating: .init(.flexible(), spacing: Space.gutter), count: max(1, count))
}

struct UserGridView: View {
    let users: [User]
    var columns: Int = 4
    var onNearEnd: (() -> Void)?
    var isLoadingMore = false
    var emptyIcon = "person.2"
    var emptyTitle = "No artists"

    private static let artworkLookahead = 12

    var body: some View {
        if users.isEmpty {
            StatusPanel(kind: .empty, icon: emptyIcon, title: emptyTitle, minHeight: 320)
        } else {
            VStack(spacing: Space.base) {
                LazyVGrid(columns: userGridColumns(columns), spacing: Space.gutter) {
                    ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                        NavigationLink {
                            ArtistDetailView(user: user)
                        } label: {
                            UserCard(user: user)
                        }
                        .onAppear {
                            guard let onNearEnd, users.isNearEnd(user, lead: 12) else { return }
                            onNearEnd()
                        }
                        .onAppear {
                            let lookahead = users[index..<min(index + Self.artworkLookahead, users.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.avatarURL))
                        }
                    }
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.hero))
                .focusEffectDisabled()

                if isLoadingMore {
                    LoadingMoreRow()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct UserCard: View {
    let user: User

    var body: some View {
        VStack(alignment: .center, spacing: Space.tight) {
            ArtworkImage(url: user.avatarURL) {
                Circle().fill(Color.scBgRaised)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(Color.scTextTertiary)
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(Circle())
            .kyleCrowned(user: user, context: user.displayName)

            VStack(alignment: .center, spacing: 0) {
                Text(user.displayName)
                    .font(.tvBodyEmph)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                Text("\(user.formattedFollowers) followers")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
