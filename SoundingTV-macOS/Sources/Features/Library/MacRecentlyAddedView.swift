import SwiftUI

struct MacRecentlyAddedView: View {
    @ObservedObject private var model = RecentlyAddedModel.shared

    var body: some View {
        RecentlyAddedStates(model: model, minimumTile: 168) {
            MacViewportScrollView {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                    Text("Recently Added")
                        .font(.largeTitle.weight(.bold))
                        .macFadesUnderToolbar()

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 168, maximum: 252), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(model.items) { item in
                            tile(item)
                        }
                    }
                }
                .padding(SCContentStyle.mac.spaceGutter)
            }
        }
        .macFillsPane()
        .navigationTitle("Recently Added")
        .task { await model.load() }
    }

    @ViewBuilder
    private func tile(_ item: RecentlyAddedItem) -> some View {
        switch item.content {
        case .playlist(let playlist):
            NavigationLink(value: playlist) {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                MacPlaylistContextMenu(playlist: playlist)
            }
            .help(item.title)

        case .likedTracks(let tracks):
            NavigationLink(value: LikesPlaylistRoute()) {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(play: { play(tracks) }) {
                playMenu(tracks)
            }
            .help(item.title)

        case .collection(let collection):
            NavigationLink(value: LibraryCollectionRoute.local(collection)) {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(play: { play(collection.tracks) }) {
                playMenu(collection.tracks)
            }
            .help(item.title)

        case .person(let user):
            NavigationLink(value: user) {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(shape: .circle, play: { Task { await MacPlayback.play(user: user) } }) {
                MacArtistContextMenu(artist: user)
            }
            .help(item.title)

        case .likedTrack(let track):
            Button {
                play([track], context: RecentlyAddedFeed.playbackContext(for: item, in: model.items))
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(play: { play([track], context: RecentlyAddedFeed.playbackContext(for: item, in: model.items)) }) {
                MacTrackContextMenu(track: track)
            }
            .help(item.title)

        case .localTrack(let track):
            Button {
                play([track])
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .macCardHover(play: { play([track]) }) {
                playMenu([track])
            }
            .help(item.title)
        }
    }

    @ViewBuilder
    private func playMenu(_ tracks: [Track]) -> some View {
        Button("Play", systemImage: "play.fill") { play(tracks) }
            .disabled(tracks.isEmpty)
        Button("Shuffle", systemImage: "shuffle") {
            Task { await MacPlayback.shuffle(tracks) }
        }
        .disabled(tracks.count < 2)
    }

    private func play(_ tracks: [Track], context: [Track]? = nil) {
        guard let first = tracks.first else { return }
        Task { await MacPlayback.play(first, in: context ?? tracks) }
    }
}
