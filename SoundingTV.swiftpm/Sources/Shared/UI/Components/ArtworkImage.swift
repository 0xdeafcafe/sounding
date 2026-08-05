import SwiftUI
import UIKit

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    private init() {
        cache.countLimit = 160
        #if os(tvOS)
        cache.totalCostLimit = 96 * 1024 * 1024
        #else
        cache.totalCostLimit = 64 * 1024 * 1024
        #endif
    }

    func image(for url: URL, variant: ArtworkVariant) async -> UIImage? {
        let key = SCArtworkStore.key(for: url, variant: variant)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let cg = await SCArtworkStore.shared.cgImage(for: url, variant: variant) else {
            return nil
        }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        #if DEBUG
        SCArtworkMetrics.event("SHOW", key)
        #endif
        return image
    }

    func cachedImage(for url: URL, variant: ArtworkVariant) -> UIImage? {
        cache.object(forKey: SCArtworkStore.key(for: url, variant: variant) as NSString)
    }

    func prefetch(_ urls: [URL], variant: ArtworkVariant = .standard) {
        for url in urls {
            let key = SCArtworkStore.key(for: url, variant: variant)
            guard prefetchTasks[key] == nil,
                  cache.object(forKey: key as NSString) == nil else { continue }
            prefetchTasks[key] = Task(priority: .utility) { [weak self] in
                if let cg = await SCArtworkStore.shared.prefetchImage(for: url, variant: variant),
                   !Task.isCancelled, let self {
                    self.cache.setObject(
                        UIImage(cgImage: cg),
                        forKey: key as NSString,
                        cost: cg.bytesPerRow * cg.height
                    )
                }
                self?.prefetchTasks[key] = nil
            }
        }
    }

    func cancelPrefetch(_ urls: [URL], variant: ArtworkVariant = .standard) {
        for url in urls {
            let key = SCArtworkStore.key(for: url, variant: variant)
            prefetchTasks[key]?.cancel()
            prefetchTasks[key] = nil
        }
    }
}

struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    var variant: ArtworkVariant = .standard
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    private var displayedImage: UIImage? {
        if let image { return image }
        guard let url else { return nil }
        return ArtworkCache.shared.cachedImage(for: url, variant: variant)
    }

    var body: some View {
        Group {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ArtworkCache.shared.cachedImage(for: url, variant: variant) {
                image = cached
                return
            }
            image = nil
            image = await ArtworkCache.shared.image(for: url, variant: variant)
        }
    }
}

extension ArtworkImage where Placeholder == ArtworkPlaceholder {
    init(url: URL?, variant: ArtworkVariant = .standard, icon: String = "music.note") {
        self.init(url: url, variant: variant) { ArtworkPlaceholder(icon: icon) }
    }
}

struct ArtworkPlaceholder: View {
    var icon: String = "music.note"

    private static let glyphFraction: CGFloat = 0.34

    var body: some View {
        Color.scBgRaised
            .overlay {
                GeometryReader { geo in
                    Image(systemName: icon)
                        .font(.system(
                            size: min(geo.size.width, geo.size.height) * Self.glyphFraction,
                            weight: .light
                        ))
                        .foregroundStyle(Color.scTextTertiary)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
    }
}
