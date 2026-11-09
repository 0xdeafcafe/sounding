import SwiftUI

struct ListeningHistoryStatusView: View {
    let phase: ListeningHistory.Phase
    let retry: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
                    .remoteFocusTarget()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: retry)
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No Listening History", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Tracks you play appear here.")
                }
                .remoteFocusTarget()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ListeningHistoryCollectionCard: View {
    let collection: ListeningHistoryCollection
    let style: SCContentStyle
    let side: CGFloat

    private var entry: DiscoveryEntry { collection.entry }

    var body: some View {
        Group {
            switch entry {
            case .user(let user):
                SCArtworkResolver(url: entry.artworkURL) { image in
                    SCArtistCard(
                        name: user.displayName,
                        subtitle: "Artist",
                        avatarImage: image,
                        identity: entry.artIdentity,
                        diameter: side,
                        crownUser: user,
                        crownContext: user.displayName,
                        style: style
                    )
                }
            case .playlist(let playlist):
                SCCollectionArtworkResolver(
                    artworkURL: playlist.largeDisplayArtworkURL ?? playlist.displayArtworkURL,
                    trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                    variant: .standard
                ) { image in
                    SCMediaCard(
                        title: playlist.title,
                        subtitle: "\(CollectionPageKind(playlist: playlist).label) · \(playlist.user.displayName)",
                        artworkImage: image,
                        artIdentity: playlist.id,
                        artSubject: .collection,
                        crownUser: playlist.user,
                        crownContext: playlist.title,
                        style: style
                    )
                }
            case .station:
                SCArtworkResolver(url: entry.artworkURL) { image in
                    SCMediaCard(
                        title: entry.cardTitle,
                        subtitle: "Station",
                        artworkImage: image,
                        artIdentity: entry.artIdentity,
                        artSubject: .station,
                        style: style
                    )
                }
            }
        }
        .frame(width: side, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch entry {
        case .user(let user): return "\(user.displayName), artist"
        case .playlist(let playlist): return "\(playlist.title), \(CollectionPageKind(playlist: playlist).label.lowercased()) by \(playlist.user.displayName)"
        case .station: return "\(entry.cardTitle), station"
        }
    }
}
