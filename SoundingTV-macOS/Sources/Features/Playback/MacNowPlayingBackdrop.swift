import SwiftUI
import AppKit
import QuartzCore
import CoreImage

struct MacNowPlayingBackdrop: NSViewRepresentable {
    var artworkURL: URL?
    var palette: ArtworkPalette
    var isAnimating: Bool
    var reduceMotion: Bool
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: BackdropView, context: Context) {
        update(nsView)
    }

    private func update(_ view: BackdropView) {
        let stops = palette.gradientStops.map { NSColor($0).usingColorSpace(.sRGB) ?? .black }
        let accent = NSColor(palette.accent).usingColorSpace(.sRGB) ?? .systemOrange
        view.apply(
            url: reduceTransparency ? nil : artworkURL,
            colors: [stops.first ?? .black, accent, stops.last ?? .black],
            drifts: !reduceMotion,
            animating: isAnimating
        )
    }

    final class BackdropView: NSView {
        private let stage = CALayer()
        private let scrim = CAGradientLayer()
        private var current: Layer?
        private var currentKey: String?
        private var loadTask: Task<Void, Never>?
        private var drifts = true
        private var isPaused = false

        private struct Layer {
            let group: CALayer
            let art: CALayer
            let blobs: [CAGradientLayer]
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            layer?.addSublayer(stage)
            scrim.colors = [NSColor.black.withAlphaComponent(0.36).cgColor, NSColor.black.withAlphaComponent(0.66).cgColor]
            scrim.startPoint = CGPoint(x: 0.5, y: 1)
            scrim.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(scrim)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.frame = bounds
            scrim.frame = bounds
            if let current { place(current) }
            CATransaction.commit()
        }

        func apply(url: URL?, colors: [NSColor], drifts: Bool, animating: Bool) {
            let key = (url?.absoluteString ?? "none") + colors.map { $0.description }.joined()
            let driftChanged = drifts != self.drifts
            self.drifts = drifts
            if key != currentKey || driftChanged {
                currentKey = key
                loadTask?.cancel()
                let cgColors = colors.map(\.cgColor)
                loadTask = Task { @MainActor [weak self] in
                    let image = await Self.blurredArtwork(url)
                    guard !Task.isCancelled, let self else { return }
                    self.install(image: image, colors: cgColors)
                }
            }
            setPaused(!animating)
        }

        private func install(image: CGImage?, colors: [CGColor]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let group = CALayer()
            let art = CALayer()
            art.contents = image
            art.opacity = 0.82
            art.contentsGravity = .resizeAspectFill
            art.backgroundColor = colors.first
            group.addSublayer(art)
            let opacities: [Float] = [0.42, 0.26, 0.4]
            let blobs = colors.prefix(3).enumerated().map { index, color -> CAGradientLayer in
                let blob = CAGradientLayer()
                blob.type = .radial
                blob.colors = [color, color.copy(alpha: 0) ?? color]
                blob.startPoint = CGPoint(x: 0.5, y: 0.5)
                blob.endPoint = CGPoint(x: 1, y: 1)
                blob.opacity = opacities[index]
                group.addSublayer(blob)
                return blob
            }
            let next = Layer(group: group, art: art, blobs: blobs)
            place(next)
            stage.addSublayer(group)
            if drifts { addDrift(to: next) }
            CATransaction.commit()

            if let previous = current {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 1.1
                fade.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil)
                fade.fillMode = .backwards
                group.add(fade, forKey: "fade")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    previous.group.removeFromSuperlayer()
                }
            }
            current = next
        }

        private func place(_ layer: Layer) {
            let size = bounds.size
            layer.group.frame = bounds
            layer.art.frame = bounds.insetBy(dx: -size.width * 0.3, dy: -size.height * 0.3)
            let frames: [CGRect] = [
                CGRect(x: -size.width * 0.35, y: size.height - size.width * 0.95 + size.height * 0.2, width: size.width * 0.95, height: size.width * 0.95),
                CGRect(x: size.width * 0.45, y: -size.height * 0.25, width: size.width * 0.95, height: size.width * 0.95),
                CGRect(x: size.width * 0.1, y: size.height * 0.65 - size.width * 0.7, width: size.width * 0.7, height: size.width * 0.7),
            ]
            for (blob, frame) in zip(layer.blobs, frames) { blob.frame = frame }
        }

        private func addDrift(to layer: Layer) {
            func transform(dx: CGFloat, dy: CGFloat, degrees: CGFloat, scale: CGFloat) -> CATransform3D {
                var t = CATransform3DMakeTranslation(dx, dy, 0)
                t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
                return CATransform3DScale(t, scale, scale, 1)
            }
            let size = bounds.size
            let drift = CABasicAnimation(keyPath: "transform")
            drift.fromValue = transform(dx: -size.width * 0.03, dy: size.height * 0.02, degrees: -4, scale: 1.02)
            drift.toValue = transform(dx: size.width * 0.03, dy: -size.height * 0.03, degrees: 6, scale: 1.14)
            drift.duration = 44
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.art.add(drift, forKey: "drift")

            let durations: [CFTimeInterval] = [31, 38, 27]
            for (index, blob) in layer.blobs.enumerated() {
                let move = CABasicAnimation(keyPath: "transform")
                move.fromValue = CATransform3DIdentity
                var to = CATransform3DMakeTranslation(blob.bounds.width * 0.16, -blob.bounds.height * 0.12, 0)
                to = CATransform3DScale(to, 1.22, 1.22, 1)
                move.toValue = to
                move.duration = durations[index % durations.count]
                move.autoreverses = true
                move.repeatCount = .infinity
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if index == 1 { move.timeOffset = move.duration }
                blob.add(move, forKey: "drift")
            }
        }

        private func setPaused(_ paused: Bool) {
            guard paused != isPaused else { return }
            isPaused = paused
            if paused {
                let time = stage.convertTime(CACurrentMediaTime(), from: nil)
                stage.speed = 0
                stage.timeOffset = time
            } else {
                let pausedTime = stage.timeOffset
                stage.speed = 1
                stage.timeOffset = 0
                stage.beginTime = 0
                stage.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            }
        }

        private static func blurredArtwork(_ url: URL?) async -> CGImage? {
            guard let url, let source = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail) else {
                return nil
            }
            return await Task.detached(priority: .utility) {
                MacArtworkBlur.blur(source)
            }.value
        }
    }
}

enum MacArtworkBlur {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func blur(_ source: CGImage) -> CGImage? {
        let input = CIImage(cgImage: source)
        let side = max(input.extent.width, input.extent.height)
        guard side > 0 else { return nil }
        let scale = 96 / side
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: small.extent)
        return context.createCGImage(blurred, from: small.extent)
    }
}


enum MacWaveLevels {
    static func levels(from samples: [Float], count: Int, floor minimum: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: minimum, count: count) }
        var out = [CGFloat]()
        out.reserveCapacity(count)
        let step = Double(samples.count) / Double(count)
        for index in 0..<count {
            let start = Int(Double(index) * step)
            let end = max(start + 1, min(samples.count, Int(Double(index + 1) * step)))
            var peak: Float = 0
            var sum: Float = 0
            for k in start..<end {
                peak = max(peak, samples[k])
                sum += samples[k]
            }
            let mean = sum / Float(end - start)
            out.append(max(minimum, min(1, CGFloat(peak * 0.55 + mean * 0.45))))
        }
        return out
    }
}

struct MacWaveformScrubber: View {
    let trackID: String?
    let samples: [Float]
    let duration: TimeInterval
    var marks: [Double] = []
    var marksAreDots = false
    @Binding var scrubTime: TimeInterval?

    @State private var width: CGFloat = 0
    @State private var levels: [CGFloat] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 36
    private let pitch: CGFloat = 3.6
    private let barWidth: CGFloat = 2.2

    private struct LevelsKey: Equatable {
        let trackID: String?
        let sampleCount: Int
        let width: Int
    }

    var body: some View {
        MacLayerProgress(
            style: .bars(levels: levels, pitch: pitch, barWidth: barWidth),
            base: .white.opacity(0.26),
            fill: .white.opacity(0.95),
            start: 0,
            end: duration,
            override: scrubTime,
            anchor: MacPlaybackTimeline.shared.anchor
        )
        .frame(height: height)
        .scaleEffect(y: scrubTime == nil || reduceMotion ? 1 : 1.32)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: scrubTime == nil)
        .overlay(alignment: .bottomLeading) { markLayer }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle().inset(by: -10))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: LevelsKey(trackID: trackID, sampleCount: samples.count, width: Int(width))) {
            let count = max(0, Int(width / pitch))
            levels = MacWaveLevels.levels(from: samples, count: count, floor: samples.isEmpty ? 0.06 : 0.1)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubTime = time(atX: value.location.x)
                }
                .onEnded { value in
                    MacPlaybackTimeline.shared.seek(to: time(atX: value.location.x))
                    scrubTime = nil
                }
        )
        .macScrubberAccessibility(duration: duration, scrubTime: scrubTime)
    }

    @ViewBuilder
    private var markLayer: some View {
        if !marks.isEmpty, width > 0 {
            Canvas { context, size in
                for mark in marks {
                    let x = size.width * mark
                    if marksAreDots {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: size.height - 3, width: 3, height: 3)), with: .color(.white.opacity(0.55)))
                    } else {
                        context.fill(Path(CGRect(x: x - 0.5, y: size.height - 5, width: 1, height: 5)), with: .color(.white.opacity(0.5)))
                    }
                }
            }
            .frame(height: 6)
            .offset(y: 11)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func time(atX x: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}

struct MacProgressScrubber: View {
    let duration: TimeInterval
    @Binding var scrubTime: TimeInterval?
    var restingThickness: CGFloat = 3

    @State private var width: CGFloat = 0
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let thickness: CGFloat = isHovering || scrubTime != nil ? restingThickness + 2 : restingThickness
        MacLayerProgress(
            style: .line,
            base: Color(nsColor: .quaternaryLabelColor),
            fill: Color(nsColor: .secondaryLabelColor),
            start: 0,
            end: duration,
            override: scrubTime,
            anchor: MacPlaybackTimeline.shared.anchor
        )
        .frame(height: thickness)
        .frame(height: 9)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: thickness)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in scrubTime = time(atX: value.location.x) }
                .onEnded { value in
                    MacPlaybackTimeline.shared.seek(to: time(atX: value.location.x))
                    scrubTime = nil
                }
        )
        .macScrubberAccessibility(duration: duration, scrubTime: scrubTime)
    }

    private func time(atX x: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}

struct MacLayerProgress: NSViewRepresentable {
    enum Style: Equatable {
        case bars(levels: [CGFloat], pitch: CGFloat, barWidth: CGFloat)
        case line
    }

    var style: Style
    var base: Color
    var fill: Color
    var start: TimeInterval
    var end: TimeInterval
    var override: TimeInterval?
    var anchor: PlaybackAnchor

    func makeNSView(context: Context) -> ProgressLayerView {
        ProgressLayerView()
    }

    func updateNSView(_ view: ProgressLayerView, context: Context) {
        let appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        var baseColor = NSColor(base).cgColor
        var fillColor = NSColor(fill).cgColor
        appearance?.performAsCurrentDrawingAppearance {
            baseColor = NSColor(base).cgColor
            fillColor = NSColor(fill).cgColor
        }
        view.configure(
            style: style,
            baseColor: baseColor,
            fillColor: fillColor,
            progress: ProgressLayerView.Progress(
                start: start,
                end: end,
                override: override,
                anchor: anchor,
                live: context.environment.macPlaybackAnimationsActive
            )
        )
    }

    final class ProgressLayerView: NSView {
        struct Progress: Equatable {
            var start: TimeInterval
            var end: TimeInterval
            var override: TimeInterval?
            var anchor: PlaybackAnchor
            var live: Bool
        }

        private let baseLayer = CAShapeLayer()
        private let fillLayer = CAShapeLayer()
        private let maskLayer = CALayer()
        private var style: Style = .line
        private var progress: Progress?
        private var pathSize: CGSize = .zero

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(baseLayer)
            layer?.addSublayer(fillLayer)
            maskLayer.backgroundColor = NSColor.black.cgColor
            maskLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
            fillLayer.mask = maskLayer
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            baseLayer.frame = bounds
            fillLayer.frame = bounds
            maskLayer.bounds = bounds
            maskLayer.position = CGPoint(x: 0, y: bounds.midY)
            if pathSize != bounds.size { rebuildPath() }
            CATransaction.commit()
        }

        func configure(style: Style, baseColor: CGColor, fillColor: CGColor, progress: Progress) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            baseLayer.fillColor = baseColor
            fillLayer.fillColor = fillColor
            if style != self.style {
                self.style = style
                rebuildPath()
            }
            CATransaction.commit()
            guard progress != self.progress else { return }
            self.progress = progress
            apply(progress)
        }

        private func rebuildPath() {
            pathSize = bounds.size
            let path = CGMutablePath()
            switch style {
            case .line:
                let radius = bounds.height / 2
                path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
            case .bars(let levels, let pitch, let barWidth):
                let radius = barWidth / 2
                for (index, level) in levels.enumerated() {
                    let height = max(barWidth, level * bounds.height)
                    let x = CGFloat(index) * pitch + (pitch - barWidth) / 2
                    let y = (bounds.height - height) / 2
                    path.addRoundedRect(
                        in: CGRect(x: x, y: y, width: barWidth, height: height),
                        cornerWidth: radius,
                        cornerHeight: radius
                    )
                }
            }
            baseLayer.path = path
            fillLayer.path = path
        }

        private func apply(_ progress: Progress) {
            let span = max(0.001, progress.end - progress.start)
            let position = progress.override ?? progress.anchor.position(at: .now)
            let fraction = min(1, max(0, (position - progress.start) / span))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskLayer.removeAnimation(forKey: "progress")
            maskLayer.transform = CATransform3DMakeScale(max(0.0001, fraction), 1, 1)
            CATransaction.commit()
            let rate = progress.anchor.rate
            guard progress.live, progress.override == nil, rate > 0, fraction < 1,
                  position < progress.end else { return }
            let delay = max(0, progress.start - position) / rate
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = max(0.0001, fraction)
            animation.toValue = 1
            animation.duration = (progress.end - max(position, progress.start)) / rate
            animation.beginTime = maskLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            maskLayer.add(animation, forKey: "progress")
        }
    }
}

private struct MacScrubberAccessibility: ViewModifier {
    let duration: TimeInterval
    let scrubTime: TimeInterval?

    func body(content: Content) -> some View {
        let position = scrubTime ?? MacPlaybackTimeline.shared.position()
        content
            .help("Drag to seek")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(macFormatTime(position)) of \(macFormatTime(duration))")
            .accessibilityAdjustableAction { direction in
                let timeline = MacPlaybackTimeline.shared
                let now = timeline.position()
                switch direction {
                case .increment: timeline.seek(to: min(duration, now + 15))
                case .decrement: timeline.seek(to: max(0, now - 15))
                @unknown default: break
                }
            }
    }
}

extension View {
    func macScrubberAccessibility(duration: TimeInterval, scrubTime: TimeInterval?) -> some View {
        modifier(MacScrubberAccessibility(duration: duration, scrubTime: scrubTime))
    }
}
