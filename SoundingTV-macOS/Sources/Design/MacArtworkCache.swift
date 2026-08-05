import Foundation
import AppKit
import SwiftUI
import CoreImage
import CoreGraphics

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSImage>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(for url: URL, variant: ArtworkVariant) async -> NSImage? {
        let key = SCArtworkStore.key(for: url, variant: variant)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let cg = await SCArtworkStore.shared.cgImage(for: url, variant: variant) else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        #if DEBUG
        SCArtworkMetrics.event("SHOW", key)
        #endif
        return image
    }

    func cachedImage(for url: URL, variant: ArtworkVariant) -> NSImage? {
        cache.object(forKey: SCArtworkStore.key(for: url, variant: variant) as NSString)
    }

    func heroImage(for url: URL) async -> Image? {
        guard let nsImage = await image(for: url, variant: .hero) else { return nil }
        return Image(nsImage: nsImage)
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
                        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
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

    private var paletteCache: [URL: ArtworkPalette] = [:]
    private var paletteInFlight: [URL: Task<ArtworkPalette, Never>] = [:]

    func palette(for url: URL) async -> ArtworkPalette {
        if let cached = paletteCache[url] { return cached }
        if let running = paletteInFlight[url] { return await running.value }

        let task = Task<ArtworkPalette, Never> {
            guard let cgImage = await SCArtworkStore.shared.cgImage(for: url, variant: .hero) else {
                return .fallback
            }
            cacheHeroImage(cgImage, for: url)
            return extractArtworkPalette(from: cgImage)
        }
        paletteInFlight[url] = task
        let palette = await task.value
        paletteInFlight[url] = nil

        paletteCache[url] = palette
        return palette
    }

    private func cacheHeroImage(_ cgImage: CGImage, for url: URL) {
        let key = SCArtworkStore.key(for: url, variant: .hero) as NSString
        guard cache.object(forKey: key) == nil else { return }
        cache.setObject(
            NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
    }
}

struct ArtworkRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func contrastRatio(against other: ArtworkRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0.0001 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        let s = maxC <= 0.0001 ? 0 : delta / maxC
        return (h, s, maxC)
    }

    static func from(h: Double, s: Double, b: Double) -> ArtworkRGB {
        let c = b * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case 0..<60: (r1, g1, b1) = (c, x, 0)
        case 60..<120: (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return ArtworkRGB(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

struct ArtworkPalette: Equatable {
    let gradientStops: [Color]
    let accent: Color
    let localScrimOpacity: Double

    static let backgroundLuminanceCeiling = 0.16
    static let backgroundSaturationCeiling = 0.42
    static let accentContrastFloor = 3.0
    static let accentSaturationFloor = 0.45
    static let accentLightnessFloor = 0.55
    static let accentLightnessCeiling = 0.90

    static let fallback = ArtworkPalette(
        gradientStops: [
            Color(red: 0.11, green: 0.11, blue: 0.14),
            Color(red: 0.05, green: 0.05, blue: 0.07)
        ],
        accent: Color(red: 0.60, green: 0.62, blue: 0.95),
        localScrimOpacity: 0.32
    )
}

private func clampForWash(_ raw: ArtworkRGB) -> ArtworkRGB {
    var (h, s, b) = raw.hsb
    s = min(s, ArtworkPalette.backgroundSaturationCeiling)
    b = min(b, 0.55)
    var out = ArtworkRGB.from(h: h, s: s, b: b)
    var steps = 0
    while out.relativeLuminance > ArtworkPalette.backgroundLuminanceCeiling, steps < 24 {
        b *= 0.9
        out = ArtworkRGB.from(h: h, s: s, b: b)
        steps += 1
    }
    return out
}

private func clampForAccent(_ raw: ArtworkRGB, against background: ArtworkRGB) -> ArtworkRGB {
    let (h, s, initialB) = raw.hsb
    let boostedS = max(s, ArtworkPalette.accentSaturationFloor)
    var b = min(ArtworkPalette.accentLightnessCeiling, max(ArtworkPalette.accentLightnessFloor, initialB))
    var out = ArtworkRGB.from(h: h, s: boostedS, b: b)
    var steps = 0
    while out.contrastRatio(against: background) < ArtworkPalette.accentContrastFloor, steps < 24 {
        if out.relativeLuminance < background.relativeLuminance {
            b = max(0, b * 0.85)
        } else {
            b = min(1, b * 1.12 + 0.03)
        }
        out = ArtworkRGB.from(h: h, s: boostedS, b: b)
        steps += 1
    }
    return out
}

func extractArtworkPalette(from image: CGImage) -> ArtworkPalette {
    let ci = CIImage(cgImage: image)
    let extent = ci.extent
    let context = CIContext(options: [.workingColorSpace: NSNull()])

    func average(_ rect: CGRect) -> ArtworkRGB {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]), let output = filter.outputImage else {
            return ArtworkRGB(r: 0.08, g: 0.08, b: 0.1)
        }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return ArtworkRGB(r: Double(bitmap[0]) / 255, g: Double(bitmap[1]) / 255, b: Double(bitmap[2]) / 255)
    }

    let topLeading = average(CGRect(
        x: extent.minX, y: extent.minY + extent.height * 0.5,
        width: extent.width * 0.5, height: extent.height * 0.5
    ))
    let bottomTrailing = average(CGRect(
        x: extent.minX + extent.width * 0.5, y: extent.minY,
        width: extent.width * 0.5, height: extent.height * 0.5
    ))
    let whole = average(extent)
    let titleRegion = average(CGRect(
        x: extent.minX, y: extent.minY,
        width: extent.width * 0.4, height: extent.height * 0.34
    ))

    let washTop = clampForWash(topLeading)
    let washBottom = clampForWash(bottomTrailing)
    let vivid = [topLeading, bottomTrailing, whole].max(by: { $0.hsb.s < $1.hsb.s }) ?? whole
    let clampedAccent = clampForAccent(vivid, against: washBottom)
    let accentMeetsContrast = clampedAccent.contrastRatio(against: washBottom) >= ArtworkPalette.accentContrastFloor
    let accent = accentMeetsContrast ? clampedAccent.color : Color.accentColor

    let localScrim = min(0.62, max(0.22, titleRegion.relativeLuminance * 1.8))

    return ArtworkPalette(
        gradientStops: [washTop.color, washBottom.color],
        accent: accent,
        localScrimOpacity: localScrim
    )
}
