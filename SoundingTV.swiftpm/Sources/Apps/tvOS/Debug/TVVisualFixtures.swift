#if DEBUG
import Foundation
import SwiftUI

extension VisualFixtures {
    static var homeShelves: [HomeShelf] {
        [
            HomeShelf(
                id: "fixture.picks", title: "Top Picks for You",
                items: .collections(albums.prefix(5).map { HomeCollection(playlist: $0, kicker: "Made for You") }, .cards)
            ),
            HomeShelf(id: "fixture.recent", title: "Recently Played", items: .tracks(Array(tracks.prefix(8)))),
            HomeShelf(
                id: "fixture.playlists", title: "Playlists Made for You",
                items: .collections(playlists.prefix(5).map { HomeCollection(playlist: $0, kicker: "For You") }, .cards)
            ),
            HomeShelf(id: "fixture.artists", title: "Artists to Explore", items: .artists(artists)),
        ]
    }
}

struct TVVisualFixtureDestinationView: View {
    let destination: String

    var body: some View {
        switch destination.lowercased() {
        case "artist":
            NavigationStack { ArtistDetailView(user: VisualFixtures.artists[0]) }
        case "album":
            NavigationStack { PlaylistDetailView(playlist: VisualFixtures.albums[0]) }
        case "playlist":
            NavigationStack { PlaylistDetailView(playlist: VisualFixtures.playlists[0]) }
        case "behind-track":
            BehindTheTrackView(track: VisualFixtures.tracks[0], palette: ArtworkColors.shared.current)
        case "now-playing":
            PlayerView()
                .task {
                    await PlayerService.shared.play(
                        VisualFixtures.tracks[13],
                        in: Array(VisualFixtures.tracks.prefix(8)) + [VisualFixtures.tracks[13]]
                    )
                }
        default:
            RootView()
        }
    }
}
#endif
