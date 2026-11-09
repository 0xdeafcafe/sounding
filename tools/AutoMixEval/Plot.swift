import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func plotReview(_ a: Analysis, to url: URL) {
    let width = 1600, height = 900
    let left = 70.0, right = 1590.0
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let H = Double(height)
    ctx.setFillColor(rgb(0.07, 0.07, 0.08))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let n = a.mixMono.count
    let seconds = Double(n) / sr
    let plotWidth = right - left
    func x(_ t: Double) -> Double { left + t / seconds * plotWidth }
    func rect(_ x0: Double, _ top: Double, _ w: Double, _ h: Double, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: x0, y: H - top - h, width: w, height: h))
    }
    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: CGColor, _ w: Double = 1) {
        ctx.setStrokeColor(c)
        ctx.setLineWidth(w)
        ctx.move(to: CGPoint(x: x0, y: H - y0))
        ctx.addLine(to: CGPoint(x: x1, y: H - y1))
        ctx.strokePath()
    }
    func text(_ s: String, _ x0: Double, _ top: Double, size: Double = 13, color: CGColor = rgb(0.75, 0.75, 0.78)) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let ln = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: x0, y: H - top - size)
        CTLineDraw(ln, ctx)
    }
    let columns = Int(plotWidth)
    func peaks(_ s: [Float]) -> [Float] {
        (0..<columns).map { c in
            let lo = c * s.count / columns, hi = max(lo + 1, (c + 1) * s.count / columns)
            var m: Float = 0
            for i in lo..<min(hi, s.count) { m = max(m, abs(s[i])) }
            return m
        }
    }
    func rmsCurve(_ s: [Float], window: Double) -> [Double] {
        let w = Int(window * sr)
        return (0..<columns).map { c in
            let center = (c * s.count + s.count / 2) / columns
            return rmsDB(s, center - w / 2, center + w / 2)
        }
    }

    let mixX0 = x(a.metrics.mixStartInClip), mixX1 = max(x(a.metrics.mixEndInClip), mixX0 + 2)
    rect(mixX0, 24, mixX1 - mixX0, 716, rgb(1, 0.95, 0.6, 0.07))

    for s in stride(from: -40.0, through: 80.0, by: 2.0) {
        let t = a.metrics.mixStartInClip + s
        guard t >= 0, t <= seconds else { continue }
        let major = Int(s) % 10 == 0
        line(x(t), 16, x(t), 24, rgb(0.6, 0.6, 0.6), major ? 1.5 : 0.7)
        if major || Int(s) % 4 == 0 { text(String(format: "%+.0f", s), x(t) - 10, 0, size: 11) }
    }
    text("sec", 4, 2, size: 10, color: rgb(0.5, 0.5, 0.5))

    func deckLane(top: Double, height: Double, wet: [Float], dry: [Float], colour: CGColor, dim: CGColor, downbeats: [Double], phrases: [Double], vocals: [ClosedRange<Double>], caption: String) {
        let mid = top + height / 2
        for t in downbeats { line(x(t), top, x(t), top + height, rgb(1, 1, 1, 0.10)) }
        for t in phrases { line(x(t), top, x(t), top + height, rgb(1, 1, 1, 0.35), 1.5) }
        let dp = peaks(dry), wp = peaks(wet)
        for c in 0..<columns {
            let xc = left + Double(c)
            if dp[c] > 0 { line(xc, mid - Double(dp[c]) * height / 2, xc, mid + Double(dp[c]) * height / 2, dim) }
        }
        for c in 0..<columns {
            let xc = left + Double(c)
            line(xc, mid - Double(wp[c]) * height / 2, xc, mid + Double(wp[c]) * height / 2, colour)
        }
        text(caption, 6, top + 4, size: 14, color: colour)
        let vt = top + height + 3
        rect(left, vt, plotWidth, 10, rgb(0.15, 0.15, 0.17))
        let audible = rmsCurve(wet, window: 0.2)
        for c in 0..<columns {
            let t = Double(c) / Double(columns) * seconds
            guard vocals.contains(where: { $0.contains(t) }) else { continue }
            rect(left + Double(c), vt, 1, 10, audible[c] > -30 ? rgb(0.85, 0.35, 0.95) : rgb(0.85, 0.35, 0.95, 0.3))
        }
        text("vox", 6, vt - 2, size: 10, color: rgb(0.85, 0.35, 0.95))
    }
    deckLane(top: 30, height: 140, wet: a.outStem, dry: a.outDry, colour: rgb(0.95, 0.62, 0.25), dim: rgb(0.95, 0.62, 0.25, 0.22), downbeats: a.outDownbeats, phrases: a.outPhrases, vocals: a.outVocals, caption: "OUT")
    deckLane(top: 192, height: 140, wet: a.inStem, dry: a.inDry, colour: rgb(0.3, 0.8, 0.95), dim: rgb(0.3, 0.8, 0.95, 0.22), downbeats: a.inDownbeats, phrases: a.inPhrases, vocals: a.inVocals, caption: "IN")

    let mixTop = 356.0, mixHeight = 210.0
    let mid = mixTop + mixHeight / 2
    let b = bands(a.mixMono, columns: columns)
    func p95(_ v: [Float]) -> Float { let s = v.sorted(); return max(1e-9, s[min(s.count - 1, Int(Double(s.count) * 0.95))]) }
    let lo95 = p95(b.map { $0.0 }), mi95 = p95(b.map { $0.1 }), hi95 = p95(b.map { $0.2 })
    let mp = peaks(a.mixMono)
    for c in 0..<columns {
        let r = CGFloat(min(1, b[c].0 / lo95)), g = CGFloat(min(1, b[c].1 / mi95)), bl = CGFloat(min(1, b[c].2 / hi95))
        let xc = left + Double(c)
        let full = Double(mp[c]) * mixHeight / 2
        line(xc, mid - full, xc, mid + full, rgb(0.15 + 0.85 * r, 0.15 + 0.85 * g, 0.15 + 0.85 * bl))
        let low = full * Double(r) * 0.5
        line(xc, mid - low, xc, mid + low, rgb(1, 0.15, 0.1))
    }
    for t in a.outDownbeats { line(x(t), mixTop, x(t), mixTop + 8, rgb(0.95, 0.62, 0.25), 1) }
    for t in a.inDownbeats { line(x(t), mixTop + mixHeight - 8, x(t), mixTop + mixHeight, rgb(0.3, 0.8, 0.95), 1) }
    for t in a.outPhrases { line(x(t), mixTop, x(t), mixTop + 16, rgb(0.95, 0.62, 0.25), 2) }
    for t in a.inPhrases { line(x(t), mixTop + mixHeight - 16, x(t), mixTop + mixHeight, rgb(0.3, 0.8, 0.95), 2) }
    text("MIX", 6, mixTop + 4, size: 14, color: rgb(0.95, 0.95, 0.95))
    text("low", 6, mixTop + 26, size: 10, color: rgb(1, 0.3, 0.25))
    text("mid", 6, mixTop + 38, size: 10, color: rgb(0.3, 1, 0.3))
    text("high", 6, mixTop + 50, size: 10, color: rgb(0.4, 0.5, 1))

    let levelTop = 576.0, levelHeight = 150.0
    rect(left, levelTop, plotWidth, levelHeight, rgb(0.11, 0.11, 0.12))
    func yDB(_ d: Double) -> Double { levelTop + (1 - (max(-42, min(0, d)) + 42) / 42) * levelHeight }
    for d in stride(from: -36.0, through: -6.0, by: 6.0) {
        line(left, yDB(d), right, yDB(d), rgb(1, 1, 1, 0.07))
        text(String(format: "%.0f", d), 40, yDB(d) - 6, size: 9, color: rgb(0.5, 0.5, 0.5))
    }
    func curve(_ v: [Double], _ c: CGColor, _ w: Double) {
        ctx.setStrokeColor(c)
        ctx.setLineWidth(w)
        for (k, d) in v.enumerated() {
            let p = CGPoint(x: left + Double(k), y: H - yDB(d))
            if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }
    curve(rmsCurve(a.outLow, window: 0.3), rgb(0.95, 0.62, 0.25, 0.85), 1.2)
    curve(rmsCurve(a.inLow, window: 0.3), rgb(0.3, 0.8, 0.95, 0.85), 1.2)
    curve(rmsCurve(a.mixMono, window: 0.4), rgb(1, 1, 1), 1.8)
    curve(rmsCurve(a.mixMono, window: 3), rgb(1, 0.9, 0.3), 2.2)
    text("LEVEL", 6, levelTop + 4, size: 13)
    text("dB", 6, levelTop + 20, size: 10, color: rgb(0.5, 0.5, 0.5))

    let zoomTop = 740.0, zoomHeight = 150.0
    let overlapStart = a.metrics.mixStartInClip, overlapEnd = a.metrics.mixEndInClip
    let zoomSeconds = 1.0
    let centres: [Double] = overlapEnd - overlapStart > 3
        ? [overlapStart + (overlapEnd - overlapStart) * 0.3, overlapStart + (overlapEnd - overlapStart) * 0.7]
        : [overlapStart - 0.6, overlapStart + 0.6]
    let panelWidth = (plotWidth - 20) / 2
    for (p, centre) in centres.enumerated() {
        let px = left + Double(p) * (panelWidth + 20)
        rect(px, zoomTop, panelWidth, zoomHeight, rgb(0.11, 0.11, 0.12))
        if let beat = a.outDownbeats.first {
            var g = beat
            while g > centre - zoomSeconds { g -= a.beatPeriod }
            while g < centre + zoomSeconds / 2 {
                if g >= centre - zoomSeconds / 2 {
                    let gx = px + (g - (centre - zoomSeconds / 2)) / zoomSeconds * panelWidth
                    line(gx, zoomTop, gx, zoomTop + zoomHeight, rgb(1, 1, 1, 0.3), 1)
                }
                g += a.beatPeriod
            }
        }
        let s0 = Int((centre - zoomSeconds / 2) * sr)
        let cols = Int(panelWidth)
        let perCol = Int(zoomSeconds * sr) / cols
        func env(_ s: [Float], _ c: CGColor, up: Bool) {
            var top: Float = 1e-6
            for i in max(0, s0)..<min(s.count, s0 + cols * perCol) { top = max(top, abs(s[i])) }
            for k in 0..<cols {
                var m: Float = 0
                let lo = s0 + k * perCol
                for i in max(0, lo)..<min(s.count, lo + perCol) { m = max(m, abs(s[i])) }
                let h = Double(m / max(top, 0.05)) * (zoomHeight / 2 - 4)
                let xc = px + Double(k)
                let base = zoomTop + zoomHeight / 2
                line(xc, base, xc, up ? base - h : base + h, c)
            }
        }
        env(a.outStem, rgb(0.95, 0.62, 0.25), up: true)
        env(a.inStem, rgb(0.3, 0.8, 0.95), up: false)
        let zx = x(centre)
        line(zx - 3, zoomTop - 6, zx + 3, zoomTop - 6, rgb(1, 1, 1, 0.8), 2)
        text(String(format: "ZOOM %+.1f s", centre - a.metrics.mixStartInClip), px + 4, zoomTop + 4, size: 11)
        text("out", px + 4, zoomTop + 20, size: 10, color: rgb(0.95, 0.62, 0.25))
        text("in", px + 4, zoomTop + zoomHeight - 16, size: 10, color: rgb(0.3, 0.8, 0.95))
    }

    line(mixX0, 24, mixX0, 740, rgb(1, 0.9, 0.3, 0.9), 1.5)
    line(mixX1, 24, mixX1, 740, rgb(1, 0.9, 0.3, 0.9), 1.5)

    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
