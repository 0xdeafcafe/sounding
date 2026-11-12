import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

final class SoundingArtCache: @unchecked Sendable {
    static let shared = SoundingArtCache()

    private final class Entry {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let memory = NSCache<NSString, Entry>()
    private let flights = SoundingArtFlights()
    private let directory: URL

    private init() {
        #if os(watchOS)
        memory.countLimit = 120
        memory.totalCostLimit = 8 * 1024 * 1024
        #elseif os(tvOS)
        memory.countLimit = 400
        memory.totalCostLimit = 64 * 1024 * 1024
        #else
        memory.countLimit = 400
        memory.totalCostLimit = 40 * 1024 * 1024
        #endif
        let base = FileManager.default.soundingDirectory(.cachesDirectory)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Artwork", isDirectory: true)
    }

    func cachedImage(for request: SoundingArtRequest) -> CGImage? {
        memory.object(forKey: request.cacheKey as NSString)?.image
    }

    func image(for request: SoundingArtRequest) async -> CGImage? {
        if let hit = cachedImage(for: request) { return hit }
        return await flights.run(request.cacheKey) { [self] in produce(request) }
    }

    func purgeMemory() {
        memory.removeAllObjects()
    }

    private func produce(_ request: SoundingArtRequest) -> CGImage? {
        let key = request.cacheKey
        if let hit = cachedImage(for: request) { return hit }
        let file = directory.appendingPathComponent(SCArtworkStore.digest(of: key), isDirectory: false)
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            store(image, key: key)
            return image
        }
        guard let image = SoundingArtRenderer.render(request) else { return nil }
        store(image, key: key)
        let directory = directory
        Task.detached(priority: .background) {
            Self.write(image, to: file, in: directory)
        }
        return image
    }

    private func store(_ image: CGImage, key: String) {
        memory.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func write(_ image: CGImage, to file: URL, in directory: URL) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (data as Data).write(to: file, options: .atomic)
    }
}

private actor SoundingArtFlights {
    private var tasks: [String: Task<CGImage?, Never>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        if let task = tasks[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { work() }
        tasks[key] = task
        let image = await task.value
        tasks[key] = nil
        return image
    }
}

struct SoundingArtworkView: View {
    var seed: UInt64
    var subject: SoundingArtSubject = .track
    var tint: SoundingArtRGB?
    var motif: SoundingArtMotif?
    var colorScheme: ColorScheme?
    var displaySize: CGSize?

    @Environment(\.colorScheme) private var environmentScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.soundingArtworkPending) private var pending
    @State private var size: CGSize = .zero
    @State private var renderedKey: String?
    @State private var rendered: CGImage?

    init(seed: UInt64, subject: SoundingArtSubject = .track, tint: SoundingArtRGB? = nil, motif: SoundingArtMotif? = nil, colorScheme: ColorScheme? = nil) {
        self.seed = seed
        self.subject = subject
        self.tint = tint
        self.motif = motif
        self.colorScheme = colorScheme
    }

    init(identity: String, subject: SoundingArtSubject = .track, tint: SoundingArtRGB? = nil, colorScheme: ColorScheme? = nil, displaySize: CGSize? = nil) {
        self.init(seed: GeneratedArtworkIdentity.seed(identity), subject: subject, tint: tint, colorScheme: colorScheme)
        self.displaySize = displaySize
    }

    private var resolvedSize: CGSize { displaySize ?? size }

    private var scheme: SoundingArtScheme {
        (colorScheme ?? environmentScheme) == .dark ? .dark : .light
    }

    private var request: SoundingArtRequest? {
        let size = resolvedSize
        guard !pending, size.width >= 1, size.height >= 1 else { return nil }
        return SoundingArtRequest(seed: seed, subject: subject, scheme: scheme, size: size, scale: displayScale, tint: tint, motif: motif)
    }

    var body: some View {
        let request = request
        let image = request.flatMap(image(for:))
        Rectangle()
            .fill(Color(cgColor: groundColour))
            .overlay {
                if let image, let request {
                    Image(decorative: image, scale: CGFloat(request.scale))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if displaySize == nil { size = $0 } }
            .task(id: request) {
                guard let request, renderedKey != request.cacheKey else { return }
                guard let image = await SoundingArtCache.shared.image(for: request), !Task.isCancelled else { return }
                rendered = image
                renderedKey = request.cacheKey
            }
            .accessibilityHidden(true)
    }

    private var groundColour: CGColor {
        let ground = SoundingArtTheme.ground(scheme, tint: tint)
        guard pending else { return ground.cgColor }
        return ground.mixed(with: SoundingArtTheme.base(scheme).masses[0], 0.22).cgColor
    }

    private func image(for request: SoundingArtRequest) -> CGImage? {
        if renderedKey == request.cacheKey, let rendered { return rendered }
        return SoundingArtCache.shared.cachedImage(for: request)
    }
}

extension EnvironmentValues {
    @Entry var soundingArtworkPending = false
}

struct SoundingArtVignette: View {
    var identity: String
    var motif: SoundingArtMotif?
    var width: CGFloat = 220
    var height: CGFloat = 132

    var body: some View {
        SoundingArtworkView(seed: GeneratedArtworkIdentity.hash(identity), subject: .scene, motif: motif)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: min(width, height) * 0.16, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension SoundingArtRGB {
    static let genreTints: [SoundingArtRGB] = [
        SoundingArtRGB(0.86, 0.42, 0.18),
        SoundingArtRGB(0.80, 0.62, 0.24),
        SoundingArtRGB(0.18, 0.58, 0.52),
        SoundingArtRGB(0.86, 0.46, 0.46),
        SoundingArtRGB(0.52, 0.30, 0.52),
        SoundingArtRGB(0.24, 0.42, 0.62),
        SoundingArtRGB(0.46, 0.56, 0.26),
        SoundingArtRGB(0.80, 0.26, 0.20),
    ]

    static func genreTint(_ name: String) -> SoundingArtRGB {
        let lowered = name.lowercased()
        let keywords: [(String, Int)] = [
            ("hip", 7), ("rap", 7), ("electronic", 5), ("techno", 4), ("house", 2), ("pop", 3),
            ("r&b", 4), ("rnb", 4), ("soul", 4), ("chill", 2), ("ambient", 5), ("party", 0),
            ("workout", 6), ("rock", 7), ("jazz", 1), ("classical", 1), ("folk", 6), ("dance", 0),
        ]
        if let match = keywords.first(where: { lowered.contains($0.0) }) {
            return genreTints[match.1]
        }
        return genreTints[Int(GeneratedArtworkIdentity.hash(name) % UInt64(genreTints.count))]
    }
}

struct SoundingArtEmptyLabel: View {
    var title: String
    var identity: String
    var motif: SoundingArtMotif?

    var body: some View {
        VStack(spacing: 18) {
            SoundingArtVignette(identity: identity, motif: motif)
            Text(title)
        }
    }
}
