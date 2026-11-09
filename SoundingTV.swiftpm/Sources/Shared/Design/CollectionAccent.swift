import SwiftUI
import CoreGraphics

struct CollectionAccent: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
    }

    struct HSB: Equatable, Sendable {
        var h: Double
        var s: Double
        var v: Double
    }

    let base: RGB

    var isNeutral: Bool { Self.hsb(base).s < 0.12 }

    func tint(for scheme: ColorScheme) -> Color {
        Self.color(resolvedTint(for: scheme))
    }

    func onTint(for scheme: ColorScheme) -> Color {
        let tint = resolvedTint(for: scheme)
        return Self.contrast(tint, Self.white) >= Self.contrast(tint, Self.black) ? .white : .black
    }

    func wash(for scheme: ColorScheme) -> Color {
        var shade = Self.hsb(base)
        if scheme == .dark {
            shade.s = isNeutral ? shade.s : min(max(shade.s, 0.35), 0.75)
            shade.v = 0.34
        } else {
            shade.s = isNeutral ? shade.s : min(max(shade.s * 0.6, 0.18), 0.4)
            shade.v = 0.94
        }
        return Self.color(Self.rgb(shade))
    }

    func pageTint(for scheme: ColorScheme) -> Color {
        wash(for: scheme).opacity(scheme == .dark ? 0.35 : 0.45)
    }

    private func resolvedTint(for scheme: ColorScheme) -> RGB {
        var shade = Self.hsb(base)
        if !isNeutral { shade.s = max(shade.s, 0.4) }
        if scheme == .dark {
            var candidate = Self.rgb(shade)
            var steps = 0
            while Self.contrast(candidate, Self.darkGround) < 4.5, steps < 24 {
                shade.v = min(1, shade.v + 0.04)
                if shade.v >= 1 { shade.s = max(0, shade.s - 0.05) }
                candidate = Self.rgb(shade)
                steps += 1
            }
            return candidate
        } else {
            var candidate = Self.rgb(shade)
            var steps = 0
            while Self.contrast(candidate, Self.white) < 4.5, steps < 24 {
                shade.v = max(0, shade.v - 0.04)
                candidate = Self.rgb(shade)
                steps += 1
            }
            return candidate
        }
    }

    private static let white = RGB(r: 1, g: 1, b: 1)
    private static let black = RGB(r: 0, g: 0, b: 0)
    private static let darkGround = RGB(r: 0.07, g: 0.07, b: 0.08)

    static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func luminance(_ rgb: RGB) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func hsb(_ rgb: RGB) -> HSB {
        let maxC = max(rgb.r, rgb.g, rgb.b)
        let minC = min(rgb.r, rgb.g, rgb.b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == rgb.r {
                hue = ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == rgb.g {
                hue = (rgb.b - rgb.r) / delta + 2
            } else {
                hue = (rgb.r - rgb.g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return HSB(h: hue, s: maxC == 0 ? 0 : delta / maxC, v: maxC)
    }

    static func rgb(_ shade: HSB) -> RGB {
        let h = (shade.h - floor(shade.h)) * 6
        let c = shade.v * shade.s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = shade.v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(r: r + m, g: g + m, b: b + m)
    }

    static func extract(from image: CGImage) -> CollectionAccent? {
        let side = 24
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let binCount = 12
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: binCount)
        var average = RGB(r: 0, g: 0, b: 0)
        var counted = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let rgb = RGB(r: Double(pixels[index]) / 255, g: Double(pixels[index + 1]) / 255, b: Double(pixels[index + 2]) / 255)
            average.r += rgb.r
            average.g += rgb.g
            average.b += rgb.b
            counted += 1

            let shade = Self.hsb(rgb)
            guard shade.s > 0.18, shade.v > 0.18, shade.v < 0.98 else { continue }
            let weight = shade.s * (1 - abs(shade.v - 0.6))
            let bin = min(binCount - 1, Int(shade.h * Double(binCount)))
            weights[bin] += weight
            sums[bin].r += rgb.r * weight
            sums[bin].g += rgb.g * weight
            sums[bin].b += rgb.b * weight
        }

        guard counted > 0 else { return nil }
        average = RGB(r: average.r / counted, g: average.g / counted, b: average.b / counted)

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > counted * 0.04 else {
            return CollectionAccent(base: average)
        }
        let total = weights[best]
        return CollectionAccent(base: RGB(r: sums[best].r / total, g: sums[best].g / total, b: sums[best].b / total))
    }
}

@MainActor
final class CollectionAccentStore {
    static let shared = CollectionAccentStore()

    private var accents: [URL: CollectionAccent] = [:]
    private var misses: Set<URL> = []
    private var flights: [URL: Task<CollectionAccent?, Never>] = [:]
    private let limit = 240

    func cached(_ url: URL?) -> CollectionAccent? {
        guard let url else { return nil }
        return accents[url]
    }

    func accent(for url: URL) async -> CollectionAccent? {
        if let known = accents[url] { return known }
        if misses.contains(url) { return nil }
        let task: Task<CollectionAccent?, Never>
        if let running = flights[url] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                guard let image = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail) else { return nil }
                return CollectionAccent.extract(from: image)
            }
            flights[url] = task
        }
        let result = await task.value
        flights[url] = nil
        if accents.count + misses.count >= limit {
            accents.removeAll()
            misses.removeAll()
        }
        if let result {
            accents[url] = result
        } else {
            misses.insert(url)
        }
        return result
    }

    func purge() {
        accents.removeAll()
        misses.removeAll()
    }
}

private struct CollectionAccentKey: EnvironmentKey {
    static let defaultValue: CollectionAccent? = nil
}

extension EnvironmentValues {
    var collectionAccent: CollectionAccent? {
        get { self[CollectionAccentKey.self] }
        set { self[CollectionAccentKey.self] = newValue }
    }
}

private struct CollectionAccentModifier: ViewModifier {
    let url: URL?

    @State private var loaded: CollectionAccent?

    private var accent: CollectionAccent? {
        if let loaded { return loaded }
        return CollectionAccentStore.shared.cached(url)
    }

    func body(content: Content) -> some View {
        let resolved = accent
        content
            .environment(\.collectionAccent, resolved)
            .task(id: url) {
                guard let url else {
                    loaded = nil
                    return
                }
                let resolved = await CollectionAccentStore.shared.accent(for: url)
                guard !Task.isCancelled else { return }
                loaded = resolved
            }
    }
}

private struct CollectionAccentTintModifier: ViewModifier {
    let foreground: Bool

    @Environment(\.collectionAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tint = accent?.tint(for: colorScheme)
        if foreground {
            content.foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
        } else {
            content.tint(tint)
        }
    }
}

extension View {
    func collectionAccent(from url: URL?) -> some View {
        modifier(CollectionAccentModifier(url: url))
    }

    func collectionAccentTint() -> some View {
        modifier(CollectionAccentTintModifier(foreground: false))
    }

    func collectionAccentTinted() -> some View {
        modifier(CollectionAccentTintModifier(foreground: true))
    }
}

struct CollectionAccentPageBackground: View {
    var height: CGFloat = 520

    @Environment(\.collectionAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let accent {
            LinearGradient(
                stops: [
                    .init(color: accent.wash(for: colorScheme), location: 0),
                    .init(color: accent.pageTint(for: colorScheme), location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}
