import SwiftUI

/// A vinyl record platter: a black disc with fine concentric grooves, a
/// circular center label (the caller's artwork), and a spindle hole.
///
/// Rotation is derived from the playback position — one turn per
/// `revolutionSeconds` of audio (33⅓ rpm by default) — never from a timer
/// or `repeatForever` animation. Feed it a `SmoothPlaybackTimeline` /
/// `PulseTimeline`-interpolated position and the spin is smooth while
/// playing, frozen while paused, and snapped on seek, at the cost of a
/// single rotation pass per frame.
struct VinylPlatterView<Label: View>: View {
    /// Diameter of the whole disc in points.
    var size: CGFloat
    /// Playback position in seconds. The platter turns
    /// `position / revolutionSeconds` revolutions.
    var position: TimeInterval
    /// Dims the moving sheen when the record isn't turning.
    var isPlaying: Bool = true
    /// Accent used for the deadwax ring around the label.
    var tint: Color = .white
    /// Seconds per revolution. 1.8 s ≈ 33⅓ rpm.
    var revolutionSeconds: Double = 1.8
    /// Label diameter as a fraction of the disc.
    var labelFraction: CGFloat = 0.42
    /// The record label — typically the track's artwork, clipped to a circle.
    @ViewBuilder var label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var angle: Double {
        guard revolutionSeconds > 0, !reduceMotion else { return 0 }
        return (position / revolutionSeconds * 360)
            .truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        ZStack {
            // Disc
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.11),
                            Color(white: 0.045),
                            Color(white: 0.085)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )

            grooves

            // A faint light streak so the rotation reads even across the
            // (radially symmetric) grooves. Rotates with the disc.
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            .clear,
                            .white.opacity(isPlaying ? 0.07 : 0.03),
                            .clear,
                            .clear
                        ],
                        center: .center,
                        startAngle: .degrees(-30),
                        endAngle: .degrees(45)
                    )
                )

            // Deadwax ring between grooves and label
            Circle()
                .stroke(tint.opacity(0.28), lineWidth: 1)
                .frame(width: size * (labelFraction + 0.035), height: size * (labelFraction + 0.035))

            label
                .frame(width: size * labelFraction, height: size * labelFraction)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))

            // Spindle hole
            Circle()
                .fill(Color(white: 0.02))
                .frame(width: max(6, size * 0.035), height: max(6, size * 0.035))
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.30), lineWidth: 1)
                )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .rotationEffect(.degrees(angle))
        .transaction { if reduceMotion { $0.animation = nil } }
        .overlay(
            // Rim highlight, applied after the rotation so it stays put.
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .shadow(color: .black.opacity(0.40), radius: size * 0.03, y: size * 0.015)
    }

    private var grooves: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let outer = canvasSize.width / 2 - 3
            let inner = canvasSize.width / 2 * (labelFraction + 0.05)
            guard outer > inner else { return }
            let count = 30
            for index in 0..<count {
                let radius = inner + (outer - inner) * CGFloat(index) / CGFloat(count - 1)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let opacity: Double = index % 4 == 0 ? 0.09 : 0.045
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(opacity)),
                    lineWidth: 0.7
                )
            }
        }
    }
}

/// Plain tinted label for callers without artwork.
struct VinylPlatterDefaultLabel: View {
    var tint: Color = .white

    var body: some View {
        Circle()
            .fill(tint.opacity(0.16))
            .overlay(
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }
}

extension VinylPlatterView where Label == VinylPlatterDefaultLabel {
    init(
        size: CGFloat,
        position: TimeInterval,
        isPlaying: Bool = true,
        tint: Color = .white,
        revolutionSeconds: Double = 1.8
    ) {
        self.init(
            size: size,
            position: position,
            isPlaying: isPlaying,
            tint: tint,
            revolutionSeconds: revolutionSeconds
        ) {
            VinylPlatterDefaultLabel(tint: tint)
        }
    }
}
