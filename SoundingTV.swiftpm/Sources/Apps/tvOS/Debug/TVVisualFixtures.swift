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

enum TVMockDestination {
    static var current: String? {
        guard SoundCloudMockService.isEnabled else { return nil }
        return ProcessInfo.processInfo.environment["SOUNDING_TV_UI_DESTINATION"]
    }

    @MainActor
    static func autoplayIfRequested() async {
        guard FixtureAudio.isEnabled, SoundCloudMockService.isEnabled, current == nil else { return }
        for _ in 0..<12 where PlayerService.shared.currentTrack == nil { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(1))
        guard let tracks = try? await SoundCloudAPI.shared.getUserTracks(userId: "101").collection,
              let first = tracks.first(where: { $0.streamURL != nil }) else { return }
        await PlayerService.shared.play(first, in: tracks)
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
        case "settings":
            SettingsView()
        case "network-activity":
            NavigationStack { NetworkActivityView() }
                .onAppear { NetworkActivityFixture.seed() }
        case "library":
            LibraryView()
        case "profile":
            ProfileTabView()
        case "signin":
            QRCodeLoginView()
        case "search":
            SearchView()
        case "now-playing":
            PlayerView()
                .task {
                    guard ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOPLAY"] != "1" else { return }
                    await PlayerService.shared.play(
                        VisualFixtures.tracks[13],
                        in: [VisualFixtures.tracks[13]] + Array(VisualFixtures.tracks.prefix(8))
                    )
                }
        default:
            RootView()
        }
    }
}
#endif
