import SwiftUI

extension View {
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    func liquidGlass<S: Shape, ID: Hashable & Sendable>(
        in shape: S,
        id: ID,
        namespace: Namespace.ID,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
            .glassEffectID(id, in: namespace)
    }
}

private struct LiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        let effect: Glass = {
            var g: Glass = .regular
            if let tint { g = g.tint(tint) }
            if interactive { g = g.interactive() }
            return g
        }()
        content.glassEffect(effect, in: shape)
    }
}

struct DynamicBackground: View {
    @ObservedObject var colors: ArtworkColors = .shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let artworkLayerOpacity: Double = 0.55
    private static let additiveHeadroom: Double = 1.15

    var body: some View {
        ZStack {
            Color.scBgBase

            if let artwork = colors.current.artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90, opaque: true)
                    .opacity(Self.artworkLayerOpacity)
                    .saturation(1.35)
            }

            LinearGradient(
                colors: [
                    colors.current.primary.opacity(0.55),
                    colors.current.secondary.opacity(0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.overlay)

            Color.black.opacity(
                colors.current.backdropScrim(
                    layerOpacity: Self.artworkLayerOpacity,
                    additiveHeadroom: Self.additiveHeadroom
                )
            )

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.50)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .scMotion(Motion.ambient, reduceMotion: reduceMotion, value: colors.current.primary)
        .scMotion(Motion.ambient, reduceMotion: reduceMotion, value: colors.current.secondary)
    }
}

struct AmbientBackdrop: View {
    @ObservedObject var colors: ArtworkColors = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let artworkLayerOpacity: Double = 0.30
    private static let additiveHeadroom: Double = 1.10

    private var palette: ArtworkColors.Palette { colors.current }

    var body: some View {
        ZStack {
            Color.scBgBase

            if let artwork = palette.artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 120, opaque: true)
                    .saturation(1.30)
                    .opacity(Self.artworkLayerOpacity)

                LinearGradient(
                    colors: [palette.primary.opacity(0.55), palette.secondary.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.overlay)

                Color.black.opacity(
                    palette.backdropScrim(
                        layerOpacity: Self.artworkLayerOpacity,
                        additiveHeadroom: Self.additiveHeadroom
                    )
                )
            } else {
                fallbackField
            }

        }
        .ignoresSafeArea()
        .scMotion(Motion.ambient, reduceMotion: reduceMotion, value: palette.primary)
        .scMotion(Motion.ambient, reduceMotion: reduceMotion, value: palette.accent)
    }

    private var fallbackField: some View {
        ZStack {
            gradedField
            RadialGradient(
                colors: [Color.scAccent.opacity(0.05), .clear],
                center: .topLeading,
                startRadius: 120,
                endRadius: 1900
            )
        }
    }

    private var gradedField: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.1067, green: 0.1003, blue: 0.1014), location: 0.0),
                .init(color: Color(red: 0.1799, green: 0.1651, blue: 0.1601), location: 0.55),
                .init(color: Color(red: 0.2673, green: 0.2431, blue: 0.2219), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct LoadingMoreRow: View {
    var body: some View {
        HStack(spacing: Space.snug) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Loading more…")
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
        }
        .padding(.vertical, Space.base)
        .padding(.horizontal, Space.roomy)
        .focusable(false)
    }
}

struct ContentSkeleton: View {
    enum Lockup: Equatable {
        case list(rows: Int = 6)
        case grid(columns: Int, rows: Int = 3, circular: Bool = false)
    }

    let lockup: Lockup
    let title: String

    @State private var sweep: CGFloat = 0
    @FocusState private var skeletonFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepDuration: Double = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gutter) {
            header
            shapes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scFocus(skeletonFocused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
        .focusable()
        .focused($skeletonFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("content.skeleton")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: Self.sweepDuration).repeatForever(autoreverses: false)) {
                sweep = 1
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.snug) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text(title)
                .font(.tvBodyEmph)
                .foregroundStyle(Color.scTextSecondary)
        }
    }

    @ViewBuilder
    private var shapes: some View {
        switch lockup {
        case .list(let rows):
            VStack(spacing: Space.tight) {
                ForEach(0..<max(1, rows), id: \.self) { _ in
                    listRow
                }
            }

        case .grid(let columns, let rows, let circular):
            VStack(spacing: Space.gutter) {
                ForEach(0..<max(1, rows), id: \.self) { _ in
                    HStack(spacing: Space.gutter) {
                        ForEach(0..<max(1, columns), id: \.self) { _ in
                            gridCell(circular: circular)
                        }
                    }
                }
            }
        }
    }

    private var listRow: some View {
        HStack(spacing: Space.snug) {
            plate(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: Space.hair) {
                bar(width: 620, height: 22)
                bar(width: 340, height: 18)
            }

            Spacer(minLength: Space.snug)

            bar(width: 84, height: 18)
        }
        .padding(Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridCell(circular: Bool) -> some View {
        let alignment: HorizontalAlignment = circular ? .center : .leading
        let frameAlignment: Alignment = circular ? .center : .leading
        return VStack(alignment: alignment, spacing: Space.tight) {
            Group {
                if circular {
                    plate(Circle())
                } else {
                    plate(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                }
            }
            .aspectRatio(1, contentMode: .fit)

            GeometryReader { geo in
                VStack(alignment: alignment, spacing: 0) {
                    bar(width: geo.size.width * 0.75, height: 22)
                        .padding(.vertical, 4)
                    bar(width: geo.size.width * 0.5, height: 18)
                        .padding(.vertical, 4)
                }
                .frame(width: geo.size.width, alignment: frameAlignment)
            }
            .frame(height: 62)
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        plate(Capsule())
            .frame(width: max(24, width), height: height)
    }

    private func plate<S: Shape>(_ shape: S) -> some View {
        shape
            .fill(Color.scBgRaised)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let band = max(80, geo.size.width * 0.45)
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.10), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + sweep * (geo.size.width + band))
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
    }
}

struct StatusPanel: View {
    enum Kind {
        case loading
        case empty
        case error
    }

    let kind: Kind
    var icon: String = "music.note"
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var minHeight: CGFloat = 520

    @FocusState private var panelFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAction: Bool { actionTitle != nil && action != nil }

    var body: some View {
        VStack(spacing: Space.snug) {
            switch kind {
            case .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    .tint(.white)
            case .empty:
                Image(systemName: icon)
                    .font(.system(size: 88, weight: .heavy))
                    .foregroundStyle(Color.scTextTertiary)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 72, weight: .heavy))
                    .foregroundStyle(Color.scDestructive)
            }

            Text(title)
                .font(.tvHeadline)
                .foregroundStyle(Color.scTextPrimary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.scAccent)
                .foregroundStyle(Color.scAccentOn)
                .padding(.top, Space.tight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .scFocus(panelFocused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
        .focusable(!hasAction)
        .focused($panelFocused)
        .focusEffectDisabled()
    }
}
