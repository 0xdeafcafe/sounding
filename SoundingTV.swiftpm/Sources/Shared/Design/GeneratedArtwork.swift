import SwiftUI
import CoreGraphics

enum GeneratedArtworkIdentity {
    static func hash(_ string: String) -> UInt64 {
        let normalized = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var h: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }

    static func unit(_ string: String, salt: UInt64 = 0) -> Double {
        let h = hash(string) &+ salt
        return Double(h % 1_000_000) / 1_000_000
    }

    static func hue(for string: String) -> Double {
        unit(string, salt: 0x9E3779B97F4A7C15)
    }
}

struct GeneratedGradient: Equatable {
    let identity: String
    private let baseHue: Double

    init(identity: String) {
        self.identity = identity
        self.baseHue = GeneratedArtworkIdentity.hue(for: identity)
    }

    private static let saturationRange = 0.58...0.82
    private static let brightnessRange = 0.32...0.56

    private func stop(hueOffset: Double, satBias: Double, briBias: Double) -> Color {
        let hue = (baseHue + hueOffset).truncatingRemainder(dividingBy: 1)
        let normalizedHue = hue < 0 ? hue + 1 : hue
        let sat = Self.saturationRange.lowerBound
            + (Self.saturationRange.upperBound - Self.saturationRange.lowerBound) * satBias
        let bri = Self.brightnessRange.lowerBound
            + (Self.brightnessRange.upperBound - Self.brightnessRange.lowerBound) * briBias
        return Color(hue: normalizedHue, saturation: sat, brightness: bri)
    }

    var meshColors: [Color] {
        [
            stop(hueOffset: -0.035, satBias: 0.85, briBias: 0.35),
            stop(hueOffset: -0.010, satBias: 0.60, briBias: 0.70),
            stop(hueOffset:  0.020, satBias: 0.90, briBias: 0.55),
            stop(hueOffset: -0.020, satBias: 0.40, briBias: 0.50),
            stop(hueOffset:  0.000, satBias: 0.70, briBias: 1.00),
            stop(hueOffset:  0.030, satBias: 0.55, briBias: 0.65),
            stop(hueOffset: -0.005, satBias: 0.95, briBias: 0.30),
            stop(hueOffset:  0.015, satBias: 0.65, briBias: 0.60),
            stop(hueOffset:  0.040, satBias: 0.80, briBias: 0.40),
        ]
    }

    var duotoneTint: Color {
        stop(hueOffset: 0, satBias: 0.85, briBias: 0.55)
    }

    func mesh(drift: Double = 0) -> MeshGradient {
        let d = Float(drift)
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0.0, 0.0),          SIMD2<Float>(0.5 + d, 0.0),       SIMD2<Float>(1.0, 0.0),
                SIMD2<Float>(0.0, 0.5 - d),      SIMD2<Float>(0.5, 0.5 + d),       SIMD2<Float>(1.0, 0.5),
                SIMD2<Float>(0.0, 1.0),          SIMD2<Float>(0.5 - d, 1.0),       SIMD2<Float>(1.0, 1.0),
            ],
            colors: meshColors
        )
    }
}

enum GeneratedArtworkGlyph: String, CaseIterable, Sendable {
    case diamond = "diamond"
    case waveform = "waveform"
    case flame = "flame"
    case headphones = "headphones"
    case guitars = "guitars"
    case pianokeys = "pianokeys"
    case radio = "dot.radiowaves.left.and.right"
    case micro = "music.mic"
    case speaker = "hifispeaker"
    case sparkles = "sparkles"
    case heart = "heart"
    case moonStars = "moon.stars"
    case bolt = "bolt"
    case globe = "globe"
    case metronome = "metronome"
    case chartBar = "chart.bar"
    case leaf = "leaf"
    case sunMax = "sun.max"
    case snow = "snowflake"
    case car = "car"
    case figureRun = "figure.run"
    case bed = "bed.double"
    case tram = "tram"
    case theatermasks = "theatermasks"

    var systemImage: String { rawValue }

    private static let keywordMap: [(keyword: String, glyph: GeneratedArtworkGlyph)] = [
        ("hip-hop", .micro), ("hip hop", .micro), ("rap", .micro),
        ("r&b", .micro), ("soul", .micro),
        ("electronic", .waveform), ("edm", .waveform), ("house", .waveform),
        ("techno", .waveform), ("trance", .waveform), ("dubstep", .bolt),
        ("drum and bass", .bolt), ("dnb", .bolt), ("bass", .bolt),
        ("rock", .guitars), ("metal", .guitars), ("punk", .guitars),
        ("indie", .guitars), ("alternative", .guitars),
        ("classical", .pianokeys), ("jazz", .pianokeys), ("piano", .pianokeys),
        ("acoustic", .guitars), ("folk", .guitars), ("country", .guitars),
        ("pop", .sparkles), ("dance", .waveform),
        ("reggae", .sunMax), ("dancehall", .sunMax), ("afrobeat", .sunMax),
        ("latin", .sunMax), ("blues", .micro),
        ("chill", .moonStars), ("ambient", .moonStars), ("sleep", .bed),
        ("focus", .leaf), ("study", .leaf), ("meditation", .leaf),
        ("workout", .figureRun), ("fitness", .figureRun), ("running", .figureRun),
        ("party", .sparkles), ("love", .heart), ("romance", .heart),
        ("radio", .radio), ("live", .speaker), ("concert", .speaker),
        ("charts", .chartBar), ("top", .chartBar), ("essentials", .chartBar),
        ("winter", .snow), ("summer", .sunMax),
        ("drive", .car), ("road trip", .car),
        ("soundtrack", .theatermasks), ("movie", .theatermasks), ("show", .theatermasks),
        ("podcast", .micro), ("world", .globe),
        ("new music", .sparkles), ("mood", .moonStars),
    ]

    static func match(_ identity: String) -> GeneratedArtworkGlyph {
        let lowered = identity.lowercased()
        for (keyword, glyph) in keywordMap where lowered.contains(keyword) {
            return glyph
        }
        let all = GeneratedArtworkGlyph.allCases
        let index = Int(GeneratedArtworkIdentity.hash(identity) % UInt64(all.count))
        return all[index]
    }
}

struct GeneratedArtworkIcon: View {
    let glyph: GeneratedArtworkGlyph
    let cardEdge: CGFloat
    var tint: Color = .white.opacity(0.92)

    var body: some View {
        Image(systemName: glyph.systemImage)
            .font(.system(size: cardEdge * 0.38, weight: .thin))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .minimumScaleFactor(0.8)
    }
}

struct GeneratedArtworkCard: View {
    enum Mode {
        case blob
        case duotone(Image)
    }

    let identity: String
    var mode: Mode = .blob
    var style: SCContentStyle = .tv
    var glyphOverride: GeneratedArtworkGlyph?
    var showGlyphOnDuotone: Bool = false
    var isAnimated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var driftPhase: Double = 0

    private var gradient: GeneratedGradient { GeneratedGradient(identity: identity) }
    private var resolvedGlyph: GeneratedArtworkGlyph {
        glyphOverride ?? GeneratedArtworkGlyph.match(identity)
    }

    var body: some View {
        GeometryReader { geo in
            let edge = min(geo.size.width, geo.size.height)

            ZStack {
                background(edge: edge)

                switch mode {
                case .blob:
                    GeneratedArtworkIcon(glyph: resolvedGlyph, cardEdge: edge)
                case .duotone:
                    if showGlyphOnDuotone {
                        GeneratedArtworkIcon(glyph: resolvedGlyph, cardEdge: edge)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous))
        }
        .task {
            guard isAnimated else { return }
            await runDrift()
        }
    }

    @ViewBuilder
    private func background(edge: CGFloat) -> some View {
        switch mode {
        case .blob:
            gradient.mesh(drift: reduceMotion ? 0 : driftPhase)

        case .duotone(let artwork):
            artwork
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(0)
                .overlay(Rectangle().fill(gradient.duotoneTint).blendMode(.color))
                .overlay(Color.black.opacity(0.16))
        }
    }

    private func runDrift() async {
        while !Task.isCancelled {
            if reduceMotion || prefersReducedResourceUsage {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            withAnimation(SCContentMotion.ambient) {
                driftPhase = driftPhase == 0 ? 0.06 : 0
            }
            try? await Task.sleep(for: .seconds(3.2))
        }
    }

    #if os(iOS) || os(tvOS)
    @Environment(\.soundingReducedResourceUsage) private var prefersReducedResourceUsage
    #else
    private var prefersReducedResourceUsage: Bool { false }
    #endif
}

actor PlaylistMosaicComposer {
    static let shared = PlaylistMosaicComposer()

    static let compositionEdge: CGFloat = 512

    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 40

    private init() {}

    func mosaic(for urls: [URL], edge: CGFloat = PlaylistMosaicComposer.compositionEdge) async -> CGImage? {
        let sources = Self.distinct(urls)
        guard !sources.isEmpty else { return nil }
        let key = cacheKey(urls: sources, edge: edge)
        if let cached = cache[key] { return cached }

        var images: [CGImage] = []
        var fingerprints = Set<Int>()
        for url in sources {
            let source = url.soundCloudArtworkVariant("t500x500")
            var image = await loadCGImage(url: source)
            if image == nil, source != url {
                image = await loadCGImage(url: url)
            }
            guard let image else { continue }
            guard fingerprints.insert(Self.fingerprint(image)).inserted else { continue }
            images.append(image)
        }
        guard let first = images.first else { return nil }

        let composed = Self.compose(images: images, edge: edge) ?? first
        store(composed, for: key)
        return composed
    }

    private func store(_ image: CGImage, for key: String) {
        cache[key] = image
        cacheOrder.append(key)
        guard cacheOrder.count > cacheLimit else { return }
        let oldest = cacheOrder.removeFirst()
        cache[oldest] = nil
    }

    nonisolated static func fingerprint(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        guard let provider = image.dataProvider?.data else {
            hasher.combine(image.bytesPerRow)
            return hasher.finalize()
        }
        let data = provider as Data
        hasher.combine(data.count)
        let step = max(data.count / 4096, 1)
        for index in stride(from: 0, to: data.count, by: step) {
            hasher.combine(data[data.startIndex + index])
        }
        return hasher.finalize()
    }

    nonisolated static func distinct(_ urls: [URL], limit: Int = 4) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where seen.insert(url.soundCloudArtworkIdentity).inserted {
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }

    private func cacheKey(urls: [URL], edge: CGFloat) -> String {
        "\(Int(edge.rounded()))|" + urls.map(\.soundCloudArtworkIdentity).joined(separator: "|")
    }

    private func loadCGImage(url: URL) async -> CGImage? {
        await SCArtworkStore.shared.cgImage(for: url, variant: .signed)
    }

    nonisolated static func cells(count: Int, edge: Int) -> [CGRect] {
        let half = edge / 2
        let restW = edge - half
        let restH = edge - half

        switch max(count, 1) {
        case 1:
            return [CGRect(x: 0, y: 0, width: edge, height: edge)]
        case 2:
            return [
                CGRect(x: 0, y: 0, width: half, height: edge),
                CGRect(x: half, y: 0, width: restW, height: edge),
            ]
        case 3:
            return [
                CGRect(x: 0, y: 0, width: half, height: edge),              // full-height left
                CGRect(x: half, y: half, width: restW, height: restH),       // top-right
                CGRect(x: half, y: 0, width: restW, height: half),           // bottom-right
            ]
        default:
            return [
                CGRect(x: 0, y: half, width: half, height: restH),           // top-left
                CGRect(x: half, y: half, width: restW, height: restH),       // top-right
                CGRect(x: 0, y: 0, width: half, height: half),               // bottom-left
                CGRect(x: half, y: 0, width: restW, height: half),           // bottom-right
            ]
        }
    }

    nonisolated static func fillCrop(_ image: CGImage, cellSize: CGSize) -> CGImage? {
        let sw = CGFloat(image.width), sh = CGFloat(image.height)
        guard sw > 0, sh > 0, cellSize.width > 0, cellSize.height > 0 else { return nil }

        let scale = max(cellSize.width / sw, cellSize.height / sh)
        let cropW = min(sw, (cellSize.width / scale).rounded())
        let cropH = min(sh, (cellSize.height / scale).rounded())
        let rect = CGRect(
            x: ((sw - cropW) / 2).rounded(.down),
            y: ((sh - cropH) / 2).rounded(.down),
            width: cropW,
            height: cropH
        )
        return image.cropping(to: rect) ?? image
    }

    nonisolated static func compose(images: [CGImage], edge: CGFloat) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let pixelEdge = Int(edge.rounded())
        guard pixelEdge > 1 else { return nil }

        let usable = Array(images.prefix(4))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelEdge, height: pixelEdge, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        let rects = cells(count: usable.count, edge: pixelEdge)
        for (index, rect) in rects.enumerated() where index < usable.count {
            let tile = fillCrop(usable[index], cellSize: rect.size) ?? usable[index]
            context.draw(tile, in: rect)
        }
        return context.makeImage()
    }
}

struct PlaylistArtworkView: View {
    let identity: String
    let artworkURL: URL?
    let trackArtworkURLs: [URL]
    var style: SCContentStyle = .tv
    var glyphOverride: GeneratedArtworkGlyph?

    @State private var mosaicImage: CGImage?

    var body: some View {
        GeometryReader { geo in
            let edge = min(geo.size.width, geo.size.height)
            content(edge: edge)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous))
        .task(id: taskID) {
            await resolveMosaicIfNeeded()
        }
    }

    static func distinctArtworkURLs(from urls: [URL?]) -> [URL] {
        PlaylistMosaicComposer.distinct(urls.compactMap { $0 })
    }

    private var distinctURLs: [URL] { Self.distinctArtworkURLs(from: trackArtworkURLs) }
    private var taskID: String { distinctURLs.map(\.soundCloudArtworkIdentity).joined(separator: "|") }

    @ViewBuilder
    private func content(edge: CGFloat) -> some View {
        if let artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    mosaicOrBlob(edge: edge)
                }
            }
        } else {
            mosaicOrBlob(edge: edge)
        }
    }

    @ViewBuilder
    private func mosaicOrBlob(edge: CGFloat) -> some View {
        if let mosaicImage {
            Image(decorative: mosaicImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            GeneratedArtworkCard(identity: identity, mode: .blob, style: style, glyphOverride: glyphOverride)
        }
    }

    private func resolveMosaicIfNeeded() async {
        let urls = distinctURLs
        guard !urls.isEmpty else {
            mosaicImage = nil
            return
        }
        let composed = await PlaylistMosaicComposer.shared.mosaic(for: urls)
        guard !Task.isCancelled else { return }
        mosaicImage = composed
    }
}

private struct KyleCrownBadgeModifier: ViewModifier {
    let position: KyleCrownPosition

    func body(content: Content) -> some View {
        content.overlay {
            if position != .none {
                GeometryReader { proxy in
                    let edge = min(proxy.size.width, proxy.size.height)
                    let fontSize = min(56, max(18, edge * 0.18))
                    let badgeSize = fontSize * 1.46
                    let inset = max(5, edge * 0.035)

                    Text("👑")
                        .font(.system(size: fontSize))
                        .frame(width: badgeSize, height: badgeSize)
                        .background(Color.black.opacity(0.52), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1))
                        .shadow(color: .black.opacity(0.48), radius: 7, y: 3)
                        .position(
                            x: position == .trailing
                                ? proxy.size.width - inset - badgeSize / 2
                                : inset + badgeSize / 2,
                            y: inset + badgeSize / 2
                        )
                        .accessibilityHidden(true)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func kyleCrowned(user: User?, context: String? = nil) -> some View {
        modifier(KyleCrownBadgeModifier(position: KyleCrownPosition.resolve(user: user, context: context)))
    }
}

extension EnvironmentValues {
    /// Backwards-compatible read of `systemPrefersReducedResourceUsage`.
    /// Returns `false` on OS versions older than 27.0.
    var soundingReducedResourceUsage: Bool {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *) {
            return self.systemPrefersReducedResourceUsage
        } else {
            return false
        }
    }
}
