#if os(iOS) || os(macOS)
import SwiftUI

struct RecentlyAddedFeedTile: View {
    let item: RecentlyAddedItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: item.isCircular ? .center : .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { artwork }
                .clipShape(shape)
                .contentShape(shape)
                #if os(iOS)
                .contentShape(.hoverEffect, shape)
                .hoverEffect(.lift)
                #endif
                .padding(.bottom, 4)

            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(item.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .frame(maxWidth: .infinity, alignment: item.isCircular ? .center : .leading)
        .multilineTextAlignment(item.isCircular ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }

    @ViewBuilder
    private var artwork: some View {
        let urls = item.artworkURLs
        if urls.count == 4 {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cell(urls[0], index: 0)
                    cell(urls[1], index: 1)
                }
                HStack(spacing: 0) {
                    cell(urls[2], index: 2)
                    cell(urls[3], index: 3)
                }
            }
        } else {
            single(urls.first)
        }
    }

    private func cell(_ url: URL, index: Int) -> some View {
        single(url, identity: "\(item.id).\(index)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    @ViewBuilder
    private func single(_ url: URL?, identity: String? = nil) -> some View {
        #if os(macOS)
        GeometryReader { proxy in
            ArtworkThumbnail(
                url: url,
                identity: identity ?? item.id,
                size: proxy.size.width,
                cornerRadius: 0
            )
        }
        #else
        ArtworkImage(url: url, variant: .standard) {
            ArtworkPlaceholder(icon: item.placeholderSymbol, identity: identity ?? item.id)
        }
        #endif
    }

    private var shape: AnyShape {
        item.isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RecentlyAddedStates<Content: View>: View {
    @ObservedObject var model: RecentlyAddedModel
    var minimumTile: CGFloat = 160
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.items.isEmpty {
            if model.showsLoading {
                LoadingPlaceholder(.grid(minimumTile: minimumTile), showsSyncStatus: true)
            } else {
                ContentUnavailableView {
                    Label("Nothing Added Yet", systemImage: "clock")
                } description: {
                    Text("Tracks you like, playlists you make or like, people you follow and music you add appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            content()
        }
    }
}
#endif
