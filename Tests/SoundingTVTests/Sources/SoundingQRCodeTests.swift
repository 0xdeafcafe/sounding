import CoreImage
import SwiftUI
import XCTest
@testable import SoundingTV

@MainActor
final class SoundingQRCodeTests: XCTestCase {
    private let pairingURL = "https://sounding.forbes.red/auth/?session=6f1c2a9e-4b7d-4c1e-9a53-0d8e7b2f41aa&secret=Zk3_vT9xQp2LmN8rYd4HfWb6CsAeJu1GoXhVt7KiRnE"

    private func render(_ string: String, markColor: Color = .scAccent, side: CGFloat = 640) throws -> CGImage {
        let matrix = try XCTUnwrap(QRMatrix.make(from: string))
        let content = QRCodeView(matrix: matrix, markColor: markColor, animatesIn: false)
            .frame(width: side, height: side)
            .background(Color.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    func testPairingLinkSurvivesTheStyledRender() throws {
        let image = try render(pairingURL)
        XCTAssertEqual(decode(image), [pairingURL])
    }

    func testShortLinkSurvivesTheStyledRender() throws {
        let link = "https://github.com/0xdeafcafe/sounding-tv"
        let image = try render(link)
        XCTAssertEqual(decode(image), [link])
    }

    func testRenderSurvivesAtSmallSize() throws {
        let image = try render(pairingURL, side: 320)
        XCTAssertEqual(decode(image), [pairingURL])
    }

    func testLightMarkColourDoesNotAffectScanning() throws {
        let image = try render(pairingURL, markColor: Color(white: 0.9))
        XCTAssertEqual(decode(image), [pairingURL])
    }

    func testLogoWellStaysClearOfModules() throws {
        let matrix = try XCTUnwrap(QRMatrix.make(from: pairingURL))
        let layout = QRLiquidLayout(matrix: matrix, reservesLogo: true)
        let centre = layout.center
        let probe = layout.combined.contains(centre)
        XCTAssertFalse(probe)
        XCTAssertGreaterThan(layout.clearRadius, 2.5)
        XCTAssertEqual(layout.eyes.count, 3)
    }

    func testModuleMatrixKeepsTheQuietZone() throws {
        let matrix = try XCTUnwrap(QRMatrix.make(from: pairingURL))
        XCTAssertEqual(matrix.quietZone, QRMatrix.defaultQuietZone)
        for index in 0..<matrix.size {
            for edge in 0..<matrix.quietZone {
                XCTAssertFalse(matrix[edge, index])
                XCTAssertFalse(matrix[index, edge])
                XCTAssertFalse(matrix[matrix.size - 1 - edge, index])
                XCTAssertFalse(matrix[index, matrix.size - 1 - edge])
            }
        }
    }

    func testInkKeepsStrongContrastAgainstWhite() {
        XCTAssertGreaterThan(Self.contrastAgainstWhite(red: 0.09, green: 0.06, blue: 0.05), 10)
        XCTAssertGreaterThan(Self.contrastAgainstWhite(red: 0.60, green: 0.21, blue: 0.03), 4.5)
    }

    private static func contrastAgainstWhite(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }
}
