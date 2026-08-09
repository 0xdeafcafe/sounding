import SwiftUI

private func playlistGridColumns(_ count: Int) -> [GridItem] {
    Array(repeating: .init(.flexible(), spacing: Space.gutter), count: max(1, count))
}

struct PlaylistGridView: View {
    let playlists: [Playlist]
    var columns: Int = 4
    var onNearEnd: (() -> Void)?
    var isLoadingMore = false
    var emptyIcon = "music.note.list"
    var emptyTitle = "No playlists"

    private static let artworkLookahead = 12

    var body: some View {
        if playlists.isEmpty {
            StatusPanel(kind: .empty, icon: emptyIcon, title: emptyTitle, minHeight: 320)
        } else {
            VStack(spacing: Space.base) {
                LazyVGrid(columns: playlistGridColumns(columns), spacing: Space.gutter) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            PlaylistCard(playlist: playlist)
                        }
                        .onAppear {
                            guard let onNearEnd, playlists.isNearEnd(playlist, lead: 12) else { return }
                            onNearEnd()
                        }
                        .onAppear {
                            let lookahead = playlists[index..<min(index + Self.artworkLookahead, playlists.count)]
                            ArtworkCache.shared.prefetch(lookahead.compactMap(\.displayArtworkURL))
                        }
                    }
                }
                .buttonStyle(SCCardButtonStyle())
                .focusEffectDisabled()

                if isLoadingMore {
                    LoadingMoreRow()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ArtworkImage(url: playlist.displayArtworkURL, icon: "music.note.list")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .kyleCrowned(user: playlist.user, context: playlist.title)

            VStack(alignment: .leading, spacing: 0) {
                Text(playlist.title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(typeLine)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var typeLine: String {
        playlist.isAlbum ? playlist.user.displayName : "Playlist"
    }
}
