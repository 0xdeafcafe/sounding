import CoreGraphics
import Foundation
import ImageIO

enum ImageThumbnail {
    nonisolated static func pixelSize(of source: CGImageSource, at index: Int = 0) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    nonisolated static func clampedMaxPixelSize(_ requested: Int, width: Int, height: Int) -> Int {
        let longest = max(width, height)
        guard requested > 0, longest > 0 else { return requested }
        return min(requested, longest)
    }

    nonisolated static func clampedMaxPixelSize(_ requested: Int, for source: CGImageSource) -> Int {
        guard let size = pixelSize(of: source) else { return requested }
        return clampedMaxPixelSize(requested, width: size.width, height: size.height)
    }

    nonisolated static func create(
        from source: CGImageSource,
        maxPixelSize: Int,
        cacheImmediately: Bool = false
    ) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedMaxPixelSize(maxPixelSize, for: source),
        ]
        if cacheImmediately {
            options[kCGImageSourceShouldCacheImmediately] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
