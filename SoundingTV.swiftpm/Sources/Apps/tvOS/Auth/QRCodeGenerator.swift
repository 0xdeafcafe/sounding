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

enum QRCodeGenerator {

    private static let linkBaseURL = "https://sounding.forbes.red/auth/"

    static func matrix(for credentials: SessionCredentials) -> QRMatrix? {
        matrix(for: buildPairingURL(for: credentials))
    }

    static func matrix(for string: String) -> QRMatrix? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H"

        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }

        return decode(cgImage)
    }

    private static let quietZoneModules = 4

    private static func decode(_ cgImage: CGImage) -> QRMatrix? {
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
        let qz = quietZoneModules
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

    static func buildPairingURL(for credentials: SessionCredentials) -> String {
        var components = URLComponents(string: linkBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "session", value: credentials.sessionId),
            URLQueryItem(name: "secret", value: credentials.secretBase64URL)
        ]
        let urlString = components.url!.absoluteString
        #if DEBUG
        NSLog("[QRCodeGenerator] PairingURL session=%@", credentials.sessionId)
        #endif
        return urlString
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
