import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum SetLearningPlot {
    static func render(_ t: SetLearningTransition, envelope: SetLearningEnvelope, bars: SetLearningBars, title: String, to url: URL) {
        let width = 1400, height = 560
        let left = 60.0, right = 1380.0, top = 70.0, bottom = 500.0
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let t0 = envelope.times.first, let t1 = envelope.times.last, t1 > t0 else { return }
        let H = Double(height)
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
        func x(_ s: Double) -> Double { left + (s - t0) / (t1 - t0) * (right - left) }
        let all = envelope.low + envelope.mid + envelope.high
        let ceiling = (all.max() ?? 0) + 2
        let floor = ceiling - 48
        func y(_ db: Double) -> Double { bottom - (min(ceiling, max(floor, db)) - floor) / (ceiling - floor) * (bottom - top) }
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: CGColor, _ w: Double = 1, dash: Bool = false) {
            ctx.setStrokeColor(c)
            ctx.setLineWidth(w)
            ctx.setLineDash(phase: 0, lengths: dash ? [6, 4] : [])
            ctx.move(to: CGPoint(x: x0, y: H - y0))
            ctx.addLine(to: CGPoint(x: x1, y: H - y1))
            ctx.strokePath()
        }
        func text(_ s: String, _ x0: Double, _ top: Double, size: Double = 13, color: CGColor = rgb(0.8, 0.8, 0.82)) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            ctx.textPosition = CGPoint(x: x0, y: H - top - size)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        ctx.setFillColor(rgb(0.07, 0.07, 0.08))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bx0 = x(t.blendStartSeconds), bx1 = max(x(t.blendEndSeconds), bx0 + 2)
        ctx.setFillColor(rgb(1, 0.95, 0.6, 0.08))
        ctx.fill(CGRect(x: bx0, y: H - bottom, width: bx1 - bx0, height: bottom - top))
        for b in 0..<bars.count where bars.starts[b] >= t0 && bars.starts[b] <= t1 {
            let phrase = SetLearning.mod(b - t.incomingPhraseOffset, 8) == 0
            line(x(bars.starts[b]), top, x(bars.starts[b]), bottom, rgb(1, 1, 1, phrase ? 0.3 : 0.07), phrase ? 1.5 : 1)
        }
        for db in stride(from: floor, through: ceiling, by: 12) {
            line(left, y(db), right, y(db), rgb(1, 1, 1, 0.05))
            text(String(format: "%.0f", db - ceiling), 8, y(db) - 7, size: 10, color: rgb(0.5, 0.5, 0.5))
        }
        func curve(_ v: [Double], _ c: CGColor) {
            let s = SetLearning.smooth(v, 2)
            ctx.setStrokeColor(c)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [])
            for (i, value) in s.enumerated() {
                let p = CGPoint(x: x(envelope.times[i]), y: H - y(value))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        curve(envelope.high, rgb(0.45, 0.75, 1))
        curve(envelope.mid, rgb(0.6, 0.9, 0.55))
        curve(envelope.low, rgb(1, 0.45, 0.35))
        if let cue = t.cueSeconds, cue >= t0, cue <= t1 { line(x(cue), top, x(cue), bottom, rgb(1, 1, 1, 0.8), 1.5, dash: true) }
        if let swap = t.bassSwapBar {
            let bar = SetLearning.barIndex(t.blendStartSeconds, bars) + Int(swap)
            if bar < bars.count { line(x(bars.starts[bar]), top, x(bars.starts[bar]), bottom, rgb(1, 0.3, 0.3, 0.9), 2.5) }
        }
        text(title, 12, 10, size: 16, color: rgb(0.95, 0.95, 0.95))
        let summary = "\(t.move)  ·  \(t.blendBars) bars  ·  bass \(t.bassSwapMethod)\(t.bassSwapBar.map { " @ bar \(Int($0))" } ?? "")  ·  filter \(t.filter)  ·  loop \(t.loopBars)  ·  \(t.exitSection) → \(t.entrySection)  ·  \(String(format: "%+.1f", t.energyStepDecibels ?? 0)) dB  ·  \(String(format: "%.1f→%.1f", t.bpmOut ?? 0, t.bpmIn ?? 0)) BPM  ·  \(t.keyOut ?? "?")→\(t.keyIn ?? "?")"
        text(summary, 12, 36, size: 13)
        text("low", right - 150, bottom + 20, size: 12, color: rgb(1, 0.45, 0.35))
        text("mid", right - 110, bottom + 20, size: 12, color: rgb(0.6, 0.9, 0.55))
        text("high", right - 70, bottom + 20, size: 12, color: rgb(0.45, 0.75, 1))
        text("shaded: measured blend · red: bass swap · dashed: tracklist cue · bright lines: incoming 8-bar phrase", left, bottom + 20, size: 12, color: rgb(0.55, 0.55, 0.58))
        for s in stride(from: (t0 / 30).rounded(.up) * 30, through: t1, by: 30) {
            text(String(format: "%d:%02d", Int(s) / 60, Int(s) % 60), x(s) - 14, bottom + 4, size: 10, color: rgb(0.55, 0.55, 0.58))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
