import Foundation
import CoreGraphics
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingArtworkProviderImpl: NowPlayingArtworkProvider {
    static let shared = NowPlayingArtworkProviderImpl()

    private init() {}

    func artwork(for cgImage: CGImage) -> MPMediaItemArtwork {
        let image = UIImage(cgImage: cgImage)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
