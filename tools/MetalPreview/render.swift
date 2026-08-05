// render.swift — headless renderer for the stitchable shaders.
//
//     tools/MetalPreview/render.sh out.png [focus] [time]
//
// Runs `cardFocusEffect` over a generated test cover and writes a PNG. No app,
// no simulator, no focus to drive, no window server.
//
// Why this exists: the shared tree is edited by several agents at once, so
// `xcodebuild` is red as often as it is green for reasons that have nothing to
// do with this shader — and `screencapture` needs a Screen Recording grant this
// environment does not have. Neither of those should be able to block looking
// at a shader. This depends on exactly one file: the `.metal` source.
//
// How a `[[stitchable]]` SwiftUI shader is called directly
// -------------------------------------------------------
// It is an ordinary MSL function; SwiftUI's only magic is the calling
// convention. A `.layerEffect` entry point takes `(float2 position,
// SwiftUI::Layer layer, ...)`, and `SwiftUI::Layer` is a plain struct of a
// texture plus `float2 info[5]` used as an affine map into it:
//
//     p = fma(p.x, info[0], fma(p.y, info[1], info[2]));
//     p = clamp(p, info[3], info[4]);
//
// So user-space -> normalised texture coords is info[0] = (1/w, 0),
// info[1] = (0, 1/h), info[2] = 0, info[3] = 0, info[4] = 1. A thin compute
// kernel builds that and calls the shader per pixel.

import Metal
import MetalKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "/tmp/card.png"
let focus = args.count > 2 ? Float(args[2])! : 1.0
let time = args.count > 3 ? Float(args[3])! : 0.0

let W = 512, H = 512

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let queue = device.makeCommandQueue()!

// The shader source plus a driver kernel, compiled together at runtime so this
// always reflects the current .metal file on disk.
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let shaderURL = here
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SoundingTV.swiftpm/Sources/Design/Shaders/CardEffects.metal")
// `#include <SwiftUI/SwiftUI_Metal.h>` resolves against the *SDK*, and a
// runtime `makeLibrary(source:)` compile only sees `/System/Library/
// Frameworks`, where that header does not ship. Strip the include and supply
// the struct — it is nine lines and its layout is fixed by the calling
// convention, so this is a transcription, not a reimplementation.
let swiftUILayerShim = """
namespace SwiftUI {
struct Layer {
    metal::texture2d<half> tex;
    float2 info[5];
    half4 sample(float2 p) const {
        p = metal::fma(p.x, info[0], metal::fma(p.y, info[1], info[2]));
        p = metal::clamp(p, info[3], info[4]);
        return tex.sample(metal::sampler(metal::filter::linear), p);
    }
};
}
"""
let shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
    .replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: swiftUILayerShim)
    // `[[stitchable]]` marks it a *visible function*, which Metal will not let
    // you call directly — it has to be linked in via `MTLLinkedFunctions`, and
    // a direct call fails at pipeline creation with "visible function not
    // loaded". Dropping the attribute makes it an ordinary function in the same
    // compilation unit as the driver kernel. The body is untouched.
    .replacingOccurrences(of: "[[ stitchable ]]", with: "")

let driver = """
#include <metal_stdlib>
using namespace metal;

kernel void driveCard(texture2d<half, access::sample> src [[texture(0)]],
                      texture2d<half, access::write> dst [[texture(1)]],
                      constant float &focus [[buffer(0)]],
                      constant float &time  [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const float w = dst.get_width(), h = dst.get_height();
    SwiftUI::Layer layer;
    layer.tex = src;
    layer.info[0] = float2(1.0f / w, 0.0f);
    layer.info[1] = float2(0.0f, 1.0f / h);
    layer.info[2] = float2(0.0f);
    layer.info[3] = float2(0.0f);
    layer.info[4] = float2(1.0f);

    const float2 pos = float2(gid) + 0.5f;
    // Shipping values from ShelfArtwork in HomeView.swift.
    half4 c = cardFocusEffect(pos, layer,
                              float4(0, 0, w, h),
                              half4(1.0h, 0.42h, 0.10h, 1.0h),   // Color.scAccent
                              time, focus,
                              2.0f,    // driftAmplitude
                              0.22f,   // rakeStrength
                              4.0f,    // rakePeriod
                              0.16f,   // spillStrength
                              0.18f,   // saturationLift
                              0.10f);  // contrastLift
    dst.write(c, gid);
}
"""

let opts = MTLCompileOptions()
let lib = try device.makeLibrary(source: shaderSource + "\n" + driver, options: opts)
let pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "driveCard")!)

// MARK: - Test cover
//
// Concentric rings on a two-stop gradient. The rings are the point: liquid
// displacement is invisible over a flat fill, so a flat test image would hide
// the one thing only a shader can do here.
func makeCover() -> MTLTexture {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.11, green: 0.15, blue: 0.35, alpha: 1),
        CGColor(red: 0.62, green: 0.16, blue: 0.42, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(7)
    for i in 0..<8 {
        let r = CGFloat(40 + i * 62)
        ctx.strokeEllipse(in: CGRect(x: CGFloat(W) / 2 - r, y: CGFloat(H) / 2 - r, width: r * 2, height: r * 2))
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
    desc.usage = [.shaderRead]
    let tex = device.makeTexture(descriptor: desc)!
    tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                withBytes: ctx.data!, bytesPerRow: W * 4)
    return tex
}

let src = makeCover()
let outDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
outDesc.usage = [.shaderWrite, .shaderRead]
let dst = device.makeTexture(descriptor: outDesc)!

let cb = queue.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pipeline)
enc.setTexture(src, index: 0)
enc.setTexture(dst, index: 1)
var f = focus, t = time
enc.setBytes(&f, length: 4, index: 0)
enc.setBytes(&t, length: 4, index: 1)
enc.dispatchThreads(MTLSize(width: W, height: H, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
enc.endEncoding()
cb.commit()
cb.waitUntilCompleted()

var bytes = [UInt8](repeating: 0, count: W * H * 4)
dst.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)

let provider = CGDataProvider(data: Data(bytes) as CFData)!
let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)  focus=\(focus) time=\(time)")
