import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

func measure<T>(_ label: String, repeats: Int = 1, _ body: () -> T) -> (T, wall: Double, cpu: Double) {
    var result: T?
    var bestWall = Double.infinity, bestCPU = Double.infinity
    for _ in 0 ..< repeats {
        let c0 = cpuSeconds(), w0 = CACurrentMediaTime()
        result = body()
        let w = CACurrentMediaTime() - w0, c = cpuSeconds() - c0
        if w < bestWall { bestWall = w; bestCPU = c }
    }
    print(String(format: "  %-44@ wall %8.1f ms   cpu %8.1f ms", label as NSString, bestWall * 1000, bestCPU * 1000))
    return (result!, bestWall, bestCPU)
}

func decodeMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let chunk: AVAudioFrameCount = 1 << 15
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
    var out: [Float] = []
    out.reserveCapacity(Int(file.length))
    let channels = Int(format.channelCount)
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: chunk)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { break }
        for i in 0 ..< frames {
            var x: Float = 0
            for c in 0 ..< channels { x += data[c][i] }
            out.append(x / Float(max(channels, 1)))
        }
    }
    return (out, format.sampleRate)
}

func maxRelativeError(_ a: [Float], _ b: [Float]) -> (abs: Float, rel: Float) {
    precondition(a.count == b.count, "count mismatch \(a.count) vs \(b.count)")
    var worstAbs: Float = 0, worstRel: Float = 0
    for i in a.indices {
        let d = abs(a[i] - b[i])
        worstAbs = max(worstAbs, d)
        worstRel = max(worstRel, d / max(abs(b[i]), 1e-3))
    }
    return (worstAbs, worstRel)
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  wrote \(path)")
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "/tmp/metal-waveform"
let tracks = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if let device = MTLCreateSystemDefaultDevice() {
    do { _ = try device.makeLibrary(source: MetalWaveformShaders.source, options: nil) } catch { print(error) }
}
guard let context = MetalWaveformContext.shared, let renderer = MetalWaveformRenderer(context: context) else {
    print("Metal unavailable"); exit(1)
}
print("GPU: \(context.device.name)")

print("\n== Generated audio parity")
do {
    let rate = 44100.0
    let seconds = 20.0
    var x = [Float](repeating: 0, count: Int(rate * seconds))
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in x.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: seed >> 11) % 2000) / 2000 - 0.5
        let t = Double(i) / rate
        x[i] = Float(0.5 * sin(2 * .pi * 55 * t) + 0.2 * sin(2 * .pi * 1000 * t) * (t.truncatingRemainder(dividingBy: 0.5) < 0.1 ? 1 : 0)) + noise * 0.15
    }
    let filter = WaveformBandFilter(sampleRate: rate, entriesPerSecond: 150)
    let serial = x.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) }
    let parallel = x.withUnsafeBufferPointer { WaveformBandsCPU.parallel($0, filter: filter, windowsPerTask: 64) }
    let gpu = x.withUnsafeBufferPointer { WaveformBandsGPU.compute($0, filter: filter, context: context)! }
    for (name, a, b) in [("amplitude", gpu.amplitude, serial.amplitude), ("low", gpu.low, serial.low), ("mid", gpu.mid, serial.mid), ("high", gpu.high, serial.high)] {
        let e = maxRelativeError(a, b)
        print(String(format: "  gpu vs cpu %-10@ max abs %.2e  max rel %.2e", name as NSString, e.abs, e.rel))
    }
    for (name, a, b) in [("low", parallel.low, serial.low), ("high", parallel.high, serial.high)] {
        let e = maxRelativeError(a, b)
        print(String(format: "  parallel vs serial %-10@ max abs %.2e  max rel %.2e", name as NSString, e.abs, e.rel))
    }
    let base = WaveformPyramid.baseBins(bands: serial)
    let cpuLevels = WaveformPyramid.buildLevels(base: base)
    let gpuLevels = WaveformPyramidGPU.buildLevels(base: base, context: context)!
    let gpuBins = UnsafeBufferPointer(start: gpuLevels.buffer.contents().assumingMemoryBound(to: SIMD2<UInt32>.self), count: cpuLevels.bins.count)
    let mismatches = zip(cpuLevels.bins, gpuBins).filter { $0 != $1 }.count
    print("  pyramid levels \(cpuLevels.offsets.count), bins \(cpuLevels.bins.count), gpu/cpu mismatches \(mismatches)")
}

var realMono: [Float] = []
var realRate = 44100.0
if !tracks.isEmpty {
    print("\n== Real tracks: decode + bands parity")
    var decodeWall = 0.0, decodeCPU = 0.0, decodedSeconds = 0.0
    for url in tracks {
        let (decoded, wall, cpu) = measure("decode \(url.lastPathComponent.prefix(30))") { try! decodeMono(url) }
        decodeWall += wall; decodeCPU += cpu
        decodedSeconds += Double(decoded.samples.count) / decoded.rate
        realRate = decoded.rate
        let filter = WaveformBandFilter(sampleRate: decoded.rate, entriesPerSecond: 150)
        let serial = decoded.samples.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) }
        let gpu = decoded.samples.withUnsafeBufferPointer { WaveformBandsGPU.compute($0, filter: filter, context: context)! }
        let eLow = maxRelativeError(gpu.low, serial.low), eHigh = maxRelativeError(gpu.high, serial.high), eAmp = maxRelativeError(gpu.amplitude, serial.amplitude)
        print(String(format: "    parity amp %.1e  low %.1e  high %.1e (max rel)", eAmp.rel, eLow.rel, eHigh.rel))
        if realMono.isEmpty { realMono = decoded.samples }
    }
    print(String(format: "  decode total: %.1f s audio in %.0f ms wall, %.0f ms cpu  => %.2f ms per minute of audio", decodedSeconds, decodeWall * 1000, decodeCPU * 1000, decodeWall * 1000 / (decodedSeconds / 60)))
}

print("\n== 2-hour set: band energy + peaks (150 entries/s)")
let setSeconds = 7200.0
let setRate = realRate
let setCount = Int(setSeconds * setRate)
var set = [Float](repeating: 0, count: setCount)
if realMono.isEmpty {
    for i in set.indices { set[i] = Float(sin(Double(i) * 0.01)) * 0.5 }
} else {
    set.withUnsafeMutableBufferPointer { out in
        realMono.withUnsafeBufferPointer { src in
            var i = 0
            while i < out.count {
                let n = min(src.count, out.count - i)
                out.baseAddress!.advanced(by: i).update(from: src.baseAddress!, count: n)
                i += n
            }
        }
    }
}
let setFilter = WaveformBandFilter(sampleRate: setRate, entriesPerSecond: 150)
let (setSerial, _, _) = measure("CPU serial (current DJAudioAnalysis loop)") { set.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: setFilter) } }
_ = measure("CPU parallel (warm-up split, all cores)", repeats: 3) { set.withUnsafeBufferPointer { WaveformBandsCPU.parallel($0, filter: setFilter) } }
_ = measure("GPU warm-up (first dispatch)") { set.withUnsafeBufferPointer { WaveformBandsGPU.compute(UnsafeBufferPointer(rebasing: $0[0 ..< 441000]), filter: setFilter, context: context) } }
let (setGPU, _, _) = measure("GPU compute (incl. upload + readback)", repeats: 3) { set.withUnsafeBufferPointer { WaveformBandsGPU.compute($0, filter: setFilter, context: context)! } }
@MainActor func streamed(_ make: () -> WaveformBandStream) -> WaveformBandFrames {
    var stream = make()
    set.withUnsafeBufferPointer { all in
        var i = 0
        while i < all.count {
            let n = min(32768, all.count - i)
            stream.append(UnsafeBufferPointer(rebasing: all[i ..< i + n]))
            i += n
        }
    }
    return stream.finish()
}
let (streamCPU, _, _) = measure("stream, CPU parallel segments (shipping fallback)", repeats: 2) { streamed { .cpu(filter: setFilter) } }
let (streamGPU, _, _) = measure("stream, GPU segments (shipping default)", repeats: 2) { streamed { .best(filter: setFilter) } }
for (name, frames) in [("stream cpu", streamCPU), ("stream gpu", streamGPU)] {
    let e = maxRelativeError(frames.high, setSerial.high), l = maxRelativeError(frames.low, setSerial.low)
    print(String(format: "  %@ vs serial: count %d/%d  low max rel %.1e  high max rel %.1e", name, frames.count, setSerial.count, l.rel, e.rel))
}
let setErr = maxRelativeError(setGPU.low, setSerial.low)
print(String(format: "  2h parity gpu vs cpu low: max rel %.1e over %d entries", setErr.rel, setGPU.count))

print("\n== LOD pyramid (2-hour set)")
let base150 = WaveformPyramid.baseBins(bands: setSerial)
_ = measure("CPU pyramid from 150/s base (\(base150.count) bins)", repeats: 3) { WaveformPyramid.buildLevels(base: base150) }
_ = measure("GPU pyramid from 150/s base", repeats: 3) { WaveformPyramidGPU.buildLevels(base: base150, context: context) }
let fineFilter = WaveformBandFilter(sampleRate: setRate, entriesPerSecond: setRate / 64)
let fineBands = set.withUnsafeBufferPointer { WaveformBandsGPU.compute($0, filter: fineFilter, context: context)! }
let base689 = WaveformPyramid.baseBins(bands: fineBands)
_ = measure("CPU pyramid from 689/s base (\(base689.count) bins)", repeats: 3) { WaveformPyramid.buildLevels(base: base689) }
_ = measure("GPU pyramid from 689/s base", repeats: 3) { WaveformPyramidGPU.buildLevels(base: base689, context: context) }

print("\n== Rendering")
let setSource = MetalWaveformSource(id: "set", baseBins: base689, binsPerSecond: setRate / 64, duration: setSeconds, context: context)!
let trackSeconds = realMono.isEmpty ? 300.0 : Double(realMono.count) / realRate
let trackPyramid = (realMono.isEmpty ? Array(set[0 ..< Int(300 * setRate)]) : realMono).withUnsafeBufferPointer { WaveformPyramid(mono: $0, sampleRate: setRate) }
let trackSource = MetalWaveformSource(id: "track", pyramid: trackPyramid, context: context)!
let grid = MetalWaveformBeatGrid(bpm: 128, firstBeatSeconds: 0.12)
let overlays: [MetalWaveformOverlay] = [
    MetalWaveformOverlay(id: "cue-a", kind: .cue(60), color: SIMD4(0.95, 0.25, 0.25, 1)),
    MetalWaveformOverlay(id: "cue-b", kind: .cue(trackSeconds * 0.5), color: SIMD4(0.25, 0.9, 0.4, 1)),
    MetalWaveformOverlay(id: "loop", kind: .loop(trackSeconds * 0.62 - 2 ... trackSeconds * 0.62 - 2 + 4 * 60 / 128 * 4), color: SIMD4(0.3, 0.8, 1, 1)),
    MetalWaveformOverlay(id: "region", kind: .region(0 ... 30), color: SIMD4(1, 1, 1, 0.06)),
]
let size = CGSize(width: 1200, height: 160)
let scale: CGFloat = 2
let mid = trackSeconds * 0.62
let shots: [(String, MetalWaveformSource, MetalWaveformTimeline, MetalWaveformStyle)] = [
    ("zoom1-whole-2h-set-threeband", setSource, .range(0 ... setSeconds, playhead: setSeconds * 0.37), MetalWaveformStyle.threeBand.dimmingUnplayed(0.55)),
    ("zoom2-track-16s-rgb", trackSource, .range(mid - 8 ... mid + 8, playhead: mid), MetalWaveformStyle.rgb.dimmingUnplayed(0.6)),
    ("zoom3-track-12ms-samples-blue", trackSource, .range(mid ... mid + 0.012, playhead: mid + 0.006), MetalWaveformStyle.blue),
    ("zoom-track-whole-blue", trackSource, .range(0 ... trackSeconds, playhead: trackSeconds * 0.4), MetalWaveformStyle.blue.dimmingUnplayed(0.5)),
]
for (name, source, timeline, style) in shots {
    var gpuTimes: [Double] = [], encodeTimes: [Double] = []
    var lastImage: CGImage?
    var stats: MetalWaveformFrameStats?
    for _ in 0 ..< 30 {
        let r = renderer.snapshot(source: source, timeline: timeline, grid: grid, overlays: overlays, style: style, size: size, scale: scale)!
        gpuTimes.append(r.gpuSeconds); encodeTimes.append(r.encodeSeconds)
        lastImage = r.image; stats = r.stats
    }
    gpuTimes.sort(); encodeTimes.sort()
    print(String(format: "  %-34@ level %2d  samples %@  grid %4d  gpu median %.3f ms  encode median %.3f ms", name as NSString, stats!.level, stats!.usesSamples ? "yes" : "no ", stats!.gridLines, gpuTimes[15] * 1000, encodeTimes[15] * 1000))
    if let lastImage { writePNG(lastImage, to: "\(outDir)/\(name).png") }
}

print("\n== 120 fps follow simulation (deck lane, 10 s window, 2400x240 px)")
do {
    var encodeTotal = 0.0, gpuTotal = 0.0, worstGPU = 0.0
    let frames = 600
    let timelineStart = CACurrentMediaTime()
    for f in 0 ..< frames {
        let timeline = MetalWaveformTimeline.following(anchor: 60, hostTime: timelineStart, rate: 1, window: 10, playheadFraction: 0.5)
        let host = timelineStart + Double(f) / 120
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2400, height: 240, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = context.device.makeTexture(descriptor: descriptor)!
        let commands = context.queue.makeCommandBuffer()!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        let e0 = CACurrentMediaTime()
        renderer.encode(into: encoder, source: trackSource, timeline: timeline, hostTime: host, grid: grid, overlays: overlays, style: .threeBand, drawableSize: CGSize(width: 2400, height: 240), scale: 2)
        encoder.endEncoding()
        encodeTotal += CACurrentMediaTime() - e0
        commands.commit()
        commands.waitUntilCompleted()
        let g = commands.gpuEndTime - commands.gpuStartTime
        gpuTotal += g; worstGPU = max(worstGPU, g)
    }
    print(String(format: "  encode (main-thread work) mean %.1f us/frame, gpu mean %.3f ms/frame, worst %.3f ms (budget 8.33 ms)", encodeTotal / Double(frames) * 1e6, gpuTotal / Double(frames) * 1000, worstGPU * 1000))
}
print("\ndone")
