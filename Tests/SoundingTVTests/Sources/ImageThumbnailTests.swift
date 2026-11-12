import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SoundingTV

final class ImageThumbnailTests: XCTestCase {
    func testClampKeepsRequestsWithinTheSource() {
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(300, width: 200, height: 200), 200)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(1800, width: 500, height: 320), 500)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(240, width: 100, height: 640), 240)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(120, width: 500, height: 500), 120)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(500, width: 500, height: 500), 500)
    }

    func testClampLeavesUnknownSizesAlone() {
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(300, width: 0, height: 0), 300)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(0, width: 200, height: 200), 0)
    }

    func testSourceSizeIsRead() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try png(width: 64, height: 48) as CFData, nil))
        let size = try XCTUnwrap(ImageThumbnail.pixelSize(of: source))
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
        XCTAssertEqual(ImageThumbnail.clampedMaxPixelSize(300, for: source), 64)
    }

    func testSmallImagesAreNotUpscaled() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try png(width: 64, height: 48) as CFData, nil))
        let image = try XCTUnwrap(ImageThumbnail.create(from: source, maxPixelSize: 300, cacheImmediately: true))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testLargeImagesAreStillDownsampled() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try png(width: 600, height: 400) as CFData, nil))
        let image = try XCTUnwrap(ImageThumbnail.create(from: source, maxPixelSize: 300))
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
    }

    func testArtworkDecodeKeepsSmallSourcesAtTheirOwnSize() throws {
        let image = try XCTUnwrap(SCArtworkStore.decode(try png(width: 200, height: 200), maxPixelSize: 300))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0.42, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
