import SwiftUI

struct AmbientArtworkSeed: Equatable {
    var artwork: Image?
    var colors: [Color]
    var accent: Color
    var scrim: Double

    static let fallback = AmbientArtworkSeed(
        artwork: nil,
        colors: [
            Color(red: 0.10, green: 0.10, blue: 0.16),
            Color(red: 0.05, green: 0.05, blue: 0.09),
            Color(red: 0.08, green: 0.07, blue: 0.13),
            Color(red: 0.04, green: 0.04, blue: 0.07)
        ],
        accent: Color(red: 1.00, green: 0.42, blue: 0.10),
        scrim: 0.32
    )

    var resolvedColors: [Color] {
        let base = colors.isEmpty ? AmbientArtworkSeed.fallback.colors : colors
        guard base.count < 4 else { return base }
        return (0..<4).map { base[$0 % base.count] }
    }

    static func == (lhs: AmbientArtworkSeed, rhs: AmbientArtworkSeed) -> Bool {
        lhs.colors == rhs.colors && lhs.accent == rhs.accent && lhs.scrim == rhs.scrim
    }
}

struct AmbientArtworkBackdrop: View {
    var seed: AmbientArtworkSeed
    var isAnimated: Bool = true
    var intensity: Double = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isAnimated && !reduceMotion {
                TimelineView(.animation(minimumInterval: animationInterval)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    layers(at: t)
                }
            } else {
                layers(at: 0)
            }
        }
        .background(seed.resolvedColors.first ?? .black)
        .clipped()
        .animation(SCContentMotion.ambient, value: seed)
    }

    private var animationInterval: TimeInterval {
        #if os(macOS)
        // The mesh itself moves on multi-second curves. Eight refreshes per
        // second looks continuous while avoiding a permanent 30 fps GPU load.
        1.0 / 8.0
        #else
        1.0 / 12.0
        #endif
    }

    @ViewBuilder
    private func layers(at t: TimeInterval) -> some View {
        ZStack {
            AmbientMesh(colors: seed.resolvedColors, phase: t, intensity: intensity)

            if let artwork = seed.artwork {
                AmbientArtworkWash(artwork: artwork, phase: t, intensity: intensity)
            }

            AmbientSheen(accent: seed.accent, phase: t, intensity: intensity)

            Color.black.opacity(seed.scrim)
        }
    }
}

private struct AmbientMesh: View {
    let colors: [Color]
    let phase: TimeInterval
    let intensity: Double

    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: meshColors)
            .saturation(1.0 + 0.10 * intensity)
    }

    private var points: [SIMD2<Float>] {
        let drift = Float(0.055 * intensity)
        func wobble(_ speed: Double, _ offset: Double) -> Float {
            Float(sin(phase * speed + offset)) * drift
        }

        return [
            SIMD2(0.0, 0.0),
            SIMD2(0.5 + wobble(0.061, 0.0), 0.0),
            SIMD2(1.0, 0.0),
            SIMD2(0.0, 0.5 + wobble(0.047, 1.3)),
            SIMD2(0.5 + wobble(0.039, 2.1), 0.5 + wobble(0.053, 0.7)),
            SIMD2(1.0, 0.5 + wobble(0.043, 3.4)),
            SIMD2(0.0, 1.0),
            SIMD2(0.5 + wobble(0.057, 4.2), 1.0),
            SIMD2(1.0, 1.0)
        ]
    }

    private var meshColors: [Color] {
        let c = colors
        let a = c[0]
        let b = c[1 % c.count]
        let d = c[2 % c.count]
        let e = c[3 % c.count]
        return [a, b, d, e, a, b, d, e, a]
    }
}

private struct AmbientArtworkWash: View {
    let artwork: Image
    let phase: TimeInterval
    let intensity: Double

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            let kenBurns = 1.18 + 0.06 * sin(phase * 0.021)
            let dx = CGFloat(sin(phase * 0.017)) * side * 0.035
            let dy = CGFloat(cos(phase * 0.013)) * side * 0.028

            artwork
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .blur(radius: side * 0.14, opaque: false)
                .scaleEffect(kenBurns)
                .offset(x: dx, y: dy)
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(0.55 * intensity)
                .blendMode(.softLight)
        }
    }
}

private struct AmbientSheen: View {
    let accent: Color
    let phase: TimeInterval
    let intensity: Double

    var body: some View {
        GeometryReader { geo in
            let travel = (sin(phase * 0.029) + 1) / 2
            let width = geo.size.width

            LinearGradient(
                colors: [.clear, accent.opacity(0.16 * intensity), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: width * 0.7)
            .offset(x: (width * 1.7) * travel - width * 0.85)
            .blur(radius: width * 0.09)
            .blendMode(.plusLighter)
        }
    }
}
