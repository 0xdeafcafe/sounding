import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@MainActor
@Observable
final class NowPlayingArtworkLoader {
    private(set) var hero: UIImage?
    private(set) var backdrop: UIImage?
    private(set) var brightCell: SCAmbient.RGB?
    private(set) var generation = 0
    private(set) var isResolved = false

    @ObservationIgnored private var requested: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let backdropCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        return cache
    }()
    nonisolated private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    func load(_ urlString: String?) {
        guard urlString != requested else { return }
        requested = urlString
        task?.cancel()
        task = nil

        guard let urlString, let url = URL(string: urlString) else {
            apply(hero: nil, backdrop: nil)
            return
        }

        let key = url.soundCloudArtworkIdentity as NSString
        if let cachedHero = ArtworkCache.shared.cachedImage(for: url, variant: .standard),
           let cachedBackdrop = Self.backdropCache.object(forKey: key) {
            apply(hero: cachedHero, backdrop: cachedBackdrop)
            return
        }

        task = Task { [weak self] in
            let source = await ArtworkCache.shared.image(for: url, variant: .standard)
            guard !Task.isCancelled, let self, self.requested == urlString else { return }
            guard let source else {
                self.apply(hero: nil, backdrop: nil)
                return
            }
            let blurred: UIImage?
            if let cached = Self.backdropCache.object(forKey: key) {
                blurred = cached
            } else {
                blurred = await Task.detached(priority: .userInitiated) { Self.renderBackdrop(from: source) }.value
                if let blurred { Self.backdropCache.setObject(blurred, forKey: key) }
            }
            guard !Task.isCancelled, self.requested == urlString else { return }
            self.apply(hero: source, backdrop: blurred)
        }
    }

    private func apply(hero: UIImage?, backdrop: UIImage?) {
        self.hero = hero
        self.backdrop = backdrop
        self.brightCell = backdrop.flatMap(Self.brightCell(of:))
        tint = Self.tint(from: backdrop.flatMap(Self.vividCell(of:)))
        isResolved = true
        generation += 1
    }

    private(set) var tint = Color(white: 0.86)

    private static func tint(from cell: SCAmbient.RGB?) -> Color {
        guard let cell else { return Color(white: 0.86) }
        let hsb = SCAmbient.hsb(cell)
        guard hsb.saturation > 0.08 else { return Color(white: 0.88) }
        return Color(
            hue: hsb.hue,
            saturation: min(0.5, max(0.28, hsb.saturation * 0.75)),
            brightness: 0.97
        )
    }

    nonisolated private static func vividCell(of image: UIImage) -> SCAmbient.RGB? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 6
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let cells = (0..<side * side).map { index in
            SCAmbient.RGB(
                r: Double(pixels[index * 4]) / 255,
                g: Double(pixels[index * 4 + 1]) / 255,
                b: Double(pixels[index * 4 + 2]) / 255
            )
        }
        return cells.max { lhs, rhs in
            let left = SCAmbient.hsb(lhs)
            let right = SCAmbient.hsb(rhs)
            return left.saturation * (0.4 + left.brightness) < right.saturation * (0.4 + right.brightness)
        }
    }

    nonisolated private static func brightCell(of image: UIImage) -> SCAmbient.RGB? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let cells = (0..<side * side).map { index in
            SCAmbient.RGB(
                r: Double(pixels[index * 4]) / 255,
                g: Double(pixels[index * 4 + 1]) / 255,
                b: Double(pixels[index * 4 + 2]) / 255
            )
        }
        .sorted { SCAmbient.relativeLuminance($0) < SCAmbient.relativeLuminance($1) }
        return cells[(cells.count * 3) / 4]
    }

    nonisolated private static func renderBackdrop(from source: UIImage) -> UIImage? {
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let size = source.size
            let scale = max(side / max(size.width, 1), side / max(size.height, 1))
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            source.draw(in: CGRect(
                x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
        }
        guard let input = CIImage(image: small) else { return nil }
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.45,
                kCIInputBrightnessKey: -0.02,
                kCIInputContrastKey: 1.04,
            ])
            .cropped(to: input.extent)
        guard let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct NowPlayingBackdropView: View {
    let loader: NowPlayingArtworkLoader
    let identity: String
    var hasArtwork = true
    var isActive = true

    @ObservedObject private var palette = NowPlayingPalette.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase

    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    private var meshColors: [Color] {
        if loader.backdrop == nil {
            return Array(repeating: Color.scAmbientFallback, count: 9)
        }
        let samples = palette.current.colors
        guard samples.count == 9 else { return Array(repeating: Color.scAmbientFallback, count: 9) }
        return [
            samples[6], samples[7], samples[8],
            samples[3], samples[4], samples[5],
            samples[0], samples[1], samples[2],
        ]
    }

    private var imageScrim: Double {
        guard let cell = loader.brightCell, !reduceTransparency else { return 0.14 }
        let required = SCAmbient.legibilityScrim(
            over: cell,
            minimumContrast: contrast == .increased ? 7 : 4.5
        )
        return max(0.14, required)
    }

    private var blobColors: [UIColor] {
        let accent = UIColor(palette.current.accent)
        let samples = palette.current.colors
        let second = samples.count == 9 ? UIColor(samples[2]) : accent
        let third = samples.count == 9 ? UIColor(samples[6]) : accent
        return [accent, second.lifted(by: 0.12), third.lifted(by: 0.08)]
    }

    var body: some View {
        ZStack {
            Color.scAmbientFallback
            MeshGradient(width: 3, height: 3, points: Self.points, colors: meshColors)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: meshColors)
            if let image = loader.backdrop, !reduceTransparency {
                NowPlayingDriftLayer(
                    image: image,
                    generation: loader.generation,
                    blobs: blobColors,
                    drifts: !reduceMotion,
                    isRunning: isActive && scenePhase == .active
                )
            }
            Color.black.opacity(imageScrim)
            LinearGradient(
                stops: [.init(color: .black.opacity(0.08), location: 0), .init(color: .black.opacity(0.26), location: 0.35), .init(color: .black.opacity(0.6), location: 0.68), .init(color: .black.opacity(0.66), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            if loader.backdrop == nil, !hasArtwork || loader.isResolved {
                SoundingLineArt(seed: GeneratedArtworkIdentity.seed(identity), style: .ambient, loop: .once, isActive: isActive && scenePhase == .active)
                    .environment(\.colorScheme, .dark)
                    .id(identity)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct NowPlayingLineArtLayer: View {
    let timeline: NowPlayingTimeline
    @ObservedObject var store: PhoneWaveformStore
    let loader: NowPlayingArtworkLoader
    let trackId: String?
    let hasArtwork: Bool
    var usesColumns = false

    private var showsArtworkFallback: Bool {
        loader.backdrop == nil && (!hasArtwork || loader.isResolved)
    }

    var body: some View {
        let anchor = timeline.anchor
        SoundingReactiveLineArt(
            trackID: trackId,
            samples: store.waveform.samples ?? [],
            duration: anchor.duration,
            playhead: SoundingLineArtPlayhead(position: anchor.position, date: anchor.date, rate: anchor.rate, duration: anchor.duration),
            scrub: timeline.scrubPreview,
            tint: loader.tint,
            intensity: 0.42,
            tipAnchor: usesColumns ? UnitPoint(x: 0.1, y: 0.97) : UnitPoint(x: 0.2, y: 0.72),
            wideTipAnchor: usesColumns ? UnitPoint(x: 0.05, y: 0.99) : UnitPoint(x: 0.36, y: 0.96),
            isActive: !showsArtworkFallback
        )
        .opacity(showsArtworkFallback ? 0 : 1)
        .animation(.easeInOut(duration: 0.6), value: showsArtworkFallback)
        .ignoresSafeArea()
    }
}

private extension UIColor {
    func lifted(by amount: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        return UIColor(hue: hue, saturation: min(1, saturation * 1.2), brightness: min(1, brightness + amount), alpha: 1)
    }
}

private struct NowPlayingDriftLayer: UIViewRepresentable {
    let image: UIImage
    let generation: Int
    let blobs: [UIColor]
    let drifts: Bool
    let isRunning: Bool

    func makeUIView(context: Context) -> NowPlayingDriftView {
        let view = NowPlayingDriftView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: NowPlayingDriftView, context: Context) {
        view.show(image: image, generation: generation, blobs: blobs, drifts: drifts)
        view.setRunning(isRunning)
    }
}

final class NowPlayingDriftView: UIView {
    private struct Scene {
        let container: CALayer
        let art: CALayer
        let blobs: [CAGradientLayer]
    }

    private struct BlobSpec {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Float
        let duration: CFTimeInterval
        let reverse: Bool
    }

    private var scene: Scene?
    private var shownGeneration = -1
    private var drifts = true
    private var driftedSize: CGSize = .zero
    private var isPaused = false
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
    private static let blobSpecs: [BlobSpec] = [
        BlobSpec(x: -0.35, y: -0.20, size: 0.95, opacity: 0.42, duration: 31, reverse: false),
        BlobSpec(x: 0.45, y: 0.55, size: 0.95, opacity: 0.26, duration: 38, reverse: true),
        BlobSpec(x: 0.10, y: 0.35, size: 0.70, opacity: 0.40, duration: 27, reverse: false),
    ]

    func show(image: UIImage, generation: Int, blobs: [UIColor], drifts: Bool) {
        if scene != nil, generation == shownGeneration, drifts == self.drifts {
            updateBlobColors(blobs)
            return
        }
        let animated = scene != nil && generation != shownGeneration
        shownGeneration = generation
        self.drifts = drifts
        let next = makeScene(image: image, blobs: blobs)
        layer.addSublayer(next.container)
        layout(next)
        if drifts, bounds.width > 0 {
            addDrift(to: next)
        }
        if animated, let previous = scene {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 1.1
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            next.container.add(fade, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                previous.container.removeFromSuperlayer()
            }
        } else {
            scene?.container.removeFromSuperlayer()
        }
        scene = next
    }

    func setRunning(_ running: Bool) {
        if running, isPaused {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            isPaused = false
        } else if !running, !isPaused {
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
            isPaused = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let scene else { return }
        layout(scene)
        if drifts, bounds.size != driftedSize {
            addDrift(to: scene)
        }
    }

    private func makeScene(image: UIImage, blobs: [UIColor]) -> Scene {
        let container = CALayer()
        let art = CALayer()
        art.contents = image.cgImage
        art.contentsGravity = .resizeAspectFill
        art.minificationFilter = .linear
        art.magnificationFilter = .linear
        container.addSublayer(art)
        var gradients: [CAGradientLayer] = []
        for (index, spec) in Self.blobSpecs.enumerated() {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.opacity = spec.opacity
            let color = blobs.indices.contains(index) ? blobs[index] : .white
            blob.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            container.addSublayer(blob)
            gradients.append(blob)
        }
        let disabled: [String: any CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "colors": NSNull(), "contents": NSNull(),
        ]
        container.actions = disabled
        art.actions = disabled
        for blob in gradients { blob.actions = disabled }
        return Scene(container: container, art: art, blobs: gradients)
    }

    private func updateBlobColors(_ colors: [UIColor]) {
        guard let scene else { return }
        for (index, blob) in scene.blobs.enumerated() where colors.indices.contains(index) {
            blob.colors = [colors[index].cgColor, colors[index].withAlphaComponent(0).cgColor]
        }
    }

    private func layout(_ scene: Scene) {
        let bounds = self.bounds
        guard bounds.width > 0 else { return }
        scene.container.frame = bounds
        let artSide = max(bounds.width, bounds.height) * 1.6
        scene.art.bounds = CGRect(x: 0, y: 0, width: artSide, height: artSide)
        scene.art.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for (index, blob) in scene.blobs.enumerated() {
            let spec = Self.blobSpecs[index]
            let side = bounds.width * spec.size
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.position = CGPoint(x: bounds.width * spec.x + side / 2, y: bounds.height * spec.y + side / 2)
        }
    }

    private func addDrift(to scene: Scene) {
        driftedSize = bounds.size
        let side = max(bounds.width, bounds.height) * 1.6
        let art = CABasicAnimation(keyPath: "transform")
        art.fromValue = Self.transform(dx: -0.03 * side, dy: -0.02 * side, degrees: -4, scale: 1.02)
        art.toValue = Self.transform(dx: 0.03 * side, dy: 0.03 * side, degrees: 6, scale: 1.14)
        configure(art, duration: 44, reverse: false)
        scene.art.add(art, forKey: "drift")
        for (index, blob) in scene.blobs.enumerated() {
            let spec = Self.blobSpecs[index]
            let blobSide = bounds.width * spec.size
            let drift = CABasicAnimation(keyPath: "transform")
            drift.fromValue = CATransform3DIdentity
            drift.toValue = Self.transform(dx: 0.16 * blobSide, dy: 0.12 * blobSide, degrees: 0, scale: 1.22)
            configure(drift, duration: spec.duration, reverse: spec.reverse)
            blob.add(drift, forKey: "drift")
        }
    }

    private func configure(_ animation: CABasicAnimation, duration: CFTimeInterval, reverse: Bool) {
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = Self.frameRate
        if reverse { animation.timeOffset = duration }
    }

    private static func transform(dx: CGFloat, dy: CGFloat, degrees: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DRotate(transform, degrees * .pi / 180, 0, 0, 1)
        return CATransform3DScale(transform, scale, scale, 1)
    }
}

struct NowPlayingArtworkTile: View {
    let urlString: String?
    let identity: String
    let size: CGFloat
    var isCurrent = true
    var cornerRadius: CGFloat = 14
    var isRaised = true

    @State private var image: UIImage?
    @State private var loadedFor: String?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var displayed: UIImage? {
        if loadedFor == urlString, let image { return image }
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return ArtworkCache.shared.bestCachedImage(for: url, variant: .standard) ?? image
    }

    var body: some View {
        ZStack {
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFill()
            } else {
                SoundingArtworkView(identity: identity, colorScheme: .dark)
                    .environment(\.soundingArtworkPending, urlString != nil && loadedFor != urlString)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(isRaised ? 0.42 : 0.3), radius: isRaised ? 26 : 12, y: isRaised ? 22 : 8)
        .accessibilityHidden(true)
        .task(id: urlString) {
            guard let urlString, let url = URL(string: urlString) else {
                image = nil
                loadedFor = nil
                return
            }
            if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .standard) {
                image = cached
                loadedFor = urlString
                return
            }
            let loaded = await ArtworkCache.shared.image(for: url, variant: .standard)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedFor = urlString
        }
    }
}
