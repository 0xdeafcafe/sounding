#if os(iOS) || os(macOS)
import SwiftUI

enum SearchMotion {
    static let state = Animation.smooth(duration: 0.28)
    static let pills = Animation.snappy(duration: 0.25)
}

struct SearchFilterPills: View {
    @Binding var selection: SearchResultFilter
    let filters: [SearchResultFilter]
    var horizontalInset: CGFloat = 20

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(filters) { filter in
                        pill(filter)
                            .id(filter)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: selection) { _, value in
                withAnimation(reduceMotion ? nil : SearchMotion.pills) { proxy.scrollTo(value, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private func pill(_ filter: SearchResultFilter) -> some View {
        let isSelected = selection == filter
        return Button {
            withAnimation(reduceMotion ? nil : SearchMotion.pills) { selection = filter }
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.scAccentOn : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.scAccent)
                            .matchedGeometryEffect(id: "selected", in: namespace)
                    }
                }
                .contentShape(Capsule())
                #if os(iOS)
                .frame(minHeight: 44)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SearchThumbnail: View {
    let url: URL?
    let identity: String
    var isCircle = false
    var size: CGFloat = 56

    var body: some View {
        SCArtworkResolver(url: url, variant: size <= 64 ? .thumbnail : .standard) { image in
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(
                    identity: identity,
                    subject: isCircle ? .person : .collection,
                    displaySize: CGSize(width: size, height: size)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: max(4, size * 0.12), style: .continuous)))
        .accessibilityHidden(true)
    }
}

struct SearchResultRowLabel: View {
    let item: SearchResultItem
    var thumbnailSize: CGFloat = 56

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var artworkURL: URL? {
        switch item.hit {
        case .artist(let user): return user.avatarURL
        default: return item.hit.artworkURL
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(url: artworkURL, identity: item.hit.id, isCircle: item.isCircle, size: thumbnailSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.hit.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                HStack(spacing: 6) {
                    Text(SearchTypeLine.text(item))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    if let track = item.hit.track {
                        SoundCloudTrackBadge(track: track)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: thumbnailSize + 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SearchRecentCard: View {
    let entry: RecentSearchEntry
    var thumbnailSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(url: entry.avatarURL, identity: entry.id, isCircle: entry.isCircle, size: thumbnailSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.query)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .libraryRowPreviewShape(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}

struct SearchCategoryTile: View {
    let category: SearchCategory
    var cornerRadius: CGFloat = 12
    var aspectRatio: CGFloat = 1.45

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [category.top, category.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                    SoundingArtworkView(
                        seed: GeneratedArtworkIdentity.hash("category:" + category.id),
                        subject: .genre,
                        tint: category.tint,
                        motif: category.motif,
                        colorScheme: .dark
                    )
                    .blendMode(.screen)
                    .opacity(0.5)
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.32)], startPoint: .center, endPoint: .bottom)
                    Text(category.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(12)
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .libraryCardPreviewShape(cornerRadius: cornerRadius)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.title)
    }
}

extension EnvironmentValues {
    @Entry var trackRowShowsType = false
}
#endif
