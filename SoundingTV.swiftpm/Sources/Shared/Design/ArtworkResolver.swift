import SwiftUI
import CoreGraphics

#if canImport(UIKit)
import UIKit
typealias SCPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias SCPlatformImage = NSImage
#endif

enum SCPlatformImageBridge {
    #if canImport(UIKit)
    static func image(_ platformImage: UIImage) -> Image { Image(uiImage: platformImage) }
    static func platformImage(_ cgImage: CGImage) -> UIImage { UIImage(cgImage: cgImage) }
    #elseif canImport(AppKit)
    static func image(_ platformImage: NSImage) -> Image { Image(nsImage: platformImage) }
    static func platformImage(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, SCPlatformImage>()

    private init() {
        cache.countLimit = SCArtworkMemoryCache.defaultCountLimit
        cache.totalCostLimit = SCArtworkMemoryCache.defaultCostLimit
    }

    func image(for url: URL, variant: ArtworkVariant) async -> SCPlatformImage? {
        let key = SCArtworkStore.storageKey(for: url, variant: variant)
        if let hit = cachedImage(forKey: key) { return hit }
        guard let cgImage = await SCArtworkStore.shared.cgImage(for: url, variant: variant) else { return nil }
        #if DEBUG
        SCArtworkMetrics.event("SHOW", key)
        #endif
        return cache.object(forKey: key as NSString) ?? insert(cgImage, forKey: key)
    }

    func cachedImage(for url: URL, variant: ArtworkVariant) -> SCPlatformImage? {
        cachedImage(forKey: SCArtworkStore.storageKey(for: url, variant: variant))
    }

    func bestCachedImage(for url: URL, variant: ArtworkVariant) -> SCPlatformImage? {
        let identity = url.soundCloudArtworkIdentity
        if let exact = cachedImage(forKey: SCArtworkStore.storageKey(identity: identity, variant: variant)) {
            return exact
        }
        for fallback in variant.displayFallbacks {
            if let hit = cachedImage(forKey: SCArtworkStore.storageKey(identity: identity, variant: fallback)) {
                return hit
            }
        }
        return nil
    }

    @discardableResult
    func store(_ cgImage: CGImage, for url: URL, variant: ArtworkVariant) -> SCPlatformImage {
        let key = SCArtworkStore.storageKey(for: url, variant: variant)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        SCArtworkStore.shared.insertIntoMemory(cgImage, forKey: key)
        return insert(cgImage, forKey: key)
    }

    func prefetch(_ urls: [URL], variant: ArtworkVariant = .standard) {
        SCArtworkStore.shared.prefetch(urls, variant: variant)
    }

    func cancelPrefetch(_ urls: [URL], variant: ArtworkVariant = .standard) {
        SCArtworkStore.shared.cancelPrefetch(urls, variant: variant)
    }

    func purgeMemory() {
        cache.removeAllObjects()
        SCArtworkStore.shared.purgeMemory()
    }

    private func cachedImage(forKey key: String) -> SCPlatformImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let cgImage = SCArtworkStore.shared.cachedImage(forKey: key) else { return nil }
        return insert(cgImage, forKey: key)
    }

    private func insert(_ cgImage: CGImage, forKey key: String) -> SCPlatformImage {
        let image = SCPlatformImageBridge.platformImage(cgImage)
        cache.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

struct SCArtworkRequest: Hashable {
    let url: URL?
    let variant: ArtworkVariant
}

struct SCResolvedArtwork {
    let url: URL
    let variant: ArtworkVariant
    let image: SCPlatformImage

    func matches(_ url: URL?, _ variant: ArtworkVariant) -> Bool {
        self.url == url && self.variant == variant
    }

    @MainActor
    static func display(url: URL?, variant: ArtworkVariant, loaded: SCResolvedArtwork?) -> SCPlatformImage? {
        guard let url else { return nil }
        if let loaded, loaded.matches(url, variant) { return loaded.image }
        return ArtworkCache.shared.bestCachedImage(for: url, variant: variant)
    }

    @MainActor
    static func load(
        url: URL?,
        variant: ArtworkVariant,
        loaded: Binding<SCResolvedArtwork?>,
        failedURL: Binding<URL?>
    ) async {
        guard let url else {
            loaded.wrappedValue = nil
            return
        }
        if loaded.wrappedValue?.matches(url, variant) == true { return }
        if let exact = ArtworkCache.shared.cachedImage(for: url, variant: variant) {
            scWithoutAnimation { loaded.wrappedValue = SCResolvedArtwork(url: url, variant: variant, image: exact) }
            return
        }
        let image = await ArtworkCache.shared.image(for: url, variant: variant)
        guard !Task.isCancelled else { return }
        scWithoutAnimation {
            if let image {
                loaded.wrappedValue = SCResolvedArtwork(url: url, variant: variant, image: image)
            } else {
                failedURL.wrappedValue = url
            }
        }
    }
}

@MainActor
func scWithoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

extension View {
    func prefetchArtwork(_ urls: [URL], variant: ArtworkVariant = .standard) -> some View {
        onAppear { ArtworkCache.shared.prefetch(urls, variant: variant) }
            .onDisappear { ArtworkCache.shared.cancelPrefetch(urls, variant: variant) }
    }
}

struct SCArtworkResolver<Content: View>: View {
    let url: URL?
    var variant: ArtworkVariant = .standard
    @ViewBuilder var content: (Image?) -> Content

    @State private var loaded: SCResolvedArtwork?
    @State private var failedURL: URL?

    var body: some View {
        let displayed = SCResolvedArtwork.display(url: url, variant: variant, loaded: loaded)
        content(displayed.map(SCPlatformImageBridge.image))
            .environment(\.soundingArtworkPending, url != nil && displayed == nil && failedURL != url)
            .task(id: SCArtworkRequest(url: url, variant: variant)) {
                await SCResolvedArtwork.load(url: url, variant: variant, loaded: $loaded, failedURL: $failedURL)
            }
    }
}

struct SCCollectionArtworkResolver<Content: View>: View {
    let artworkURL: URL?
    let trackArtworkURLs: [URL]
    var variant: ArtworkVariant = .standard
    @ViewBuilder var content: (Image?) -> Content

    private struct Resolved {
        let id: String
        let image: Image
    }

    @State private var resolved: Resolved?
    @State private var settledID: String?

    var body: some View {
        let mosaicURLs = PlaylistArtworkView.distinctArtworkURLs(from: trackArtworkURLs.map { Optional($0) })
        let id = Self.taskID(artworkURL: artworkURL, mosaicURLs: mosaicURLs)
        let image = current(id: id, mosaicURLs: mosaicURLs)
        content(image)
            .environment(\.soundingArtworkPending, image == nil && id != "#" && settledID != id)
            .task(id: id) {
                await resolve(id: id, mosaicURLs: mosaicURLs)
            }
    }

    private static func taskID(artworkURL: URL?, mosaicURLs: [URL]) -> String {
        (artworkURL?.absoluteString ?? "") + "#" + mosaicURLs.map(\.absoluteString).joined(separator: "|")
    }

    private func current(id: String, mosaicURLs: [URL]) -> Image? {
        if let resolved, resolved.id == id { return resolved.image }
        if let artworkURL, let cached = ArtworkCache.shared.bestCachedImage(for: artworkURL, variant: variant) {
            return SCPlatformImageBridge.image(cached)
        }
        if !mosaicURLs.isEmpty, let mosaic = PlaylistMosaicComposer.cachedMosaic(for: mosaicURLs) {
            return Image(decorative: mosaic, scale: 1)
        }
        return resolved?.image
    }

    private func resolve(id: String, mosaicURLs: [URL]) async {
        if resolved?.id == id { return }
        var image: Image?
        if let artworkURL, let loaded = await ArtworkCache.shared.image(for: artworkURL, variant: variant) {
            image = SCPlatformImageBridge.image(loaded)
        }
        if image == nil, !mosaicURLs.isEmpty, !Task.isCancelled,
           let composed = await PlaylistMosaicComposer.shared.mosaic(for: mosaicURLs) {
            image = Image(decorative: composed, scale: 1)
        }
        guard !Task.isCancelled else { return }
        scWithoutAnimation {
            resolved = image.map { Resolved(id: id, image: $0) }
            settledID = id
        }
    }
}
