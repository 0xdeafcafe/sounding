import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRMatrix: Equatable {
    let size: Int
    let quietZone: Int
    private let modules: [Bool]

    init(size: Int, quietZone: Int = 0, modules: [Bool]) {
        self.size = size
        self.quietZone = quietZone
        self.modules = modules
    }

    subscript(row: Int, col: Int) -> Bool {
        guard row >= 0, row < size, col >= 0, col < size else { return false }
        return modules[row * size + col]
    }
}

extension QRMatrix {
    static let defaultQuietZone = 4

    static func make(from string: String, quietZone: Int = QRMatrix.defaultQuietZone) -> QRMatrix? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H"

        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }

        return read(cgImage, quietZone: quietZone)
    }

    private static func read(_ cgImage: CGImage, quietZone qz: Int) -> QRMatrix? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        func isDark(_ x: Int, _ y: Int) -> Bool { pixels[y * w + x] < 128 }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where isDark(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let dataSize = max(maxX - minX + 1, maxY - minY + 1)
        let size = dataSize + qz * 2
        var modules = [Bool](repeating: false, count: size * size)
        for row in 0..<dataSize {
            for col in 0..<dataSize {
                let x = minX + col, y = minY + row
                guard x <= maxX, y <= maxY, isDark(x, y) else { continue }
                modules[(row + qz) * size + (col + qz)] = true
            }
        }
        return QRMatrix(size: size, quietZone: qz, modules: modules)
    }
}

struct QRLiquidLayout {
    static let bandCount = 8
    static let cornerRadius: CGFloat = 0.5
    static let filletRadius: CGFloat = 0.5
    static let kappa: CGFloat = 0.5523

    let size: Int
    let bands: [Path]
    let combined: Path
    let eyes: [CGRect]
    let center: CGPoint
    let clearRadius: CGFloat

    init(matrix: QRMatrix, reservesLogo: Bool) {
        let n = matrix.size
        let qz = matrix.quietZone
        let dataSize = max(n - qz * 2, 0)
        let mid = CGFloat(n) / 2
        let radius: CGFloat = reservesLogo ? max(2.8, CGFloat(dataSize) * 0.155) : 0

        var building = [Bool](repeating: false, count: n * n)
        for row in 0..<n {
            for col in 0..<n where matrix[row, col] {
                if Self.isFinder(row: row, col: col, quietZone: qz, dataSize: dataSize) { continue }
                if reservesLogo {
                    let dx = CGFloat(col) + 0.5 - mid
                    let dy = CGFloat(row) + 0.5 - mid
                    if (dx * dx + dy * dy).squareRoot() <= radius { continue }
                }
                building[row * n + col] = true
            }
        }
        let grid = building

        func filled(_ row: Int, _ col: Int) -> Bool {
            row >= 0 && row < n && col >= 0 && col < n && grid[row * n + col]
        }

        var bandPaths = [Path](repeating: Path(), count: Self.bandCount)
        let reach = max(mid * 1.2, 1)

        for row in 0..<n {
            for col in 0..<n {
                let dx = CGFloat(col) + 0.5 - mid
                let dy = CGFloat(row) + 0.5 - mid
                let distance = (dx * dx + dy * dy).squareRoot()
                let band = min(Self.bandCount - 1, Int(distance / reach * CGFloat(Self.bandCount)))
                let x = CGFloat(col), y = CGFloat(row)

                if filled(row, col) {
                    let up = filled(row - 1, col), down = filled(row + 1, col)
                    let left = filled(row, col - 1), right = filled(row, col + 1)
                    Self.addModule(
                        to: &bandPaths[band], x: x, y: y,
                        roundTL: !up && !left, roundTR: !up && !right,
                        roundBR: !down && !right, roundBL: !down && !left
                    )
                } else {
                    for dr in [-1, 1] {
                        for dc in [-1, 1] where filled(row + dr, col) && filled(row, col + dc) && filled(row + dr, col + dc) {
                            Self.addFillet(
                                to: &bandPaths[band],
                                corner: CGPoint(x: dc > 0 ? x + 1 : x, y: dr > 0 ? y + 1 : y),
                                towardX: dc > 0 ? -1 : 1,
                                towardY: dr > 0 ? -1 : 1
                            )
                        }
                    }
                }
            }
        }

        var all = Path()
        for path in bandPaths { all.addPath(path) }

        self.size = n
        self.bands = bandPaths
        self.combined = all
        self.center = CGPoint(x: mid, y: mid)
        self.clearRadius = radius
        self.eyes = dataSize >= 21 ? [
            CGRect(x: CGFloat(qz), y: CGFloat(qz), width: 7, height: 7),
            CGRect(x: CGFloat(qz + dataSize - 7), y: CGFloat(qz), width: 7, height: 7),
            CGRect(x: CGFloat(qz), y: CGFloat(qz + dataSize - 7), width: 7, height: 7)
        ] : []
    }

    private static func isFinder(row: Int, col: Int, quietZone qz: Int, dataSize: Int) -> Bool {
        let r = row - qz, c = col - qz
        guard r >= 0, r < dataSize, c >= 0, c < dataSize else { return false }
        return (r < 8 && c < 8)
            || (r < 8 && c >= dataSize - 8)
            || (r >= dataSize - 8 && c < 8)
    }

    private static func addModule(
        to path: inout Path, x: CGFloat, y: CGFloat,
        roundTL: Bool, roundTR: Bool, roundBR: Bool, roundBL: Bool
    ) {
        let r = cornerRadius
        let k = kappa * r

        if roundTL {
            path.move(to: CGPoint(x: x, y: y + r))
            path.addCurve(
                to: CGPoint(x: x + r, y: y),
                control1: CGPoint(x: x, y: y + r - k),
                control2: CGPoint(x: x + r - k, y: y)
            )
        } else {
            path.move(to: CGPoint(x: x, y: y))
        }

        if roundTR {
            path.addLine(to: CGPoint(x: x + 1 - r, y: y))
            path.addCurve(
                to: CGPoint(x: x + 1, y: y + r),
                control1: CGPoint(x: x + 1 - r + k, y: y),
                control2: CGPoint(x: x + 1, y: y + r - k)
            )
        } else {
            path.addLine(to: CGPoint(x: x + 1, y: y))
        }

        if roundBR {
            path.addLine(to: CGPoint(x: x + 1, y: y + 1 - r))
            path.addCurve(
                to: CGPoint(x: x + 1 - r, y: y + 1),
                control1: CGPoint(x: x + 1, y: y + 1 - r + k),
                control2: CGPoint(x: x + 1 - r + k, y: y + 1)
            )
        } else {
            path.addLine(to: CGPoint(x: x + 1, y: y + 1))
        }

        if roundBL {
            path.addLine(to: CGPoint(x: x + r, y: y + 1))
            path.addCurve(
                to: CGPoint(x: x, y: y + 1 - r),
                control1: CGPoint(x: x + r - k, y: y + 1),
                control2: CGPoint(x: x, y: y + 1 - r + k)
            )
        } else {
            path.addLine(to: CGPoint(x: x, y: y + 1))
        }

        path.closeSubpath()
    }

    private static func addFillet(to path: inout Path, corner: CGPoint, towardX sx: CGFloat, towardY sy: CGFloat) {
        let f = filletRadius
        let k = kappa * f
        let onX = CGPoint(x: corner.x + sx * f, y: corner.y)
        let onY = CGPoint(x: corner.x, y: corner.y + sy * f)
        let nearX = CGPoint(x: corner.x + sx * (f - k), y: corner.y)
        let nearY = CGPoint(x: corner.x, y: corner.y + sy * (f - k))

        path.move(to: corner)
        if sx * sy > 0 {
            path.addLine(to: onX)
            path.addCurve(to: onY, control1: nearX, control2: nearY)
        } else {
            path.addLine(to: onY)
            path.addCurve(to: onX, control1: nearY, control2: nearX)
        }
        path.closeSubpath()
    }
}

enum QRLiquidPainter {
    static let ink = Color(red: 0.09, green: 0.06, blue: 0.05)
    static let ember = Color(red: 0.60, green: 0.21, blue: 0.03)

    static func draw(
        _ context: GraphicsContext,
        size: CGSize,
        layout: QRLiquidLayout,
        progress: Double,
        markColor: Color,
        showsMark: Bool
    ) {
        let side = min(size.width, size.height)
        guard side > 0, layout.size > 0 else { return }

        let cell = side / CGFloat(layout.size)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let transform = CGAffineTransform(a: cell, b: 0, c: 0, d: cell, tx: origin.x, ty: origin.y)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: ink, location: 0),
                .init(color: ink, location: 0.38),
                .init(color: ember, location: 1)
            ]),
            startPoint: origin,
            endPoint: CGPoint(x: origin.x + side, y: origin.y + side)
        )
        let settled = progress >= 1

        func layer(_ opacity: Double) -> GraphicsContext {
            var copy = context
            copy.opacity = opacity
            return copy
        }

        if settled {
            context.fill(layout.combined.applying(transform), with: shading)
        } else {
            let last = Double(QRLiquidLayout.bandCount - 1)
            for (index, path) in layout.bands.enumerated() {
                let alpha = ramp(progress, from: 0.06 + 0.52 * Double(index) / last, span: 0.30)
                guard alpha > 0 else { continue }
                layer(alpha).fill(path.applying(transform), with: shading)
            }
        }

        let eyeAlpha = settled ? 1 : ramp(progress, from: 0, span: 0.34)
        if eyeAlpha > 0 {
            let eyeLayer = layer(eyeAlpha)
            for rect in layout.eyes {
                let outer = rect.applying(transform)
                var ring = Path(roundedRect: outer, cornerRadius: cell * 2.2, style: .continuous)
                ring.addPath(Path(roundedRect: outer.insetBy(dx: cell, dy: cell), cornerRadius: cell * 1.35, style: .continuous))
                eyeLayer.fill(ring, with: shading, style: FillStyle(eoFill: true))

                let pupil = outer.insetBy(dx: cell * 2, dy: cell * 2)
                eyeLayer.fill(
                    Path(roundedRect: pupil, cornerRadius: cell * 1.1, style: .continuous),
                    with: .color(ember)
                )
            }
        }

        guard showsMark, layout.clearRadius > 0 else { return }
        let markAlpha = settled ? 1 : ramp(progress, from: 0.55, span: 0.30)
        guard markAlpha > 0 else { return }
        let markLayer = layer(markAlpha)

        let center = CGPoint(x: origin.x + layout.center.x * cell, y: origin.y + layout.center.y * cell)
        let ringRadius = (layout.clearRadius - 0.9) * cell
        if ringRadius > 0 {
            markLayer.stroke(
                Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
                with: .color(markColor.opacity(0.4)),
                lineWidth: cell * 0.12
            )
        }

        let grow = settled ? 1 : 0.7 + 0.3 * markAlpha
        let markSide = max((layout.clearRadius - 1.2) / 0.45, 1) * cell * grow
        let markRect = CGRect(x: center.x - markSide / 2, y: center.y - markSide / 2, width: markSide, height: markSide)
        markLayer.fill(SoundingMark().path(in: markRect), with: .color(markColor))
    }

    private static func ramp(_ progress: Double, from: Double, span: Double) -> Double {
        let t = min(1, max(0, (progress - from) / span))
        return t * t * (3 - 2 * t)
    }
}

struct QRCodeView: View {
    let matrix: QRMatrix
    var markColor: Color = .scAccent
    var showsMark: Bool = true
    var animatesIn: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var settled = false

    private static let duration: TimeInterval = 1.2

    private var animates: Bool { animatesIn && !reduceMotion }

    var body: some View {
        let layout = QRLiquidLayout(matrix: matrix, reservesLogo: showsMark)
        return content(layout)
            .task(id: matrix) { await reveal() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ layout: QRLiquidLayout) -> some View {
        if animates, !settled {
            TimelineView(.animation) { timeline in
                painter(layout, progress: progress(at: timeline.date))
            }
        } else {
            painter(layout, progress: 1)
        }
    }

    private func painter(_ layout: QRLiquidLayout, progress: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            QRLiquidPainter.draw(
                context, size: size, layout: layout,
                progress: progress, markColor: markColor, showsMark: showsMark
            )
        }
    }

    private func progress(at date: Date) -> Double {
        guard let startedAt else { return 0 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / Self.duration))
    }

    private func reveal() async {
        guard animates else { return }
        startedAt = Date()
        settled = false
        try? await Task.sleep(for: .seconds(Self.duration + 0.05))
        if !Task.isCancelled { settled = true }
    }
}

struct SoundingMark: Shape {
    var barCount: Int = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = max(barCount, 3)
        let heights = symmetricHeights(count: n)
        let span = rect.width * 0.80
        let barW = span / (CGFloat(n) * 1.45)
        let gap = n > 1 ? (span - barW * CGFloat(n)) / CGFloat(n - 1) : 0
        let x0 = rect.midX - span / 2

        for i in 0..<n {
            let barH = max(heights[i] * rect.height * 0.86, rect.height * 0.18)
            let x = x0 + CGFloat(i) * (barW + gap)
            path.addRoundedRect(
                in: CGRect(x: x, y: rect.midY - barH / 2, width: barW, height: barH),
                cornerSize: CGSize(width: barW / 2, height: barW / 2)
            )
        }
        return path
    }

    private func symmetricHeights(count: Int) -> [CGFloat] {
        let mid = CGFloat(count - 1) / 2
        return (0..<count).map { i in
            let d = mid == 0 ? 0 : abs(CGFloat(i) - mid) / mid
            return 1.0 - d * 0.62
        }
    }
}
