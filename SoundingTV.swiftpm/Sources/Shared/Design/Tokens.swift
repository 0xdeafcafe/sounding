import SwiftUI
import CoreImage
import UIKit

enum SCAmbient {

    static let backgroundLuminanceCeiling: Double = 0.14
    static let backgroundSaturationCeiling: Double = 0.55
    static let backgroundSaturationFloor: Double = 0.26
    static let secondaryTextOpacity: Double = 0.68
    static let secondaryTextContrastFloor: Double = 4.5
    static let accentContrastFloor: Double = 3.0

    static let fallback = RGB(r: 0.07, g: 0.07, b: 0.10)

    static func background(from raw: Color) -> Color {
        Color(rgb: background(from: components(raw)))
    }

    static func background(from raw: RGB) -> RGB {
        var out = clampedBase(raw)
        var steps = 0
        while steps < 48 {
            let luminanceOK = relativeLuminance(out) <= backgroundLuminanceCeiling
            let textOK = contrastRatio(
                composite(RGB(r: 1, g: 1, b: 1), alpha: secondaryTextOpacity, over: out),
                out
            ) >= secondaryTextContrastFloor
            if luminanceOK && textOK { break }
            out = RGB(r: out.r * 0.92, g: out.g * 0.92, b: out.b * 0.92)
            steps += 1
        }
        return out
    }

    static func accent(from raw: Color, on background: Color) -> Color {
        Color(rgb: accent(from: components(raw), on: components(background)))
    }

    static func accent(from raw: RGB, on background: RGB) -> RGB {
        let hsb = hsb(raw)
        guard hsb.brightness > 0.001 else { return brandAccent }
        var saturation = min(1.0, max(0.55, hsb.saturation * 1.30))
        var brightness = min(0.98, max(0.62, hsb.brightness * 1.25))
        var out = rgb(hue: hsb.hue, saturation: saturation, brightness: brightness)
        var steps = 0
        while contrastRatio(out, background) < accentContrastFloor && steps < 24 {
            brightness = min(1.0, brightness * 1.05)
            saturation = max(0.20, saturation * 0.92)
            out = rgb(hue: hsb.hue, saturation: saturation, brightness: brightness)
            steps += 1
        }
        return contrastRatio(out, background) >= accentContrastFloor ? out : brandAccent
    }

    static let brandAccent = RGB(r: 1.00, g: 0.42, b: 0.10)

    static func scrimAlpha(mean: RGB, layerOpacity: Double, additiveHeadroom: Double = 1.0) -> Double {
        let black = RGB(r: 0, g: 0, b: 0)
        let backdrop = composite(mean, alpha: layerOpacity, over: black)
        let lifted = RGB(
            r: min(1, backdrop.r * additiveHeadroom),
            g: min(1, backdrop.g * additiveHeadroom),
            b: min(1, backdrop.b * additiveHeadroom)
        )
        var alpha: Double = 0
        while alpha < 0.94 {
            let out = composite(black, alpha: alpha, over: lifted)
            let luminanceOK = relativeLuminance(out) <= backgroundLuminanceCeiling
            let textOK = contrastRatio(
                composite(RGB(r: 1, g: 1, b: 1), alpha: secondaryTextOpacity, over: out),
                out
            ) >= secondaryTextContrastFloor
            if luminanceOK && textOK { return alpha }
            alpha += 0.02
        }
        return alpha
    }

    static func legibilityScrim(over backdrop: RGB, textOpacity: Double = 0.6, minimumContrast: Double = 4.5) -> Double {
        let black = RGB(r: 0, g: 0, b: 0)
        let white = RGB(r: 1, g: 1, b: 1)
        var alpha: Double = 0
        while alpha < 0.9 {
            let out = composite(black, alpha: alpha, over: backdrop)
            if contrastRatio(composite(white, alpha: textOpacity, over: out), out) >= minimumContrast { return alpha }
            alpha += 0.02
        }
        return alpha
    }

    static func relativeLuminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            let v = min(1, max(0, v))
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func relativeLuminance(_ c: Color) -> Double { relativeLuminance(components(c)) }

    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func contrastRatio(_ a: Color, _ b: Color) -> Double {
        contrastRatio(components(a), components(b))
    }

    static func composite(_ foreground: RGB, alpha: Double, over background: RGB) -> RGB {
        RGB(
            r: foreground.r * alpha + background.r * (1 - alpha),
            g: foreground.g * alpha + background.g * (1 - alpha),
            b: foreground.b * alpha + background.b * (1 - alpha)
        )
    }

    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
    }

    static func components(_ color: Color) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return fallback }
        return RGB(r: Double(r), g: Double(g), b: Double(b))
    }

    private static func clampedBase(_ raw: RGB) -> RGB {
        let hsb = hsb(raw)
        guard hsb.brightness > 0.001 || hsb.saturation > 0.001 else { return fallback }
        return rgb(
            hue: hsb.hue,
            saturation: min(backgroundSaturationCeiling,
                            max(backgroundSaturationFloor, hsb.saturation * 1.15)),
            brightness: min(0.55, max(0.05, hsb.brightness))
        )
    }

    static func hsb(_ c: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b)
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0 {
            if maxV == c.r        { hue = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == c.g   { hue = (c.b - c.r) / delta + 2 }
            else                  { hue = (c.r - c.g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV > 0 ? delta / maxV : 0, maxV)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = floor(h), f = h - i
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch Int(i) % 6 {
        case 0:  return RGB(r: brightness, g: t, b: p)
        case 1:  return RGB(r: q, g: brightness, b: p)
        case 2:  return RGB(r: p, g: brightness, b: t)
        case 3:  return RGB(r: p, g: q, b: brightness)
        case 4:  return RGB(r: t, g: p, b: brightness)
        default: return RGB(r: brightness, g: p, b: q)
        }
    }
}

extension Color {
    init(rgb: SCAmbient.RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
