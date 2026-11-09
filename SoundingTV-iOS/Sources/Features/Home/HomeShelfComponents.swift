import SwiftUI

enum PhoneLayout {
    static let margin: CGFloat = Space.roomy
    static let tileGap: CGFloat = Space.base
    static let shelfGap: CGFloat = Space.section
    static let headerGap: CGFloat = Space.snug
    static let heroPeek: CGFloat = 24
    static let listIconWidth: CGFloat = 30
}

struct PhoneSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct HomeHeroCardLabel: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let identity: String
    var subject: SoundingArtSubject = .track
    var isAvailable = true
    let width: CGFloat

    var body: some View {
        HomeHeroCardContent(card: self)
            .collectionAccent(from: artworkURL)
    }
}

private struct HomeHeroCardContent: View {
    let card: HomeHeroCardLabel

    @Environment(\.collectionAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ground: Color {
        accent?.wash(for: .dark) ?? Color(white: 0.16)
    }

    var body: some View {
        VStack(spacing: 0) {
            SCArtworkResolver(url: card.artworkURL) { image in
                SCArtwork(
                    image: image,
                    identity: card.identity,
                    isAvailable: card.isAvailable,
                    style: .phone,
                    cornerRadius: 0,
                    subject: card.subject
                )
            }
            .frame(width: card.width, height: card.width)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
                    .frame(height: card.width * 0.28)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(card.eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(card.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(.horizontal, Space.base)
            .padding(.bottom, Space.base)
        }
        .frame(width: card.width)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: SCContentStyle.phone.cornerPanel, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .opacity(card.isAvailable ? 1 : 0.72)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: accent)
        .accessibilityElement(children: .combine)
    }
}

struct HomeShelfDetailView: View {
    let shelf: DiscoveryShelf

    @Namespace private var heroNamespace
    @StateObject private var confirmation = QueueConfirmationController()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    private var columns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        let available = width - PhoneLayout.margin * 2
        return max(2, Int(((available + PhoneLayout.tileGap) / (160 + PhoneLayout.tileGap)).rounded(.down)))
    }

    private var tileSize: CGFloat {
        guard width > 0 else { return 150 }
        let available = width - PhoneLayout.margin * 2
        let count = CGFloat(columns)
        return ((available - PhoneLayout.tileGap * (count - 1)) / count).rounded(.down)
    }

    var body: some View {
        content
            .navigationTitle(shelf.title)
            .navigationBarTitleDisplayMode(.large)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .queueConfirmationOverlay(confirmation)
    }

    @ViewBuilder
    private var content: some View {
        if case .tracks(let tracks) = shelf.content {
            List {
                ForEach(tracks) { track in
                    TrackListRow(track: track, context: { tracks }, confirmation: confirmation)
                }
            }
            .listStyle(.plain)
            .prefetchArtwork(tracks.prefix(24).compactMap(\.artworkURL), variant: .thumbnail)
        } else {
            ScrollView {
                HomeShelfView(shelf: shelf, heroNamespace: heroNamespace, tileSize: tileSize, layout: .grid(columns: columns))
                    .padding(.vertical, Space.base)
            }
        }
    }
}
