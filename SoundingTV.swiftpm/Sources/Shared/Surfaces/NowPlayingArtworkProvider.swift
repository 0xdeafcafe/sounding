import Foundation
import CoreGraphics
import MediaPlayer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class NowPlayingArtworkProviderImpl: NowPlayingArtworkProvider {
    static let shared = NowPlayingArtworkProviderImpl()

    private init() {}

    func artwork(for cgImage: CGImage) -> MPMediaItemArtwork {
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
