import SwiftUI

enum LoadingPlaceholderStyle {
    case grid(minimumTile: CGFloat = 160, circular: Bool = false)
    case columns(Int, spacing: CGFloat, circular: Bool = false)
    case trackList(SCTrackListMetrics)
    case shelf(tile: CGFloat, circular: Bool = false)

    static var platformTrackList: LoadingPlaceholderStyle {
        #if os(macOS)
        return .trackList(.mac)
        #elseif os(tvOS)
        return .trackList(.tv)
        #else
        return .trackList(.phoneRoomy)
        #endif
    }
}

struct LoadingPlaceholder: View {
    let style: LoadingPlaceholderStyle
    var count: Int?
    var showsSyncStatus = false
    var insets = true

    init(_ style: LoadingPlaceholderStyle, count: Int? = nil, showsSyncStatus: Bool = false, insets: Bool = true) {
        self.style = style
        self.count = count
        self.showsSyncStatus = showsSyncStatus
        self.insets = insets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsSyncStatus {
                LibrarySyncStatusLine()
            }
            shapes
                .redacted(reason: .placeholder)
                .loadingShimmer()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, insets ? horizontalInset : 0)
        .padding(.top, insets ? 8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loading")
        #if os(tvOS)
        .focusable()
        .focusEffectDisabled()
        #else
        .allowsHitTesting(false)
        #endif
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        return 80
        #elseif os(macOS)
        return 24
        #else
        return 20
        #endif
    }

    @ViewBuilder
    private var shapes: some View {
        switch style {
        case .grid(let minimumTile, let circular):
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumTile, maximum: minimumTile * 1.5), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(0..<(count ?? 12), id: \.self) { index in
                    LoadingPlaceholderTile(index: index, circular: circular)
                }
            }
        case .columns(let columns, let spacing, let circular):
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: max(columns, 1)),
                alignment: .leading,
                spacing: spacing
            ) {
                ForEach(0..<(count ?? columns * 3), id: \.self) { index in
                    LoadingPlaceholderTile(index: index, circular: circular)
                }
            }
        case .trackList(let metrics):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<(count ?? 14), id: \.self) { index in
                    LoadingPlaceholderRow(index: index, metrics: metrics)
                }
            }
        case .shelf(let tile, let circular):
            VStack(alignment: .leading, spacing: 12) {
                Text(LoadingPlaceholderText.shelf)
                    .font(.title3.weight(.semibold))
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<(count ?? 8), id: \.self) { index in
                        LoadingPlaceholderTile(index: index, circular: circular)
                            .frame(width: tile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
    }
}

private enum LoadingPlaceholderText {
    static let titles = [
        "Placeholder title",
        "A longer placeholder title",
        "Short title",
        "Placeholder track name here",
        "Another title",
        "Medium length title",
    ]
    static let subtitles = [
        "Artist name",
        "Another artist",
        "Placeholder artist name",
        "Artist",
    ]
    static let shelf = "Placeholder shelf"

    static func title(_ index: Int) -> String { titles[index % titles.count] }
    static func subtitle(_ index: Int) -> String { subtitles[index % subtitles.count] }
}

private struct LoadingPlaceholderTile: View {
    let index: Int
    let circular: Bool

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: 4) {
            artwork
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 4)
            Text(LoadingPlaceholderText.title(index))
                .font(.subheadline)
                .lineLimit(1)
            Text(LoadingPlaceholderText.subtitle(index))
                .font(.subheadline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
    }

    @ViewBuilder
    private var artwork: some View {
        if circular {
            Circle().fill(.fill.tertiary)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.fill.tertiary)
        }
    }
}

private struct LoadingPlaceholderRow: View {
    let index: Int
    let metrics: SCTrackListMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            RoundedRectangle(cornerRadius: metrics.artworkCorner, style: .continuous)
                .fill(.fill.tertiary)
                .frame(width: metrics.artworkSize, height: metrics.artworkSize)
            if metrics.isSingleLine {
                Text(LoadingPlaceholderText.title(index))
                    .font(metrics.titleFont)
                    .lineLimit(1)
                Spacer(minLength: metrics.spacing)
                Text(LoadingPlaceholderText.subtitle(index))
                    .font(metrics.subtitleFont)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LoadingPlaceholderText.title(index))
                        .font(metrics.titleFont)
                        .lineLimit(1)
                    Text(LoadingPlaceholderText.subtitle(index))
                        .font(metrics.subtitleFont)
                        .lineLimit(1)
                }
                Spacer(minLength: metrics.spacing)
            }
            Text("0:00")
                .font(metrics.detailFont)
                .frame(minWidth: metrics.durationMinWidth, alignment: .trailing)
        }
        .padding(.vertical, metrics.verticalPadding)
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(minHeight: metrics.minHeight)
    }
}

private struct LoadingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var sweeping = false

    private var isActive: Bool {
        !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func body(content: Content) -> some View {
        if isActive {
            content
                .mask {
                    GeometryReader { proxy in
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.6), location: 0.3),
                                .init(color: .black, location: 0.5),
                                .init(color: .black.opacity(0.6), location: 0.7),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 3)
                        .offset(x: sweeping ? 0 : -proxy.size.width * 2)
                    }
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        sweeping = true
                    }
                }
                .onDisappear { sweeping = false }
        } else {
            content
        }
    }
}

extension View {
    func loadingShimmer() -> some View {
        modifier(LoadingShimmer())
    }
}
