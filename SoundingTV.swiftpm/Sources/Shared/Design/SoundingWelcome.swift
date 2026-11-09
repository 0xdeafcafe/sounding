import SwiftUI

enum SoundingWelcome {
    static let headline = "Plug in. Turn it up."
    static let stackedHeadline = "Plug in.\nTurn it up."

    static var tagline: String {
        #if os(macOS)
        "Your SoundCloud on Mac, iPhone and Apple TV."
        #elseif os(tvOS)
        "Your SoundCloud on Apple TV, iPhone and Mac."
        #else
        "Your SoundCloud on iPhone, Mac and Apple TV."
        #endif
    }

    static let signInTint = Color.scAccent
}

struct SoundingWelcomeHero: View {
    var seed: UInt64
    var style: SoundingLineArt.Style = .hero
    var loop: SoundingLineArt.Loop = .ambient
    var isActive = true
    var fadeFrom: CGFloat = 0.72
    var colorScheme: ColorScheme?

    @Environment(\.colorScheme) private var inheritedScheme

    var body: some View {
        SoundingLineArt(seed: seed, style: style, loop: loop, isActive: isActive)
            .environment(\.colorScheme, colorScheme ?? inheritedScheme)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: fadeFrom),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .accessibilityHidden(true)
    }
}

struct SoundingWelcomeTitle: View {
    var title = SoundingWelcome.headline
    var message = SoundingWelcome.tagline
    var titleFont: Font = .largeTitle.weight(.bold)
    var messageFont: Font = .body
    var messageStyle = AnyShapeStyle(.secondary)
    var spacing: CGFloat = 10

    var body: some View {
        VStack(spacing: spacing) {
            Text(title)
                .font(titleFont)
                .accessibilityAddTraits(.isHeader)
            if !message.isEmpty {
                Text(message)
                    .font(messageFont)
                    .foregroundStyle(messageStyle)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SoundingSoundRings: View {
    var level: Double
    var idle: Double = 0.18
    var rings = 5
    var palette: SoundingArtPalette?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = palette ?? SoundingArtPalette.resolve(colorScheme)
        let energy = min(1, max(0, level))
        let swell = reduceMotion ? 0 : energy
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(palette.masses[0])
                    .frame(width: side * 0.6, height: side * 0.6)
                    .scaleEffect(1 + swell * 0.16)
                    .opacity(0.85 * (idle + (1 - idle) * energy))
                ForEach(0..<rings, id: \.self) { index in
                    let reach = Double(index + 1) / Double(rings)
                    Circle()
                        .stroke(palette.inks[index % palette.inks.count], lineWidth: max(1.5, side * 0.008))
                        .frame(width: side * (0.44 + 0.56 * reach), height: side * (0.44 + 0.56 * reach))
                        .scaleEffect(1 + swell * 0.12 * reach)
                        .opacity((idle + (1 - idle) * energy) * (1.15 - 0.55 * reach))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
