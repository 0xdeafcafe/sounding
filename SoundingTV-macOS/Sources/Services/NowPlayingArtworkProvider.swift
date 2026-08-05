import Foundation
import CoreGraphics
import MediaPlayer
import AppKit

@MainActor
final class NowPlayingArtworkProviderImpl: NowPlayingArtworkProvider {
    static let shared = NowPlayingArtworkProviderImpl()

    private init() {}

    func artwork(for cgImage: CGImage) -> MPMediaItemArtwork {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
