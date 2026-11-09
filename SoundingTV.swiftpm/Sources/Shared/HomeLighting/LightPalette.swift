import CoreGraphics
import Foundation

enum LightPalette {
    static let sampleSide = 24
    private static let binCount = 24
    private static let minimumSeparation: Double = 40

    static func colors(from image: CGImage, maximum: Int = 3) -> [LightColor] {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return colors(rgba: pixels, width: side, height: side, maximum: maximum)
    }

    static func colors(rgba: [UInt8], width: Int, height: Int, maximum: Int = 3) -> [LightColor] {
        let count = width * height
        guard count > 0, rgba.count >= count * 4, maximum > 0 else { return [] }

        var weight = [Double](repeating: 0, count: binCount)
        var cosine = [Double](repeating: 0, count: binCount)
        var sine = [Double](repeating: 0, count: binCount)
        var saturation = [Double](repeating: 0, count: binCount)
        var colourful = 0

        for index in 0..<count {
            let r = Double(rgba[index * 4]) / 255
            let g = Double(rgba[index * 4 + 1]) / 255
            let b = Double(rgba[index * 4 + 2]) / 255
            let (h, s, v) = hsv(r, g, b)
            guard v >= 0.12, s >= 0.18 else { continue }
            colourful += 1
            let w = s * v
            let bin = min(binCount - 1, Int(h / (360 / Double(binCount))))
            let radians = h * .pi / 180
            weight[bin] += w
            cosine[bin] += cos(radians) * w
            sine[bin] += sin(radians) * w
            saturation[bin] += s * w
        }

        guard Double(colourful) / Double(count) >= 0.02 else { return [] }

        func smoothed(_ bin: Int) -> Double {
            weight[bin] + 0.5 * weight[(bin + 1) % binCount] + 0.5 * weight[(bin + binCount - 1) % binCount]
        }

        let ranked = (0..<binCount).sorted { smoothed($0) > smoothed($1) }
        guard let top = ranked.first, smoothed(top) > 0 else { return [] }
        let floor = smoothed(top) * 0.12

        var chosen: [(color: LightColor, weight: Double)] = []
        for bin in ranked {
            guard chosen.count < maximum else { break }
            let w = smoothed(bin)
            guard w > 0, w >= floor else { break }
            let neighbours = [(bin + binCount - 1) % binCount, bin, (bin + 1) % binCount]
            let c = neighbours.reduce(0) { $0 + cosine[$1] }
            let s = neighbours.reduce(0) { $0 + sine[$1] }
            let total = neighbours.reduce(0) { $0 + weight[$1] }
            guard total > 0 else { continue }
            var hue = atan2(s, c) * 180 / .pi
            if hue < 0 { hue += 360 }
            let meanSaturation = neighbours.reduce(0) { $0 + saturation[$1] } / total
            let candidate = LightColor(hue: hue, saturation: max(0.6, min(1, meanSaturation * 1.25)))
            guard chosen.allSatisfy({ LightState.hueDistance($0.color.hue, candidate.hue) >= minimumSeparation }) else { continue }
            chosen.append((candidate, w))
        }
        return chosen.map(\.color)
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        guard maxC > 0 else { return (0, 0, 0) }
        let s = delta / maxC
        guard delta > 0 else { return (0, 0, maxC) }
        var h: Double
        if maxC == r {
            h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = 60 * ((b - r) / delta + 2)
        } else {
            h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, maxC)
    }
}
