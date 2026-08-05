#!/usr/bin/env swift
//
// Renders the Top Shelf sign-in banner: a dark field matching the app, with a
// white QR plate on the RIGHT.
//
// Right, specifically, because `TVTopShelfCarouselContent(style: .details)`
// draws its own contextTitle / title / summary over the LEFT of the image.
// Anything put there is either hidden or fighting the system's type.
//
// Run:  swift tools/make_topshelf_qr.swift
//
// Output is committed, not generated at build time, and that is the whole
// point: the encoded URL is a fixed public page with no session, no secret
// and no expiry, so there is nothing to generate at runtime. See
// `DefaultShelf.swift` for why a *pairing* QR could not work here.

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let payload = "https://sounding.forbes.red/"

// Correction level M, not the app's H. H exists on the in-app code only to buy
// budget for the app mark knocked out of its centre. Nothing is knocked out
// here, and M produces a lower-density symbol — fewer, fatter modules — which
// is strictly easier to scan across a living room.
func qrMatrix(_ string: String) -> (size: Int, bits: [Bool])? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = filter.outputImage else { return nil }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }

    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h)
    guard let bmp = CGContext(data: &px, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    bmp.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Core Image bakes in its own quiet zone. Crop to the dark bounding box so
    // the caller controls the margin instead of inheriting an unknown one.
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where px[y * w + x] < 128 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= minX else { return nil }

    let size = maxX - minX + 1
    var bits = [Bool](repeating: false, count: size * size)
    for y in 0..<size { for x in 0..<size {
        // Flip vertically: CGContext origin is bottom-left, matrix is top-left.
        bits[y * size + x] = px[(minY + (size - 1 - y)) * w + (minX + x)] < 128
    } }
    return (size, bits)
}

// The backdrop is drawn into a small context and then scaled up, rather than
// drawn at full size.
//
// CoreGraphics dithers its gradients — it adds per-pixel noise on purpose, to
// stop smooth ramps banding. That is the right call on screen and a disaster
// in a PNG: the noise is incompressible, and it was costing 6-9x the file size
// of the flat brand art this sits beside (884 KB / 3.2 MB against 142 KB /
// 356 KB). Dithering a 240x90 tile and then interpolating it up to 3840x1440
// gives a ramp that is smoother than the dithered original *and* compresses,
// because the upscale turns the noise into gentle continuous tone.
//
// The plate and the code are drawn afterwards, at full resolution, because
// those must stay pixel-sharp — a soft-edged QR module is a QR that doesn't
// scan.
func drawBackdrop(into ctx: CGContext, width: CGFloat, height: CGFloat, cs: CGColorSpace) {
    let scale: CGFloat = 8
    let w = Int(width / scale), h = Int(height / scale)
    guard let small = CGContext(data: nil, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return }

    let W = CGFloat(w), H = CGFloat(h)

    small.setFillColor(CGColor(srgbRed: 0.027, green: 0.027, blue: 0.043, alpha: 1))
    small.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // Warm bloom behind the plate, so the light has a source. Same move as
    // `PairingBackdrop` on the pairing screen itself.
    let accent = CGColor(srgbRed: 1.0, green: 0.42, blue: 0.10, alpha: 1)
    if let grad = CGGradient(colorsSpace: cs,
                             colors: [accent.copy(alpha: 0.30)!, accent.copy(alpha: 0)!] as CFArray,
                             locations: [0, 1]) {
        small.drawRadialGradient(grad,
                                 startCenter: CGPoint(x: W * 0.74, y: H * 0.5), startRadius: 0,
                                 endCenter: CGPoint(x: W * 0.74, y: H * 0.5), endRadius: H * 0.95,
                                 options: [])
    }

    // Cool counterweight, kept far away in the opposite corner — orange over
    // violet in the same region just makes brown.
    let violet = CGColor(srgbRed: 0.24, green: 0.16, blue: 0.52, alpha: 1)
    if let grad = CGGradient(colorsSpace: cs,
                             colors: [violet.copy(alpha: 0.42)!, violet.copy(alpha: 0)!] as CFArray,
                             locations: [0, 1]) {
        small.drawRadialGradient(grad,
                                 startCenter: CGPoint(x: W * 0.02, y: 0), startRadius: 0,
                                 endCenter: CGPoint(x: W * 0.02, y: 0), endRadius: H * 1.4,
                                 options: [])
    }

    guard let image = small.makeImage() else { return }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func render(width: Int, height: Int, to url: URL) throws {
    guard let matrix = qrMatrix(payload) else { fatalError("QR generation failed") }

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    // Opaque. The first version used `premultipliedLast`, which wrote an alpha
    // channel nothing needed into every pixel of a banner that is fully
    // opaque by construction — 25% of the file for no information. The brand
    // art alongside it is RGB.
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("context") }

    let W = CGFloat(width), H = CGFloat(height)

    drawBackdrop(into: ctx, width: W, height: H, cs: cs)

    // The plate. Solid white and generously sized: this has to survive being
    // photographed off a television from across a room.
    let plate = H * 0.72
    let plateRect = CGRect(x: W * 0.745 - plate / 2, y: (H - plate) / 2, width: plate, height: plate)
    let radius = plate * 0.14

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -plate * 0.05), blur: plate * 0.16,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // ISO/IEC 18004 wants 4 modules of quiet zone on every side. Without it
    // scanners lose the contrast edge they use to find the finder patterns.
    let quiet = 4
    let total = matrix.size + quiet * 2
    let inset = plate * 0.10
    let module = (plate - inset * 2) / CGFloat(total)

    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    for row in 0..<matrix.size {
        for col in 0..<matrix.size where matrix.bits[row * matrix.size + col] {
            let x = plateRect.minX + inset + CGFloat(col + quiet) * module
            // Flip back into CGContext's bottom-left origin.
            let y = plateRect.maxY - inset - CGFloat(row + quiet + 1) * module
            // +0.5 overdraw closes the hairline seams that otherwise appear
            // between adjacent modules at non-integer module sizes, which is
            // exactly the artefact that makes a rendered QR fail to scan.
            ctx.fill(CGRect(x: x, y: y, width: module + 0.5, height: module + 0.5))
        }
    }

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("encode") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write") }
    let kb = (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue / 1024
    print("wrote \(url.lastPathComponent) (\(width)x\(height), \(kb) KB)")
}

let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("SoundingTV-TopShelf")

// 1920×720 @1x and 3840×1440 @2x — the sizes a carousel item wants, and the
// same pair `DefaultShelfArt` already ships.
try render(width: 1920, height: 720, to: dir.appendingPathComponent("SignInShelfArt.png"))
try render(width: 3840, height: 1440, to: dir.appendingPathComponent("SignInShelfArt@2x.png"))
