import SwiftUI
import CoreImage
import UIKit

@MainActor
final class ArtworkColors: ObservableObject {
    static let shared = ArtworkColors()

    @Published private(set) var current: Palette = .fallback

    private var cache: [URL: Palette] = [:]
    private var lastRequestedURL: URL?

    private init() {}

    func lockAccount() {
        lastRequestedURL = nil
        cache.removeAll()
        current = .fallback
    }

    func update(for url: URL?) {
        lastRequestedURL = url

        guard let url else {
            current = .fallback
            return
        }

        if let cached = cache[url] {
            current = cached
            return
        }

        // Download, decode, and CoreImage filtering all run on a background
        // queue so the main actor is not blocked by artwork color extraction.
        Task.detached(priority: .utility) { [weak self, url] in
            guard let palette = await Self.extract(from: url) else { return }
            await MainActor.run {
                guard let self, self.lastRequestedURL == url else { return }
                self.cache[url] = palette
                withAnimation(.easeInOut(duration: 0.55)) {
                    self.current = palette
                }
            }
        }
    }

    nonisolated private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated private static func extract(from url: URL) async -> Palette? {
        guard let cg = await SCArtworkStore.shared.cgImage(for: url, variant: .standard) else { return nil }

        let ci = CIImage(cgImage: cg)
        let extent = ci.extent

        let regions: [CGRect] = [
            extent,
            CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.minX, y: extent.midY, width: extent.width / 2, height: extent.height / 2),
            CGRect(x: extent.midX, y: extent.midY, width: extent.width / 2, height: extent.height / 2)
        ]
        let colors = regions.compactMap { rect in
            Self.averageColor(of: ci, in: rect, context: Self.ciContext)
        }
        guard let primary = colors.first else { return nil }

        let candidates = Array(colors.dropFirst())
        let mostVibrant = candidates.max(by: { Self.saturation(of: $0) < Self.saturation(of: $1) }) ?? primary
        let other = candidates.min(by: { Self.saturation(of: $0) < Self.saturation(of: $1) }) ?? primary

        let background = SCAmbient.background(from: mostVibrant)
        return Palette(
            primary:   background,
            secondary: SCAmbient.background(from: other),
            average:   SCAmbient.background(from: primary),
            accent:    SCAmbient.accent(from: mostVibrant, on: background),
            rawMean:   SCAmbient.components(primary),
            artwork:   Image(decorative: cg, scale: 1)
        )
    }

    nonisolated private static func saturation(of color: Color) -> CGFloat {
        SCAmbient.hsb(SCAmbient.components(color)).saturation
    }

    nonisolated private static func averageColor(of image: CIImage, in rect: CGRect, context: CIContext) -> Color? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]),
              let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Color(
            red:   Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue:  Double(bitmap[2]) / 255
        )
    }

    struct Palette: Equatable {
        let primary: Color
        let secondary: Color
        let average: Color
        let accent: Color
        let rawMean: SCAmbient.RGB
        let artwork: Image?

        func backdropScrim(layerOpacity: Double, additiveHeadroom: Double) -> Double {
            SCAmbient.scrimAlpha(
                mean: rawMean,
                layerOpacity: layerOpacity,
                additiveHeadroom: additiveHeadroom
            )
        }

        static let fallback = Palette(
            primary: Color(red: 0.10, green: 0.10, blue: 0.16),
            secondary: Color(red: 0.04, green: 0.04, blue: 0.08),
            average: Color(red: 0.08, green: 0.08, blue: 0.12),
            accent: .scAccent,
            rawMean: SCAmbient.RGB(r: 0.08, g: 0.08, b: 0.12),
            artwork: nil
        )

        static func == (lhs: Palette, rhs: Palette) -> Bool {
            lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
                && lhs.average == rhs.average && lhs.accent == rhs.accent
                && lhs.rawMean == rhs.rawMean
        }
    }
}
