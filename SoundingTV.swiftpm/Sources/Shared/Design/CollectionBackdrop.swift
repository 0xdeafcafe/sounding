import SwiftUI
import CoreImage
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct CollectionBackdropArt: Sendable {
    let base: CGImage
    let blobs: [CGImage]
    let cells: [CollectionAccent.RGB]
    let scrim: Double
    let strongScrim: Double
}

enum CollectionBackdropRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let side = 64
    private static let blobCrops: [CGRect] = [
        CGRect(x: 0, y: 24, width: 40, height: 40),
        CGRect(x: 24, y: 0, width: 40, height: 40),
        CGRect(x: 12, y: 12, width: 40, height: 40),
    ]

    static func render(_ source: CGImage) -> CollectionBackdropArt? {
        guard let small = downsample(source) else { return nil }
        let input = CIImage(cgImage: small)
        let extent = input.extent
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 6)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.6,
                kCIInputBrightnessKey: -0.03,
                kCIInputContrastKey: 1.05,
            ])
            .cropped(to: extent)
        guard let base = context.createCGImage(blurred, from: extent) else { return nil }
        let blobs = blobCrops.compactMap { blob(from: blurred, crop: $0) }
        let bright = brightCell(of: base) ?? CollectionAccent.RGB(r: 0.5, g: 0.5, b: 0.5)
        return CollectionBackdropArt(
            base: base,
            blobs: blobs,
            cells: grid(of: base, cells: 3) ?? [],
            scrim: max(0.2, legibilityScrim(over: bright, minimumContrast: 4.5)),
            strongScrim: max(0.32, legibilityScrim(over: bright, minimumContrast: 7))
        )
    }

    static func legibilityScrim(over backdrop: CollectionAccent.RGB, textOpacity: Double = 0.6, minimumContrast: Double) -> Double {
        var alpha = 0.0
        while alpha < 0.9 {
            let ground = CollectionAccent.RGB(r: backdrop.r * (1 - alpha), g: backdrop.g * (1 - alpha), b: backdrop.b * (1 - alpha))
            let text = CollectionAccent.RGB(
                r: textOpacity + ground.r * (1 - textOpacity),
                g: textOpacity + ground.g * (1 - textOpacity),
                b: textOpacity + ground.b * (1 - textOpacity)
            )
            if CollectionAccent.contrast(text, ground) >= minimumContrast { return alpha }
            alpha += 0.02
        }
        return alpha
    }

    static func nameScrim(for art: CollectionBackdropArt, strong: Bool) -> Double {
        let floor = strong ? 0.6 : 0.3
        guard art.cells.count == 9,
              let brightest = art.cells[6...8].max(by: { CollectionAccent.luminance($0) < CollectionAccent.luminance($1) }) else { return strong ? 0.92 : 0.78 }
        return max(floor, legibilityScrim(over: brightest, textOpacity: 1, minimumContrast: strong ? 7 : 4.5))
    }

    private static func downsample(_ source: CGImage) -> CGImage? {
        guard source.width > 0, source.height > 0,
              let canvas = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let scale = max(CGFloat(side) / CGFloat(source.width), CGFloat(side) / CGFloat(source.height))
        let width = CGFloat(source.width) * scale
        let height = CGFloat(source.height) * scale
        canvas.interpolationQuality = .medium
        canvas.draw(source, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        return canvas.makeImage()
    }

    private static func blob(from image: CIImage, crop: CGRect) -> CGImage? {
        let piece = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let size = crop.width
        let center = CIVector(x: size / 2, y: size / 2)
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": size * 0.12,
            "inputRadius1": size * 0.5,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let masked = piece.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: gradient.cropped(to: bounds),
        ])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(masked, from: bounds, format: .RGBA8, colorSpace: space)
    }

    private static func grid(of image: CGImage, cells: Int) -> [CollectionAccent.RGB]? {
        var pixels = [UInt8](repeating: 0, count: cells * cells * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let canvas = CGContext(
                data: buffer.baseAddress,
                width: cells,
                height: cells,
                bitsPerComponent: 8,
                bytesPerRow: cells * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            canvas.interpolationQuality = .high
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: cells, height: cells))
            return true
        }
        guard drawn else { return nil }
        return (0..<cells * cells).map { index in
            CollectionAccent.RGB(
                r: Double(pixels[index * 4]) / 255,
                g: Double(pixels[index * 4 + 1]) / 255,
                b: Double(pixels[index * 4 + 2]) / 255
            )
        }
    }

    private static func brightCell(of image: CGImage) -> CollectionAccent.RGB? {
        guard let cells = grid(of: image, cells: 4) else { return nil }
        let sorted = cells.sorted { CollectionAccent.luminance($0) < CollectionAccent.luminance($1) }
        return sorted[(sorted.count * 3) / 4]
    }
}

@MainActor
final class CollectionBackdropStore {
    static let shared = CollectionBackdropStore()

    private var arts: [URL: CollectionBackdropArt] = [:]
    private var order: [URL] = []
    private var flights: [URL: Task<CollectionBackdropArt?, Never>] = [:]
    private let limit = 24

    func cached(_ url: URL?) -> CollectionBackdropArt? {
        guard let url else { return nil }
        return arts[url]
    }

    func art(for url: URL, variant: ArtworkVariant = .thumbnail) async -> CollectionBackdropArt? {
        if let known = arts[url] { return known }
        let task: Task<CollectionBackdropArt?, Never>
        if let running = flights[url] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                guard let image = await SCArtworkStore.shared.cgImage(for: url, variant: variant) else { return nil }
                return CollectionBackdropRenderer.render(image)
            }
            flights[url] = task
        }
        let result = await task.value
        flights[url] = nil
        if let result, arts[url] == nil {
            arts[url] = result
            order.append(url)
            if order.count > limit {
                arts[order.removeFirst()] = nil
            }
        }
        return result
    }

    func purge() {
        arts.removeAll()
        order.removeAll()
    }
}

// MARK: - Drift

@MainActor
final class CollectionDriftScene {
    let root = CALayer()

    private struct BlobSpec {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Float
        let duration: CFTimeInterval
        let turn: CGFloat
        let dx: CGFloat
        let dy: CGFloat
    }

    private static let specs: [BlobSpec] = [
        BlobSpec(x: 0.2, y: 0.25, size: 0.95, opacity: 0.9, duration: 29, turn: 48, dx: 0.14, dy: 0.08),
        BlobSpec(x: 0.82, y: 0.4, size: 0.85, opacity: 0.85, duration: 37, turn: -56, dx: -0.12, dy: 0.1),
        BlobSpec(x: 0.45, y: 0.78, size: 0.8, opacity: 0.8, duration: 23, turn: 40, dx: 0.1, dy: -0.12),
    ]
    private static let frameRate = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
    private static let quiet: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(), "transform": NSNull(), "opacity": NSNull(),
    ]

    private var art: CALayer?
    private var blobs: [CALayer] = []
    private var shown: CGImage?
    private var drifts = false
    private var driftedSize: CGSize = .zero
    private var isPaused = false

    init() {
        root.masksToBounds = true
        root.actions = Self.quiet
    }

    func show(_ image: CollectionBackdropArt, drifts: Bool) {
        if let shown, shown === image.base, drifts == self.drifts { return }
        shown = image.base
        self.drifts = drifts
        root.sublayers?.forEach { $0.removeFromSuperlayer() }

        let base = CALayer()
        base.contents = image.base
        base.contentsGravity = .resizeAspectFill
        base.minificationFilter = .linear
        base.magnificationFilter = .linear
        base.actions = Self.quiet
        root.addSublayer(base)
        art = base

        blobs = zip(image.blobs, Self.specs).map { blobImage, spec in
            let blob = CALayer()
            blob.contents = blobImage
            blob.contentsGravity = .resize
            blob.magnificationFilter = .linear
            blob.opacity = spec.opacity
            blob.actions = Self.quiet
            root.addSublayer(blob)
            return blob
        }
        driftedSize = .zero
        layout(root.bounds)
    }

    func layout(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        let longest = max(bounds.width, bounds.height)
        art?.bounds = CGRect(x: 0, y: 0, width: longest * 1.35, height: longest * 1.35)
        art?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for (blob, spec) in zip(blobs, Self.specs) {
            let side = longest * spec.size
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.position = CGPoint(x: bounds.width * spec.x, y: bounds.height * spec.y)
        }
        CATransaction.commit()
        if drifts, bounds.size != driftedSize {
            addDrift(size: bounds.size)
        }
    }

    func setRunning(_ running: Bool) {
        if running, isPaused {
            let pausedTime = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            isPaused = false
        } else if !running, !isPaused {
            let pausedTime = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = pausedTime
            isPaused = true
        }
    }

    private func addDrift(size: CGSize) {
        driftedSize = size
        let longest = max(size.width, size.height)
        if let art {
            art.add(
                Self.loop(
                    from: Self.transform(dx: -0.03 * longest, dy: -0.02 * longest, degrees: -6, scale: 1.04),
                    to: Self.transform(dx: 0.03 * longest, dy: 0.03 * longest, degrees: 8, scale: 1.16),
                    duration: 41,
                    reverse: false
                ),
                forKey: "drift"
            )
        }
        for (index, (blob, spec)) in zip(blobs, Self.specs).enumerated() {
            let side = longest * spec.size
            blob.add(
                Self.loop(
                    from: CATransform3DIdentity,
                    to: Self.transform(dx: spec.dx * side, dy: spec.dy * side, degrees: spec.turn, scale: 1.18),
                    duration: spec.duration,
                    reverse: index == 1
                ),
                forKey: "drift"
            )
        }
    }

    private static func loop(from: CATransform3D, to: CATransform3D, duration: CFTimeInterval, reverse: Bool) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = frameRate
        if reverse { animation.timeOffset = duration }
        return animation
    }

    private static func transform(dx: CGFloat, dy: CGFloat, degrees: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DRotate(transform, degrees * .pi / 180, 0, 0, 1)
        return CATransform3DScale(transform, scale, scale, 1)
    }
}

#if canImport(UIKit)
final class CollectionDriftHost: UIView {
    let scene = CollectionDriftScene()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(scene.root)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scene.layout(bounds)
    }
}

struct CollectionDriftLayer: UIViewRepresentable {
    let art: CollectionBackdropArt
    let drifts: Bool
    let isRunning: Bool

    func makeUIView(context: Context) -> CollectionDriftHost {
        CollectionDriftHost()
    }

    func updateUIView(_ view: CollectionDriftHost, context: Context) {
        view.scene.show(art, drifts: drifts)
        view.scene.setRunning(isRunning && drifts)
    }
}
#else
final class CollectionDriftHost: NSView {
    let scene = CollectionDriftScene()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(scene.root)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        scene.layout(bounds)
    }
}

struct CollectionDriftLayer: NSViewRepresentable {
    let art: CollectionBackdropArt
    let drifts: Bool
    let isRunning: Bool

    func makeNSView(context: Context) -> CollectionDriftHost {
        CollectionDriftHost()
    }

    func updateNSView(_ view: CollectionDriftHost, context: Context) {
        view.scene.show(art, drifts: drifts)
        view.scene.setRunning(isRunning && drifts)
    }
}
#endif

// MARK: - Backdrop

struct CollectionArtworkBackdrop: View {
    let url: URL?
    var identity: String? = nil
    var isActive = true
    var fade: CGFloat = 96
    var variant: ArtworkVariant = .thumbnail

    @State private var loaded: CollectionBackdropArt?
    @State private var loadedURL: URL?
    @Environment(\.collectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase

    private var art: CollectionBackdropArt? {
        if loadedURL == url, let loaded { return loaded }
        return CollectionBackdropStore.shared.cached(url)
    }

    var body: some View {
        let art = self.art
        ZStack {
            accent?.wash(for: .dark) ?? Color(white: 0.16)
            if let art, !reduceTransparency {
                CollectionDriftLayer(art: art, drifts: !reduceMotion, isRunning: isActive && scenePhase == .active)
                    .transition(.opacity)
            }
            if let identity, !reduceTransparency {
                CollectionBackdropLineArt(identity: identity)
            }
            Color.black.opacity(scrim(for: art))
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .black.opacity(0), location: 0.35),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeOut(duration: 0.45), value: art == nil)
        .modifier(CollectionBackdropFade(length: fade))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                loaded = nil
                loadedURL = nil
                return
            }
            let result = await CollectionBackdropStore.shared.art(for: url, variant: variant)
            guard !Task.isCancelled else { return }
            loaded = result
            loadedURL = url
        }
    }

    private func scrim(for art: CollectionBackdropArt?) -> Double {
        guard let art, !reduceTransparency else { return 0.28 }
        return contrast == .increased ? art.strongScrim : art.scrim
    }
}

struct CollectionBackdropLineArt: View {
    let identity: String

    var body: some View {
        let seed = GeneratedArtworkIdentity.seed(identity)
        let palette = SoundingArtPalette.resolve(.dark)
        let moment = SoundingLineArtMoment(time: SoundingLineArtComposition.introDuration(for: .ambient), idle: 0, drifts: false)
        Canvas { context, size in
            let composition = SoundingLineArtComposition(seed: seed, size: size, style: .ambient)
            composition.draw(in: &context, moment: moment, palette: palette, layer: .inks)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


// MARK: - Page tone

struct CollectionPageTone: Equatable {
    let scheme: ColorScheme
    let base: CollectionAccent.RGB
    let cells: [CollectionAccent.RGB]

    init?(art: CollectionBackdropArt, allowsLight: Bool = true, strong: Bool = false) {
        guard art.cells.count == 9 else { return nil }
        let vivid = Self.vivid(art.cells)
        let bottom = Self.ground(Array(vivid[6...8]))
        let dark = Self.fit(bottom, light: false, strong: strong)
        let light = Self.fit(bottom, light: true, strong: strong)
        let useLight = allowsLight && light.change + 0.08 < dark.change
        scheme = useLight ? .light : .dark
        base = useLight ? light.color : dark.color
        cells = vivid.enumerated().map { index, cell in
            let fitted = Self.fit(cell, light: useLight, strong: strong).color
            guard Self.recessed.contains(index) else { return fitted }
            return useLight ? Self.whitened(fitted, by: 0.35) : Self.scaled(fitted, by: 0.78)
        }
    }

    private static let recessed: Set<Int> = [2, 6]

    static func vivid(_ cells: [CollectionAccent.RGB]) -> [CollectionAccent.RGB] {
        let shades = cells.map(CollectionAccent.hsb)
        let chromatic = shades.indices.filter { shades[$0].s >= 0.2 && shades[$0].v >= 0.15 }
        guard let anchor = chromatic.max(by: { vividness(shades[$0]) < vividness(shades[$1]) }) else { return cells }
        return cells.indices.map { index in
            guard chromatic.contains(index) else { return mix(cells[index], cells[anchor], by: 0.55) }
            var shade = shades[index]
            shade.s = min(1, max(shade.s * 1.2, 0.45))
            return CollectionAccent.rgb(shade)
        }
    }

    private static func vividness(_ shade: CollectionAccent.HSB) -> Double {
        shade.s * shade.s * shade.v
    }

    private static func ground(_ cells: [CollectionAccent.RGB]) -> CollectionAccent.RGB {
        let weights = cells.map { 0.05 + vividness(CollectionAccent.hsb($0)) }
        let total = max(weights.reduce(0.0, +), 0.0001)
        return CollectionAccent.RGB(
            r: zip(cells, weights).reduce(0.0) { $0 + $1.0.r * $1.1 } / total,
            g: zip(cells, weights).reduce(0.0) { $0 + $1.0.g * $1.1 } / total,
            b: zip(cells, weights).reduce(0.0) { $0 + $1.0.b * $1.1 } / total
        )
    }

    private static func mix(_ a: CollectionAccent.RGB, _ b: CollectionAccent.RGB, by amount: Double) -> CollectionAccent.RGB {
        CollectionAccent.RGB(
            r: a.r + (b.r - a.r) * amount,
            g: a.g + (b.g - a.g) * amount,
            b: a.b + (b.b - a.b) * amount
        )
    }

    var baseColor: Color { CollectionAccent.color(base) }
    var colors: [Color] { cells.map(CollectionAccent.color) }

    static func fit(_ color: CollectionAccent.RGB, light: Bool, strong: Bool) -> (color: CollectionAccent.RGB, change: Double) {
        let target = strong ? 7.0 : 4.5
        if !light {
            let alpha = CollectionBackdropRenderer.legibilityScrim(over: color, minimumContrast: target)
            return (scaled(color, by: 1 - alpha), alpha)
        }
        var alpha = 0.0
        while alpha < 0.95 {
            let ground = whitened(color, by: alpha)
            if CollectionAccent.contrast(scaled(ground, by: 0.4), ground) >= target { return (ground, alpha) }
            alpha += 0.02
        }
        return (whitened(color, by: alpha), alpha)
    }

    private static func scaled(_ color: CollectionAccent.RGB, by factor: Double) -> CollectionAccent.RGB {
        CollectionAccent.RGB(r: color.r * factor, g: color.g * factor, b: color.b * factor)
    }

    private static func whitened(_ color: CollectionAccent.RGB, by amount: Double) -> CollectionAccent.RGB {
        CollectionAccent.RGB(
            r: color.r + (1 - color.r) * amount,
            g: color.g + (1 - color.g) * amount,
            b: color.b + (1 - color.b) * amount
        )
    }
}

enum CollectionMeshPalette {

    static func tone(_ cell: CollectionAccent.RGB, scheme: ColorScheme, strong: Bool, lift: Double = 0) -> CollectionAccent.RGB {
        var shade = CollectionAccent.hsb(cell)
        let neutral = shade.s < 0.12
        if scheme == .dark {
            shade.s = neutral ? shade.s * 0.5 : min(max(shade.s, 0.4), 0.85)
            shade.v = min(max(shade.v * 0.42 + lift, 0.12), strong ? 0.2 : 0.3)
            let ceiling = strong ? 0.025 : 0.05
            var out = CollectionAccent.rgb(shade)
            var steps = 0
            while CollectionAccent.luminance(out) > ceiling, steps < 30 {
                shade.v *= 0.93
                out = CollectionAccent.rgb(shade)
                steps += 1
            }
            return out
        } else {
            shade.s = neutral ? shade.s * 0.4 : min(max(shade.s * 0.45, 0.1), strong ? 0.12 : 0.26)
            shade.v = min(1, 0.95 + shade.v * 0.05 - lift * 0.3)
            let floor = strong ? 0.9 : 0.82
            var out = CollectionAccent.rgb(shade)
            var steps = 0
            while CollectionAccent.luminance(out) < floor, steps < 30 {
                shade.s *= 0.88
                shade.v = min(1, shade.v + 0.01)
                out = CollectionAccent.rgb(shade)
                steps += 1
            }
            return out
        }
    }
    static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let a = Float(sin(time * 2 * .pi / 31))
        let b = Float(cos(time * 2 * .pi / 37))
        let c = Float(sin(time * 2 * .pi / 23))
        return [
            [0, 0], [0.5 + 0.1 * a, 0], [1, 0],
            [0, 0.5 + 0.1 * b], [0.5 + 0.12 * c, 0.5 + 0.1 * a], [1, 0.5 - 0.1 * c],
            [0, 1], [0.5 - 0.1 * b, 1], [1, 1],
        ]
    }
}

struct CollectionToneMesh: View {
    let tone: CollectionPageTone?

    #if os(tvOS)
    private static let frameInterval: TimeInterval = 1.0 / 10
    #else
    private static let frameInterval: TimeInterval = 1.0 / 15
    #endif

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.clear
            if let tone {
                tone.baseColor
                    .transition(.opacity)
                if reduceMotion {
                    MeshGradient(width: 3, height: 3, points: CollectionMeshPalette.points(at: 0), colors: tone.colors)
                        .transition(.opacity)
                } else {
                    TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isVisible || scenePhase != .active)) { context in
                        MeshGradient(
                            width: 3,
                            height: 3,
                            points: CollectionMeshPalette.points(at: context.date.timeIntervalSinceReferenceDate),
                            colors: tone.colors
                        )
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.6), value: tone)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

struct CollectionPageMesh: View {
    let url: URL?
    var allowsLight = false
    var variant: ArtworkVariant = .thumbnail

    @State private var loaded: CollectionBackdropArt?
    @State private var loadedURL: URL?
    @Environment(\.colorSchemeContrast) private var contrast

    private var art: CollectionBackdropArt? {
        if loadedURL == url, let loaded { return loaded }
        return CollectionBackdropStore.shared.cached(url)
    }

    var body: some View {
        CollectionToneMesh(tone: art.flatMap { CollectionPageTone(art: $0, allowsLight: allowsLight, strong: contrast == .increased) })
            .task(id: url) {
                guard let url else {
                    loaded = nil
                    loadedURL = nil
                    return
                }
                let result = await CollectionBackdropStore.shared.art(for: url, variant: variant)
                guard !Task.isCancelled else { return }
                loaded = result
                loadedURL = url
            }
    }
}

private struct CollectionPageToneKey: EnvironmentKey {
    static let defaultValue: CollectionPageTone? = nil
}

private struct CollectionTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var collectionPageTone: CollectionPageTone? {
        get { self[CollectionPageToneKey.self] }
        set { self[CollectionPageToneKey.self] = newValue }
    }

    var collectionTopInset: CGFloat {
        get { self[CollectionTopInsetKey.self] }
        set { self[CollectionTopInsetKey.self] = newValue }
    }
}

private struct CollectionPageModifier: ViewModifier {
    let url: URL?
    var variant: ArtworkVariant = .thumbnail
    var allowsLight = true
    var fallbackScheme: ColorScheme? = nil

    @State private var loaded: CollectionBackdropArt?
    @State private var loadedURL: URL?
    @Environment(\.colorSchemeContrast) private var contrast

    private var art: CollectionBackdropArt? {
        if loadedURL == url, let loaded { return loaded }
        return CollectionBackdropStore.shared.cached(url)
    }

    func body(content: Content) -> some View {
        let tone = art.flatMap { CollectionPageTone(art: $0, allowsLight: allowsLight, strong: contrast == .increased) }
        content
            .environment(\.collectionPageTone, tone)
            .modifier(CollectionPageToolbarScheme(scheme: tone?.scheme ?? fallbackScheme))
            .background { CollectionToneMesh(tone: tone) }
            .task(id: url) {
                guard let url else {
                    loaded = nil
                    loadedURL = nil
                    return
                }
                let result = await CollectionBackdropStore.shared.art(for: url, variant: variant)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.5)) {
                    loaded = result
                    loadedURL = url
                }
            }
    }
}

private struct CollectionPageToolbarScheme: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbarColorScheme(scheme, for: .navigationBar)
        #elseif os(macOS)
        content.toolbarColorScheme(scheme, for: .windowToolbar)
        #else
        content
        #endif
    }
}

private struct CollectionPageSchemeModifier: ViewModifier {
    @Environment(\.collectionPageTone) private var tone
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, tone?.scheme ?? colorScheme)
    }
}

private struct CollectionHeroProgressReader: ViewModifier {
    @Binding var progress: Double
    let distance: CGFloat

    @Environment(\.collectionTopInset) private var topInset

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Double.self) { [topInset, distance] proxy in
            let maxY = proxy.frame(in: .scrollView).maxY
            let raw = Double((topInset + distance - maxY) / distance)
            return (min(max(raw, 0), 1) * 10).rounded() / 10
        } action: { value in
            withAnimation(.smooth(duration: 0.25)) { progress = value }
        }
    }
}

struct CollectionFullBleedArtwork: View {
    let url: URL?
    let identity: String
    var isHosted = false

    @Environment(\.collectionPageTone) private var tone
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SCArtworkResolver(url: url, variant: .hero) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity, subject: .collection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay { fade }
        .modifier(CollectionFullBleedInlineEffects(isEnabled: !isHosted))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fade: some View {
        let ground = tone?.baseColor ?? (colorScheme == .dark ? Color.black : Color.white)
        let bar: Color = (tone?.scheme ?? colorScheme) == .dark ? .black : .white
        return LinearGradient(
            stops: [
                .init(color: bar.opacity(0.3), location: 0),
                .init(color: bar.opacity(0), location: 0.22),
                .init(color: ground.opacity(0), location: 0.42),
                .init(color: ground.opacity(reduceTransparency ? 1 : 0.72), location: 0.74),
                .init(color: ground, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct CollectionFullBleedInlineEffects: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .modifier(CollectionBackdropExtension())
                .visualEffect { effect, proxy in
                    let stretch = max(0, proxy.frame(in: .scrollView).minY)
                    return effect.scaleEffect(1 + stretch / max(proxy.size.height, 1), anchor: .bottom)
                }
        } else {
            content
        }
    }
}

private struct CollectionBackdropFade: ViewModifier {
    let length: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.86), location: 0.2),
                        .init(color: .black.opacity(0.62), location: 0.4),
                        .init(color: .black.opacity(0.36), location: 0.6),
                        .init(color: .black.opacity(0.13), location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: length)
            }
        }
    }
}

// MARK: - Hero modifier

private struct CollectionOverscrollKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct CollectionHeroOnArtworkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var collectionOverscroll: CGFloat {
        get { self[CollectionOverscrollKey.self] }
        set { self[CollectionOverscrollKey.self] = newValue }
    }

    var collectionHeroOnArtwork: Bool {
        get { self[CollectionHeroOnArtworkKey.self] }
        set { self[CollectionHeroOnArtworkKey.self] = newValue }
    }
}

private struct CollectionOverscrollReader: ViewModifier {
    @State private var overscroll: CGFloat = 0
    @State private var topInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.collectionOverscroll, overscroll)
            .environment(\.collectionTopInset, topInset)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top)).rounded()
            } action: { _, value in
                overscroll = value
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentInsets.top.rounded()
            } action: { _, value in
                topInset = value
            }
    }
}

private struct CollectionArtworkBackdropModifier: ViewModifier {
    let url: URL?
    let identity: String?
    let headroom: CGFloat
    let fade: CGFloat
    let padsFade: Bool

    @Environment(\.collectionOverscroll) private var overscroll
    @Environment(\.collectionScrollBackdrop) private var host
    @State private var isOnScreen = true

    func body(content: Content) -> some View {
        if let host {
            content
                .environment(\.colorScheme, .dark)
                .environment(\.collectionHeroOnArtwork, true)
                .padding(.bottom, padsFade ? fade : 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height.rounded()
                } action: { height in
                    if host.heroHeight != height { host.heroHeight = height }
                }
        } else {
            inline(content)
        }
    }

    private func inline(_ content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .environment(\.collectionHeroOnArtwork, true)
            .padding(.bottom, padsFade ? fade : 0)
            .background(alignment: .bottom) {
                CollectionArtworkBackdrop(url: url, identity: identity, isActive: isOnScreen, fade: fade)
                    .padding(.top, -headroom)
                    .visualEffect { [overscroll] effect, proxy in
                        effect.scaleEffect(1 + overscroll / max(proxy.size.height, 1), anchor: .bottom)
                    }
                    .modifier(CollectionBackdropExtension())
            }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .global).maxY > 0
            } action: { isOnScreen = $0 }
    }
}

private struct CollectionBackdropExtension: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.backgroundExtensionEffect()
        #endif
    }
}

// MARK: - Scroll backdrop

@MainActor
@Observable
final class CollectionScrollBackdropState {
    var heroHeight: CGFloat = 0
    var lead: CGFloat = 0
    var topInset: CGFloat = 0
    var offset: CGFloat = 0

    var height: CGFloat { topInset + lead + heroHeight }
}

extension EnvironmentValues {
    @Entry var collectionScrollBackdrop: CollectionScrollBackdropState? = nil
}

enum CollectionScrollBackdropStyle: Equatable {
    case artwork(fade: CGFloat)
    case fullBleed
    case person(PersonHeroContent, blursBanner: Bool)
}

private struct CollectionScrollPosition: Equatable {
    var inset: CGFloat
    var offset: CGFloat
}

private struct CollectionScrollBackdropModifier: ViewModifier {
    let url: URL?
    let identity: String?
    let style: CollectionScrollBackdropStyle
    var isPresent = true

    @State private var state = CollectionScrollBackdropState()

    func body(content: Content) -> some View {
        content
            .environment(\.collectionScrollBackdrop, state)
            .background(alignment: .top) {
                CollectionScrollBackdropLayer(state: state, url: url, identity: identity, style: style, isPresent: isPresent)
            }
            .onScrollGeometryChange(for: CollectionScrollPosition.self) { geometry in
                CollectionScrollPosition(
                    inset: geometry.contentInsets.top.rounded(),
                    offset: (geometry.contentOffset.y + geometry.contentInsets.top).rounded()
                )
            } action: { _, position in
                if state.topInset != position.inset { state.topInset = position.inset }
                let offset = min(position.offset, state.height + 1)
                if state.offset != offset { state.offset = offset }
            }
            .onChange(of: isPresent) { _, present in
                if !present, state.heroHeight != 0 { state.heroHeight = 0 }
            }
    }
}

private struct CollectionScrollBackdropLayer: View {
    let state: CollectionScrollBackdropState
    let url: URL?
    let identity: String?
    let style: CollectionScrollBackdropStyle
    let isPresent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = state.height
        let offset = state.offset
        let isOnScreen = isPresent && state.heroHeight > 0 && offset < height
        artwork(isOnScreen: isOnScreen)
            .frame(maxWidth: .infinity)
            .frame(height: max(height, 1))
            .modifier(CollectionBackdropExtension())
            .scaleEffect(offset < 0 ? 1 - offset / max(height, 1) : 1, anchor: .top)
            .offset(y: -max(0, offset))
            .opacity(isOnScreen ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45), value: isPresent && state.heroHeight > 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artwork(isOnScreen: Bool) -> some View {
        switch style {
        case .fullBleed:
            CollectionFullBleedArtwork(url: url, identity: identity ?? "", isHosted: true)
                .nowPlayingZoomSource(id: NowPlayingReveal.collectionSourceID(identity ?? ""))
        case .artwork(let fade):
            CollectionArtworkBackdrop(url: url, identity: identity, isActive: isOnScreen, fade: fade)
                .collectionAccent(from: url)
        case .person(let content, let blursBanner):
            PersonHeroBackdrop(content: content, blursBanner: blursBanner, isActive: isOnScreen)
        }
    }
}

private struct CollectionScrollBackdropHeroReader: ViewModifier {
    let isLead: Bool

    @Environment(\.collectionScrollBackdrop) private var host

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height.rounded()
        } action: { height in
            guard let host else { return }
            if isLead {
                if host.lead != height { host.lead = height }
            } else if host.heroHeight != height {
                host.heroHeight = height
            }
        }
    }
}

extension View {
    func collectionScrollBackdrop(url: URL?, identity: String?, fade: CGFloat, isPresent: Bool = true) -> some View {
        modifier(CollectionScrollBackdropModifier(url: url, identity: identity, style: .artwork(fade: fade), isPresent: isPresent))
    }

    func collectionFullBleedBackdrop(url: URL?, identity: String?) -> some View {
        modifier(CollectionScrollBackdropModifier(url: url, identity: identity, style: .fullBleed))
    }

    func collectionPersonBackdrop(_ content: PersonHeroContent, blursBanner: Bool) -> some View {
        modifier(CollectionScrollBackdropModifier(url: content.backdropURL, identity: content.id, style: .person(content, blursBanner: blursBanner)))
    }

    func collectionScrollBackdropHero() -> some View {
        modifier(CollectionScrollBackdropHeroReader(isLead: false))
    }

    func collectionScrollBackdropLead() -> some View {
        modifier(CollectionScrollBackdropHeroReader(isLead: true))
    }

    func collectionArtworkBackdrop(url: URL?, identity: String?, headroom: CGFloat, fade: CGFloat, padsFade: Bool = true) -> some View {
        modifier(CollectionArtworkBackdropModifier(url: url, identity: identity, headroom: headroom, fade: fade, padsFade: padsFade))
    }

    func tracksCollectionOverscroll() -> some View {
        modifier(CollectionOverscrollReader())
    }

    func collectionPage(artworkURL: URL?) -> some View {
        modifier(CollectionPageModifier(url: artworkURL))
    }

    func collectionPersonPage(_ content: PersonHeroContent) -> some View {
        modifier(CollectionPageModifier(url: content.backdropURL, variant: content.backdropVariant, allowsLight: false, fallbackScheme: .dark))
    }

    func collectionPageMesh(url: URL?, variant: ArtworkVariant = .thumbnail) -> some View {
        background {
            CollectionPageMesh(url: url, variant: variant)
                .ignoresSafeArea()
        }
    }

    func collectionPageScheme() -> some View {
        modifier(CollectionPageSchemeModifier())
    }

    func collectionHeroProgress(_ progress: Binding<Double>, distance: CGFloat = 88) -> some View {
        modifier(CollectionHeroProgressReader(progress: progress, distance: distance))
    }
}
