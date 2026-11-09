import SwiftUI

struct RecentlyAddedTVGrid: View {
    @ObservedObject var model: RecentlyAddedModel
    var isLoading = false
    var error: String?
    var retry: () -> Void = {}

    @Environment(\.libraryGridColumns) private var columns

    var body: some View {
        TVLibraryPage(
            title: LibraryFilter.recentlyAdded.label,
            subtitle: subtitle,
            showsSyncLine: true,
            state: state
        ) {
            LazyVGrid(columns: LibraryPageMetrics.grid(columns), alignment: .leading, spacing: Space.section) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    RecentlyAddedCardLink(item: item, allItems: model.items)
                        .accessibilityIdentifier("library.recentlyAdded.card.\(index)")
                }
            }
            .focusEffectDisabled()
            .prefetchArtwork(model.items.prefix(columns * 3).compactMap { $0.artworkURLs.first })
        }
        .task { await model.load() }
    }

    private var state: LibraryPageState {
        guard model.items.isEmpty else { return .ready }
        if isLoading || model.showsLoading {
            return .loading(.columns(columns, spacing: SCBrowseMetrics.gutter))
        }
        if let error {
            return .message(.failure(.recentlyAdded, message: error, retry: retry))
        }
        return .message(.empty(.recentlyAdded))
    }

    private var subtitle: String? {
        guard !model.items.isEmpty else { return nil }
        let count = model.items.count
        return "\(count.formatted(.number)) \(count == 1 ? "item" : "items")"
    }
}

private struct RecentlyAddedCardLink: View {
    let item: RecentlyAddedItem
    let allItems: [RecentlyAddedItem]

    @EnvironmentObject private var playerService: PlayerService
    @EnvironmentObject private var navigationState: NavigationState

    var body: some View {
        switch item.content {
        case .person(let user):
            NavigationLink {
                ArtistDetailView(user: user)
            } label: {
                SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
                    SCArtistCard(
                        name: item.title,
                        subtitle: item.subtitle,
                        avatarImage: image,
                        identity: item.id,
                        diameter: SCBrowseMetrics.tileEdge,
                        style: SCBrowseMetrics.tile
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SCArtistCardButtonStyle())
            .accessibilityLabel("\(item.title), \(item.subtitle)")

        case .playlist(let playlist):
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                card(subject: .collection, isPrivate: playlist.isPrivate)
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .accessibilityLabel("\(item.title), \(item.subtitle)")

        case .likedTracks:
            Button {
                LibraryRouter.shared.open(.likes, navigationState: navigationState)
            } label: {
                card(subject: .collection)
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .accessibilityLabel("\(item.title), \(item.subtitle)")

        case .collection(let collection):
            NavigationLink {
                TVLocalCollectionView(collection: collection)
            } label: {
                card(subject: .collection)
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .accessibilityLabel("\(item.title), \(item.subtitle)")

        case .likedTrack(let track), .localTrack(let track):
            Button {
                Task {
                    let context = RecentlyAddedFeed.playbackContext(for: item, in: allItems)
                    await playerService.play(track, in: context.isEmpty ? [track] : context)
                }
            } label: {
                card(subject: .track)
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .prewarmPlaybackOnFocus(track)
            .accessibilityLabel("\(item.title), \(item.subtitle)")
        }
    }

    private func card(subject: SoundingArtSubject, isPrivate: Bool = false) -> some View {
        let urls = item.artworkURLs
        let isMosaic = urls.count >= 4
        return SCCollectionArtworkResolver(
            artworkURL: isMosaic ? nil : urls.first,
            trackArtworkURLs: isMosaic ? urls : []
        ) { image in
            SCMediaCard(
                title: item.title,
                subtitle: item.subtitle,
                artworkImage: image,
                artIdentity: item.id,
                artSubject: subject,
                style: SCBrowseMetrics.tile,
                isPrivate: isPrivate
            )
        }
    }
}
