import SwiftUI
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SCPlatformImageBridge {
    #if canImport(UIKit)
    static func image(_ platformImage: UIImage) -> Image { Image(uiImage: platformImage) }
    #elseif canImport(AppKit)
    static func image(_ platformImage: NSImage) -> Image { Image(nsImage: platformImage) }
    #endif
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

    @State private var image: Image?

    private var displayedImage: Image? {
        if let image { return image }
        guard let url else { return nil }
        guard let cached = ArtworkCache.shared.cachedImage(for: url, variant: variant) else { return nil }
        return SCPlatformImageBridge.image(cached)
    }

    var body: some View {
        content(displayedImage)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                if let cached = ArtworkCache.shared.cachedImage(for: url, variant: variant) {
                    image = SCPlatformImageBridge.image(cached)
                    return
                }
                image = nil
                guard let loaded = await ArtworkCache.shared.image(for: url, variant: variant) else { return }
                image = SCPlatformImageBridge.image(loaded)
            }
    }
}

struct SCCollectionArtworkResolver<Content: View>: View {
    let artworkURL: URL?
    let trackArtworkURLs: [URL]
    var variant: ArtworkVariant = .standard
    @ViewBuilder var content: (Image?) -> Content

    @State private var image: Image?

    private var mosaicURLs: [URL] {
        PlaylistArtworkView.distinctArtworkURLs(from: trackArtworkURLs.map { Optional($0) })
    }

    private var taskID: String {
        (artworkURL?.absoluteString ?? "") + "#" + mosaicURLs.map(\.absoluteString).joined(separator: "|")
    }

    var body: some View {
        content(image)
            .task(id: taskID) { await resolve() }
    }

    private func resolve() async {
        if let artworkURL,
           let cached = ArtworkCache.shared.cachedImage(for: artworkURL, variant: variant) {
            image = SCPlatformImageBridge.image(cached)
            return
        }

        image = nil

        if let artworkURL,
           let loaded = await ArtworkCache.shared.image(for: artworkURL, variant: variant) {
            image = SCPlatformImageBridge.image(loaded)
            return
        }

        let urls = mosaicURLs
        guard !urls.isEmpty else { return }
        guard let composed = await PlaylistMosaicComposer.shared.mosaic(for: urls) else { return }
        guard !Task.isCancelled else { return }
        image = Image(decorative: composed, scale: 1)

    }
}
