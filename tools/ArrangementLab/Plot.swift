import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func roleColor(_ role: TrackArrangement.Role) -> CGColor {
    switch role {
    case .introDrums: return rgb(0.35, 0.65, 0.95)
    case .introQuiet: return rgb(0.25, 0.35, 0.55)
    case .groove: return rgb(0.35, 0.75, 0.45)
    case .breakdown: return rgb(0.55, 0.45, 0.75)
    case .build: return rgb(0.95, 0.75, 0.3)
    case .dropOpening: return rgb(0.95, 0.3, 0.3)
    case .dropGroove: return rgb(0.85, 0.55, 0.45)
    case .vocalHook: return rgb(0.95, 0.4, 0.85)
    case .outroUsable: return rgb(0.3, 0.6, 0.7)
    case .outroDead: return rgb(0.3, 0.3, 0.35)
    }
}

func plot(_ track: LabTrack, arrangement: TrackArrangement?, aiArrangement: TrackArrangement?, annotation: Annotation?, to url: URL) {
    let r = track.result
    guard let profile = r.bars, let bands = profile.bands, r.downbeats.count == profile.level.count else { return }
    let count = profile.level.count
    let width = 1800, height = 820
    let left = 60.0, right = 1780.0
    let H = Double(height)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0.07, 0.07, 0.08))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let barWidth = (right - left) / Double(count)
    func x(_ bar: Double) -> Double { left + bar * barWidth }
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
    func text(_ s: String, _ x0: Double, _ top: Double, size: Double = 12, color: CGColor = rgb(0.75, 0.75, 0.78)) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let ln = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: x0, y: H - top - size)
        CTLineDraw(ln, ctx)
    }

    let measured = profile.level.filter { $0 > -89 }
    let body = TrackArrangement.percentile(measured, 0.75)
    let loud = (0..<count).filter { profile.level[$0] >= body - 3 }
    func bandRel(_ k: Int) -> [Float] {
        let v = (0..<count).map { bands[$0 * 4 + k] * 4.343 }
        let typical = TrackArrangement.percentile(loud.map { v[$0] }, 0.5)
        return v.map { $0 - typical }
    }
    let rel = profile.level.map { $0 > -89 ? $0 - body : -40 }

    text("\(track.id)  \(track.title)", 12, 8, size: 15, color: rgb(0.95, 0.95, 0.97))
    text(String(format: "%.1f BPM · %d bars · grid conf %.2f · phrase offset %d · %.0f s", r.bpm ?? 0, count, r.confidence, r.phraseOffsetBars, r.analysedSeconds), 12, 28)

    let topA = 60.0, hA = 330.0
    func yA(_ db: Float) -> Double { topA + Double(6 - max(-36, min(6, db))) / 42 * hA }
    for db in stride(from: 6, through: -36, by: -6) {
        line(left, yA(Float(db)), right, yA(Float(db)), rgb(1, 1, 1, db == 0 ? 0.25 : 0.08))
        text("\(db)", 20, yA(Float(db)) - 6, size: 10)
    }
    let offset = ((r.phraseOffsetBars % 8) + 8) % 8
    for b in 0..<count {
        let phrase = (b - offset) % 8 == 0
        if (b - offset) % 4 == 0 { line(x(Double(b)), topA, x(Double(b)), 700, rgb(1, 1, 1, phrase ? 0.16 : 0.05)) }
        if phrase { text("\(b)", x(Double(b)) + 2, 700, size: 9, color: rgb(0.6, 0.6, 0.65)) }
    }
    var s = 0.0
    while s < r.analysedSeconds {
        if let b = r.downbeats.firstIndex(where: { $0 >= s }) { text("\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))", x(Double(b)), 712, size: 9, color: rgb(0.45, 0.45, 0.5)) }
        s += 30
    }
    func curve(_ values: [Float], _ color: CGColor, _ w: Double = 1.6) {
        for b in 1..<count { line(x(Double(b - 1) + 0.5), yA(values[b - 1]), x(Double(b) + 0.5), yA(values[b]), color, w) }
    }
    curve(bandRel(1), rgb(0.55, 0.85, 0.5, 0.9))
    curve(bandRel(2), rgb(0.95, 0.85, 0.4, 0.7), 1.2)
    curve(bandRel(3), rgb(0.5, 0.75, 1, 0.9))
    curve(bandRel(0), rgb(1, 0.45, 0.35), 2.2)
    curve(rel, rgb(0.95, 0.95, 0.95), 2)
    text("level (white) · low 30-150 Hz (red) · low-mid (green) · mid 1-5 kHz (yellow) · high (blue), dB vs body", left, topA - 16, size: 10)

    let topB = 400.0, hB = 70.0
    text("onset density (yellow bars) · loop8 repetition (grey)", left, topB - 14, size: 10)
    for b in 0..<count {
        let d = Double(profile.density[b])
        rect(x(Double(b)) + 0.5, topB + hB * (1 - d), max(1, barWidth - 1), hB * d, rgb(0.9, 0.8, 0.3, 0.75))
    }
    for b in 1..<count {
        line(x(Double(b - 1) + 0.5), topB + hB * (1 - Double(profile.loop8[b - 1])), x(Double(b) + 0.5), topB + hB * (1 - Double(profile.loop8[b])), rgb(0.8, 0.8, 0.8, 0.7))
    }

    let topC = 490.0, hC = 60.0
    text("vocal: SoundAnalysis curve max per bar (purple) · AI vocal stem (pink tick row)", left, topC - 14, size: 10)
    if let vc = r.vocalCurve {
        for b in 0..<count {
            let lo = r.downbeats[b], hi = b + 1 < count ? r.downbeats[b + 1] : lo + 2
            let i0 = Int(lo / 0.5), i1 = max(i0 + 1, Int(hi / 0.5))
            guard i0 < vc.count else { continue }
            let v = Double(vc[i0..<min(vc.count, i1)].max() ?? 0)
            rect(x(Double(b)) + 0.5, topC + hC * (1 - v), max(1, barWidth - 1), hC * v, rgb(0.7, 0.45, 1, 0.8))
        }
        line(left, topC + hC * 0.6, right, topC + hC * 0.6, rgb(1, 1, 1, 0.15))
    } else {
        text("no vocal evidence", left, topC + 20, size: 11)
    }
    if let stems = track.ai {
        for span in stems.vocals {
            guard let b0 = r.downbeats.lastIndex(where: { $0 <= span.start }) ?? (span.start < (r.downbeats.first ?? 0) ? 0 : nil) else { continue }
            let b1 = r.downbeats.lastIndex(where: { $0 <= span.end }) ?? b0
            rect(x(Double(b0)), topC + hC + 2, max(2, x(Double(b1 + 1)) - x(Double(b0))), 6, rgb(1, 0.4, 0.8, 0.9))
        }
    }

    func strip(_ intervals: [(Range<Int>, TrackArrangement.Role, Float)], top: Double, label: String) {
        text(label, 4, top + 4, size: 10)
        for (range, role, c) in intervals {
            rect(x(Double(range.lowerBound)), top, x(Double(range.upperBound)) - x(Double(range.lowerBound)), 22, roleColor(role))
            rect(x(Double(range.lowerBound)), top + 22, (x(Double(range.upperBound)) - x(Double(range.lowerBound))) * Double(c), 3, rgb(1, 1, 1, 0.7))
            if x(Double(range.upperBound)) - x(Double(range.lowerBound)) > 40 { text(role.rawValue, x(Double(range.lowerBound)) + 3, top + 5, size: 10, color: rgb(0.05, 0.05, 0.05)) }
        }
    }
    var top = 575.0
    if let annotation {
        strip(annotation.intervals.map { ($0.bars, $0.role, 1) }, top: top, label: "truth")
        top += 30
    }
    if let arrangement {
        strip(arrangement.intervals.map { ($0.bars, $0.role, $0.confidence) }, top: top, label: "new")
        for boundary in arrangement.boundaries where boundary.isSection {
            line(x(Double(boundary.bar)), top - 4, x(Double(boundary.bar)), top + 26, rgb(1, 1, 1, Double(boundary.confidence)), 2)
        }
        top += 30
    }
    if let aiArrangement {
        strip(aiArrangement.intervals.map { ($0.bars, $0.role, $0.confidence) }, top: top, label: "AI")
        top += 30
    }
    if arrangement != nil {
        for section in r.sectionStarts {
            if let b = r.downbeats.firstIndex(where: { abs($0 - section) < 0.1 }) { rect(x(Double(b)) - 2, topA - 6, 4, 6, rgb(1, 1, 1, 0.8)) }
        }
    }
    let legend = TrackArrangement.Role.allCases
    var lx = left
    for role in legend {
        rect(lx, 760, 12, 12, roleColor(role))
        text(role.rawValue, lx + 16, 760, size: 10)
        lx += 120
    }

    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
