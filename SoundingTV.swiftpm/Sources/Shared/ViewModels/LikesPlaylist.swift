import SwiftUI
import Combine

enum LikesPlaylist {
    static let title = "Likes"
    static let artworkIdentity = "sounding.library.likes"

    static func subtitle(trackCount: Int) -> String {
        trackCount == 1 ? "1 track" : "\(trackCount) tracks"
    }

    static func matches(search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || title.localizedCaseInsensitiveContains(needle)
    }
}

@MainActor
final class LikesPlaylistCount: ObservableObject {
    static let shared = LikesPlaylistCount()

    @Published private(set) var trackCount: Int?

    private var observation: AnyCancellable?

    private init() {
        observation = LibrarySyncEngine.shared.$revision.sink { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var subtitle: String? {
        trackCount.map(LikesPlaylist.subtitle(trackCount:))
    }

    func refresh() async {
        trackCount = await LibraryDB.count(.likes)
    }
}

struct LikesPlaylistArtwork: View {
    var cornerRadius: CGFloat = SCContentStyle.tv.cornerCard

    var body: some View {
        GeometryReader { geo in
            let edge = min(geo.size.width, geo.size.height)
            ZStack {
                SoundingArtworkView(identity: LikesPlaylist.artworkIdentity, subject: .collection)
                LinearGradient(
                    colors: [Color.scAccent.opacity(0.85), Color.scAccent.opacity(0.25)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
                Image(systemName: "heart.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: edge * 0.38, height: edge * 0.38)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: max(edge * 0.03, 1), y: max(edge * 0.01, 0.5))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LikesPlaylistCard: View {
    var style: SCContentStyle = .tv

    @ObservedObject private var count = LikesPlaylistCount.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceTight) {
            LikesPlaylistArtwork(cornerRadius: style.artworkCorner)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(LikesPlaylist.title)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Text(count.subtitle ?? " ")
                    .font(style.fontCaption)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .accessibilityElement(children: .combine)
        .task { await count.refresh() }
    }
}
