import SwiftUI

struct CollectionShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    let items: [Item]
    let style: SCContentStyle
    var tileWidth: CGFloat
    var spacing: CGFloat
    var inset: CGFloat
    var headerAction: (() -> Void)? = nil
    @ViewBuilder var tile: (Item) -> Tile

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: style.spaceSnug) {
                header
                    .padding(.horizontal, inset)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(items) { item in
                            tile(item)
                                .frame(width: tileWidth)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    @ViewBuilder
    private var header: some View {
        #if os(tvOS)
        if let headerAction {
            Button(action: headerAction) {
                TVShelfHeaderLabel(title: title)
            }
            .buttonStyle(TVCollectionLinkStyle())
        } else {
            SCSectionHeader(title: title, style: style)
        }
        #else
        SCSectionHeader(title: title, showChevron: headerAction != nil, action: headerAction, style: style)
        #endif
    }
}

struct ArtworkShelfCard: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let identity: String
    var subject: SoundingArtSubject = .collection
    var isAvailable = true
    var crownUser: User?
    let style: SCContentStyle
    var isPrivate = false

    var body: some View {
        SCArtworkResolver(url: artworkURL) { image in
            SCMediaCard(
                title: title,
                subtitle: subtitle,
                artworkImage: image,
                artIdentity: identity,
                artSubject: subject,
                isAvailable: isAvailable,
                crownUser: crownUser,
                crownContext: title,
                style: style,
                isPrivate: isPrivate
            )
        }
    }
}

extension ArtworkShelfCard {
    init(playlist: Playlist, style: SCContentStyle) {
        self.init(
            title: playlist.title,
            subtitle: Self.subtitle(for: playlist),
            artworkURL: playlist.largeDisplayArtworkURL,
            identity: playlist.id,
            subject: .collection,
            crownUser: playlist.user,
            style: style,
            isPrivate: playlist.isPrivate
        )
    }

    init(track: Track, style: SCContentStyle) {
        self.init(
            title: track.title,
            subtitle: track.user.displayName,
            artworkURL: track.largeArtworkURL ?? track.artworkURL,
            identity: track.id,
            subject: .track,
            isAvailable: track.streamURL != nil,
            crownUser: track.user,
            style: style
        )
    }

    static func subtitle(for playlist: Playlist) -> String {
        let year = String(Calendar.current.component(.year, from: playlist.createdAt))
        return "\(CollectionPageKind(playlist: playlist).label) · \(year)"
    }
}

struct PersonShelfTile: View {
    let user: User
    var diameter: CGFloat
    let style: SCContentStyle

    var body: some View {
        SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
            SCArtistCard(
                name: user.displayName,
                subtitle: user.followersCount > 0
                    ? "\(user.formattedFollowers) \(user.followersCount == 1 ? "follower" : "followers")"
                    : nil,
                avatarImage: image,
                identity: user.id,
                diameter: diameter,
                crownUser: user,
                crownContext: user.displayName,
                style: style
            )
        }
    }
}
