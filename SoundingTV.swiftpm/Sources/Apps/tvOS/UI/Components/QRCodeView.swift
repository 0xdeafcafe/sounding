import SwiftUI

struct QRCodeView: View {
    let matrix: QRMatrix
    var moduleColor: Color = Color(white: 0.07)
    var markColor: Color = .scAccent
    var showsMark: Bool = true

    private let markWell: CGFloat = 0.30

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let n = CGFloat(matrix.size)
            let cell = size.width / n
            let dot = cell * 0.88
            let qz = matrix.quietZone
            let dataSize = matrix.size - qz * 2

            let wellSpan = Int((CGFloat(dataSize) * markWell).rounded())
            let wellLo = (matrix.size - wellSpan) / 2
            let wellHi = wellLo + wellSpan

            var dots = Path()
            for row in 0..<matrix.size {
                for col in 0..<matrix.size {
                    guard matrix[row, col], !isFinder(row: row, col: col) else { continue }
                    if showsMark, row >= wellLo, row < wellHi, col >= wellLo, col < wellHi {
                        continue
                    }
                    let cx = (CGFloat(col) + 0.5) * cell
                    let cy = (CGFloat(row) + 0.5) * cell
                    dots.addEllipse(in: CGRect(
                        x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot
                    ))
                }
            }
            context.fill(dots, with: .color(moduleColor))

            let eyeOrigins = [
                (fr: 0, fc: 0),
                (fr: 0, fc: dataSize - 7),
                (fr: dataSize - 7, fc: 0)
            ]
            for eye in eyeOrigins {
                let origin = CGPoint(x: CGFloat(eye.fc + qz) * cell, y: CGFloat(eye.fr + qz) * cell)
                let outer = CGRect(origin: origin, size: CGSize(width: cell * 7, height: cell * 7))

                var ring = Path(roundedRect: outer, cornerRadius: cell * 2.1, style: .continuous)
                let ringInner = outer.insetBy(dx: cell, dy: cell)
                ring.addPath(Path(roundedRect: ringInner, cornerRadius: cell * 1.3, style: .continuous))
                context.fill(ring, with: .color(moduleColor), style: FillStyle(eoFill: true))

                let core = outer.insetBy(dx: cell * 2, dy: cell * 2)
                context.fill(
                    Path(roundedRect: core, cornerRadius: cell * 0.95, style: .continuous),
                    with: .color(moduleColor)
                )
            }

            if showsMark {
                let side = size.width * markWell * 0.78
                let markRect = CGRect(
                    x: (size.width - side) / 2,
                    y: (size.height - side) / 2,
                    width: side, height: side
                )
                context.fill(SoundingMark().path(in: markRect), with: .color(markColor))
            }
        }
        .accessibilityHidden(true)
    }

    private func isFinder(row: Int, col: Int) -> Bool {
        let qz = matrix.quietZone
        let dataSize = matrix.size - qz * 2
        let r = row - qz, c = col - qz
        guard r >= 0, r < dataSize, c >= 0, c < dataSize else { return false }
        return (r < 8 && c < 8)
            || (r < 8 && c >= dataSize - 8)
            || (r >= dataSize - 8 && c < 8)
    }
}
