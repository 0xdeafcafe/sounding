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

    static func seed(_ id: String) -> UInt64 {
        UInt64(id) ?? hash(id)
    }

    static func unit(_ string: String, salt: UInt64 = 0) -> Double {
        let h = hash(string) &+ salt
        return Double(h % 1_000_000) / 1_000_000
    }

    static func hue(for string: String) -> Double {
        unit(string, salt: 0x9E3779B97F4A7C15)
    }
}

struct GeneratedArtworkCard: View {
    let identity: String
    var subject: SoundingArtSubject = .track
    var style: SCContentStyle = .tv
    var colorScheme: ColorScheme?

    var body: some View {
        SoundingArtworkView(identity: identity, subject: subject, colorScheme: colorScheme)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous))
    }
}

actor PlaylistMosaicComposer {
    static let shared = PlaylistMosaicComposer()

    static let compositionEdge: CGFloat = 512

    static let memory: SCArtworkMemoryCache = {
        #if os(watchOS)
        return SCArtworkMemoryCache(costLimit: 4 * 1024 * 1024, countLimit: 8)
        #else
        return SCArtworkMemoryCache(costLimit: 48 * 1024 * 1024, countLimit: 64)
        #endif
    }()

    private init() {}

    nonisolated static func cachedMosaic(for urls: [URL], edge: CGFloat = PlaylistMosaicComposer.compositionEdge) -> CGImage? {
        let sources = distinct(urls)
        guard !sources.isEmpty else { return nil }
        return memory.image(forKey: cacheKey(urls: sources, edge: edge))
    }

    func mosaic(for urls: [URL], edge: CGFloat = PlaylistMosaicComposer.compositionEdge) async -> CGImage? {
        let sources = Self.distinct(urls)
        guard !sources.isEmpty else { return nil }
        let key = Self.cacheKey(urls: sources, edge: edge)
        if let cached = Self.memory.image(forKey: key) { return cached }

        let loaded = await withTaskGroup(of: (Int, CGImage?).self, returning: [CGImage?].self) { group in
            for (index, url) in sources.enumerated() {
                group.addTask { (index, await Self.loadTile(url)) }
            }
            var results = [CGImage?](repeating: nil, count: sources.count)
            for await (index, image) in group { results[index] = image }
            return results
        }

        var images: [CGImage] = []
        var fingerprints = Set<Int>()
        for image in loaded.compactMap({ $0 }) {
            guard fingerprints.insert(Self.fingerprint(image)).inserted else { continue }
            images.append(image)
        }
        guard let first = images.first else { return nil }

        let composed = Self.compose(images: images, edge: edge) ?? first
        Self.memory.insert(composed, forKey: key)
        return composed
    }

    func purge() {
        Self.memory.removeAll()
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

    private nonisolated static func cacheKey(urls: [URL], edge: CGFloat) -> String {
        "\(Int(edge.rounded()))|" + urls.map(\.soundCloudArtworkIdentity).joined(separator: "|")
    }

    private nonisolated static func loadTile(_ url: URL) async -> CGImage? {
        await SCArtworkStore.shared.cgImage(for: url, variant: .standard)
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

    var body: some View {
        GeometryReader { geo in
            SCCollectionArtworkResolver(artworkURL: artworkURL, trackArtworkURLs: trackArtworkURLs) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    GeneratedArtworkCard(identity: identity, subject: .collection, style: style)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous))
    }

    static func distinctArtworkURLs(from urls: [URL?]) -> [URL] {
        PlaylistMosaicComposer.distinct(urls.compactMap { $0 })
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
