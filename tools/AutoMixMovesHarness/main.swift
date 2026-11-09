import Foundation
import AVFoundation
import Accelerate
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/automix-moves-src")
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/automix-moves-out")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let ids = ["jungle", "voodoo", "marionette", "darkknight"]
let sr = 44_100.0

func analysis(_ id: String) async throws -> BeatTrackerResult {
    let cache = sourceDirectory.appendingPathComponent("analysis-\(id)-v\(BeatTracker.version).json")
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(BeatTrackerResult.self, from: data) { return cached }
    let result = try await BeatTracker.analyze(fileURL: sourceDirectory.appendingPathComponent("\(id).wav"))
    try JSONEncoder().encode(result).write(to: cache)
    return result
}

func performanceTrack(_ id: String, _ result: BeatTrackerResult, duration: Double) -> MixPerformanceTrack {
    let bars = result.bars.flatMap { $0.level.count == result.downbeats.count ? $0 : nil }
    return MixPerformanceTrack(
        trackId: id, duration: duration, downbeats: result.downbeats, barsPerPhrase: 8,
        phraseOffsetBars: result.phraseOffsetBars, vocals: result.vocalSeconds,
        barLevel: bars?.level, barDensity: bars?.density, barLoop: bars?.loop4
    )
}

struct Render {
    var left: [Float]
    var right: [Float]
    var startSeconds: Double
}

func render(_ url: URL, from: Double, seconds: Double, move: MixPerformanceMove?, track: MixPerformanceTrack) throws -> Render {
    let core = MixRenderCore(sampleRate: sr)
    let source = try MixSource(url: url, synchronous: true)
    var seq: Int64 = 0
    func push(_ make: (Int64) -> MixCommand) {
        seq += 1
        _ = core.ring.push(make(seq))
    }
    push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(source)) }
    push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .start(deck: 0, fromFrame: from * sr)) }
    if let move {
        let timeline = MixTimeline.performance(move, deck: 0, track: track, sampleRate: sr, rate: 1)
        for event in timeline.events {
            push { .event(seq: $0, time: event.offset, immediate: false, group: 7, action: event.action) }
        }
        push { .anchor(seq: $0, group: 7, anchor: timeline.anchor) }
    }
    let total = Int(seconds * sr)
    var left = [Float](repeating: 0, count: total)
    var right = [Float](repeating: 0, count: total)
    let block = 512
    let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { l.deallocate(); r.deallocate() }
    var done = 0
    while done < total {
        let n = min(block, total - done)
        core.render(frames: n, left: l, right: r)
        for k in 0..<n {
            left[done + k] = l[k]
            right[done + k] = r[k]
        }
        done += n
    }
    withExtendedLifetime(source) {}
    return Render(left: left, right: right, startSeconds: from)
}

func truePeak(_ x: [Float], _ range: Range<Int>) -> Float {
    let taps = 12
    var kernels: [[Float]] = []
    for phase in 1..<4 {
        let frac = Double(phase) / 4
        var k: [Float] = []
        for t in -taps..<taps {
            let d = Double(t) + 1 - frac
            let sinc = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
            let w = 0.5 + 0.5 * cos(.pi * d / Double(taps + 1))
            k.append(Float(sinc * w))
        }
        kernels.append(k)
    }
    var peak: Float = 0
    let lo = max(range.lowerBound, taps)
    let hi = min(range.upperBound, x.count - taps)
    guard hi > lo else { return 0 }
    for i in lo..<hi {
        peak = max(peak, abs(x[i]))
        for k in kernels {
            var s: Float = 0
            for (j, c) in k.enumerated() { s += x[i - taps + 1 + j] * c }
            peak = max(peak, abs(s))
        }
    }
    return peak
}

func db(_ x: Float) -> Float { 20 * log10(max(1e-9, x)) }

func secondDifferenceMax(_ x: [Float], _ range: Range<Int>) -> Float {
    var m: Float = 0
    let lo = max(2, range.lowerBound)
    let hi = min(x.count, range.upperBound)
    guard hi > lo else { return 0 }
    for i in lo..<hi { m = max(m, abs(x[i] - 2 * x[i - 1] + x[i - 2])) }
    return m
}

func rms(_ x: [Float], _ range: Range<Int>) -> Float {
    let lo = max(0, range.lowerBound)
    let hi = min(x.count, range.upperBound)
    guard hi > lo else { return 0 }
    var s: Float = 0
    for i in lo..<hi { s += x[i] * x[i] }
    return sqrt(s / Float(hi - lo))
}

func residual(_ a: [Float], _ b: [Float], _ range: Range<Int>) -> Float {
    let lo = max(0, range.lowerBound)
    let hi = min(a.count, b.count, range.upperBound)
    guard hi > lo else { return 0 }
    var s: Float = 0
    for i in lo..<hi { let d = a[i] - b[i]; s += d * d }
    return sqrt(s / Float(hi - lo))
}

func writeWav(_ render: Render, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(render.left.count))!
    buffer.frameLength = AVAudioFrameCount(render.left.count)
    for i in 0..<render.left.count {
        buffer.floatChannelData![0][i] = render.left[i]
        buffer.floatChannelData![1][i] = render.right[i]
    }
    try file.write(from: buffer)
}

func spectrogram(_ x: [Float], width: Int, bins: Int) -> [[Float]] {
    let n = 2048
    let log2n = vDSP_Length(11)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var columns: [[Float]] = []
    for c in 0..<width {
        let start = min(max(0, x.count - n), c * (x.count - n) / max(1, width - 1))
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = x[start + i] * window[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        var column = [Float](repeating: -120, count: bins)
        for b in 0..<bins {
            let f0 = 30 * pow(16_000.0 / 30, Double(b) / Double(bins))
            let f1 = 30 * pow(16_000.0 / 30, Double(b + 1) / Double(bins))
            let i0 = max(1, Int(f0 / sr * Double(n)))
            let i1 = max(i0 + 1, min(n / 2, Int(f1 / sr * Double(n))))
            var m: Float = 0
            for i in i0..<i1 { m = max(m, mags[i]) }
            column[b] = 10 * log10(max(1e-12, m))
        }
        columns.append(column)
    }
    return columns
}

func plot(wet: Render, dry: Render, move: MixPerformanceMove, title: String, to url: URL) {
    let width = 1400
    let waveHeight = 220
    let specHeight = 300
    let height = waveHeight * 2 + specHeight + 20
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func wave(_ x: [Float], top: Int, color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        let mid = Double(height - top - waveHeight / 2)
        for c in 0..<width {
            let lo = c * x.count / width
            let hi = max(lo + 1, (c + 1) * x.count / width)
            var mn: Float = 0, mx: Float = 0
            for i in lo..<min(hi, x.count) { mn = min(mn, x[i]); mx = max(mx, x[i]) }
            ctx.move(to: CGPoint(x: Double(c), y: mid + Double(mn) * Double(waveHeight / 2)))
            ctx.addLine(to: CGPoint(x: Double(c), y: mid + Double(mx) * Double(waveHeight / 2)))
            ctx.strokePath()
        }
    }
    wave(dry.left, top: 0, color: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    wave(wet.left, top: waveHeight, color: CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    let columns = spectrogram(wet.left, width: width, bins: specHeight)
    for (c, column) in columns.enumerated() {
        for (b, v) in column.enumerated() {
            let t = CGFloat(min(1, max(0, (v + 20) / 80)))
            ctx.setFillColor(CGColor(red: t, green: t * t, blue: 0.3 * (1 - t), alpha: 1))
            ctx.fill(CGRect(x: c, y: b, width: 1, height: 1))
        }
    }
    let duration = Double(wet.left.count) / sr
    func marker(_ seconds: Double, _ color: CGColor) {
        let x = (seconds - wet.startSeconds) / duration * Double(width)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x, y: Double(height)))
        ctx.strokePath()
    }
    marker(move.startSeconds, CGColor(red: 0, green: 0.7, blue: 0, alpha: 1))
    marker(move.landingSeconds, CGColor(red: 0.9, green: 0, blue: 0, alpha: 1))
    if move.endSeconds > move.landingSeconds { marker(move.endSeconds, CGColor(red: 0.9, green: 0.6, blue: 0, alpha: 1)) }
    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    _ = title
}

func spectralFlux(_ x: [Float], from start: Int, to end: Int) -> [Float] {
    let n = 2048
    let hop = 512
    let log2n = vDSP_Length(11)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    let bands = 40
    var edges: [Int] = []
    for b in 0...bands { edges.append(max(1, min(n / 2 - 1, Int(30 * pow(16_000.0 / 30, Double(b) / Double(bands)) / sr * Double(n))))) }
    var previous: [Float]? = nil
    var out: [Float] = []
    var position = max(0, start)
    while position + n <= min(x.count, end) {
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = x[position + i] * window[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        var bandsDB = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            var sum: Float = 0
            for i in edges[b]..<max(edges[b] + 1, edges[b + 1]) { sum += mags[i] }
            bandsDB[b] = max(-80, 10 * log10(max(1e-12, sum)))
        }
        if let previous {
            var f: Float = 0
            for b in 0..<bands { f += max(0, bandsDB[b] - previous[b]) }
            out.append(f / Float(bands))
        }
        previous = bandsDB
        position += hop
    }
    return out
}

func percentile(_ x: [Float], _ p: Double) -> Float {
    guard !x.isEmpty else { return 0 }
    let sorted = x.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

struct GateResult {
    var lines: [String] = []
    var failures: [String] = []
}

func gate(_ id: String, _ url: URL, _ move: MixPerformanceMove, _ track: MixPerformanceTrack, label: String, write: Bool) throws -> GateResult {
    var out = GateResult()
    let from = max(0, move.startSeconds - 12)
    let seconds = (move.endSeconds - from) + 10
    let dry = try render(url, from: from, seconds: seconds, move: nil, track: track)
    let wet = try render(url, from: from, seconds: seconds, move: move, track: track)
    func frame(_ s: Double) -> Int { Int(((s - from) * sr).rounded()) }
    let window = frame(move.startSeconds - 0.1)..<frame(move.endSeconds + 0.6)
    let whole = 0..<dry.left.count
    let ceiling = max(secondDifferenceMax(dry.left, whole), secondDifferenceMax(dry.right, whole))
    let wetD2 = max(secondDifferenceMax(wet.left, window), secondDifferenceMax(wet.right, window))
    let dryTP = max(truePeak(dry.left, window), truePeak(dry.right, window))
    let wetTP = max(truePeak(wet.left, window), truePeak(wet.right, window))
    let beat = track.barLength(at: move.landingBar - 1) / 4
    let settle = move.kind == .echoThrow ? move.endSeconds + 4 * beat : move.endSeconds + 0.25
    let nullRange = frame(settle)..<frame(settle + 3)
    let level = max(1e-6, rms(dry.left, nullRange))
    let null = db(residual(wet.left, dry.left, nullRange) / level)
    let moveRange = frame(move.startSeconds)..<frame(max(move.landingSeconds, move.endSeconds))
    let changed = db(residual(wet.left, dry.left, moveRange) / max(1e-6, rms(dry.left, moveRange)))
    let vocal = track.vocalSeconds((move.startSeconds - beat)...max(move.endSeconds, move.landingSeconds + beat))
    let onDownbeat = track.downbeats.contains { abs($0 - move.landingSeconds) < 1e-6 } && track.isPhraseStart(move.landingBar)
    let startOnGrid = move.kind == .echoThrow
        ? abs((move.landingSeconds - move.startSeconds) - beat) < 1e-6
        : track.downbeats.contains { abs($0 - move.startSeconds) < 1e-6 }
    var eventsOnGrid = true
    let timeline = MixTimeline.performance(move, deck: 0, track: track, sampleRate: sr, rate: 1)
    let rollBeat = (move.landingSeconds - move.startSeconds) / Double(max(1, move.lengthBeats))
    for event in timeline.events {
        let t = Double(event.offset) / sr
        if abs(t - Double(timeline.lengthFrames) / sr) <= 0.001 { continue }
        let source = move.startSeconds + t
        guard let k = track.downbeats.lastIndex(where: { $0 <= source + 0.0005 }), k + 1 < track.downbeats.count else { eventsOnGrid = false; continue }
        let beats = (source - track.downbeats[k]) / (track.downbeats[k + 1] - track.downbeats[k]) * 4
        if abs(beats * 2 - (beats * 2).rounded()) > 0.004 { eventsOnGrid = false }
    }
    if move.kind == .loopRoll {
        let span = move.landingSeconds - move.startSeconds
        var offsets: [Double] = []
        var rung = span / 2
        var at = 0.0
        while rung > rollBeat + 1e-6 { at += rung; rung /= 2; offsets.append(at) }
        offsets.append(at + rung)
        var lags: [Int] = []
        var worst = 1.0
        let downbeat = frame(move.startSeconds) + 400
        for offset in offsets {
            let probe = frame(move.startSeconds + offset) + 400
            var best = (lag: 0, score: -2.0)
            for lag in stride(from: -3000, through: 3000, by: 2) {
                var xy = 0.0, xx = 0.0, yy = 0.0
                for i in 0..<1024 {
                    let x = Double(dry.left[downbeat + lag + i]), y = Double(wet.left[probe + i])
                    xy += x * y; xx += x * x; yy += y * y
                }
                let c = xy / max(1e-12, sqrt(xx * yy))
                if c > best.score { best = (lag, c) }
            }
            lags.append(best.lag)
            worst = min(worst, best.score)
        }
        out.lines.append(String(format: "ROLL|%@|rungs at %@ s restart %@ frames from the looped downbeat (worst match %.2f)", id, offsets.map { String(format: "%.3f", $0) }.joined(separator: ","), lags.map(String.init).joined(separator: ","), worst))
        if lags.contains(where: { abs($0) > 8 }) || worst < 0.3 { out.failures.append("\(label) \(id) loop roll rungs do not restart on the downbeat (lags \(lags))") }
    }
    let release = frame(move.landingSeconds - 2 * beat)..<frame(move.landingSeconds + beat)
    let wetFlux = spectralFlux(wet.left, from: release.lowerBound, to: release.upperBound)
    let dryFlux = spectralFlux(dry.left, from: release.lowerBound, to: release.upperBound)
    let clipFlux = spectralFlux(dry.left, from: 0, to: dry.left.count)
    let fluxCeiling = max(wetFlux.isEmpty ? 0 : (dryFlux.max() ?? 0), percentile(clipFlux, 0.99)) * 1.25
    let releaseFlux = wetFlux.max() ?? 0
    let peakAt = (Double(release.lowerBound + (wetFlux.firstIndex(of: releaseFlux) ?? 0) * 512 + 1024) / sr + from) - move.landingSeconds
    out.lines.append(String(format: "FLUX|%@|%@|release flux %.2f dB/band (peak %+.3f s from the landing), dry same window %.2f, dry p99 %.2f, ceiling %.2f", id, move.kind.displayName, releaseFlux, peakAt, dryFlux.max() ?? 0, percentile(clipFlux, 0.99), fluxCeiling))
    if releaseFlux > fluxCeiling { out.failures.append("\(label) \(id) \(move.kind): spectral flux spike at the release \(releaseFlux) above \(fluxCeiling)") }
    let meaty = (move.startBar..<move.landingBar).filter(track.isMeaty)
    if !meaty.isEmpty { out.failures.append("\(label) \(id) \(move.kind): runs over meaty bars \(meaty)") }
    if track.hasJump(in: (move.startBar - MixPerformancePlanner.settleBars + 1)..<move.landingBar) { out.failures.append("\(label) \(id) \(move.kind): starts within 8 bars after a drop or energy jump") }
    out.lines.append(String(format: "%@|%@|%@|bars %d->%d|start %.3f landing %.3f end %.3f|d2 %.4f/ceiling %.4f|TP dry %.2f wet %.2f dBTP|change %.1f dB|null after %.1f dB|vocal %.2f s|grid %@",
        label, id, move.kind.displayName, move.startBar, move.landingBar, move.startSeconds, move.landingSeconds, move.endSeconds,
        wetD2, ceiling, db(dryTP), db(wetTP), changed, null, vocal, (onDownbeat && startOnGrid && eventsOnGrid) ? "ok" : "OFF"))
    if wetD2 > ceiling * 1.1 { out.failures.append("\(label) \(id) \(move.kind): discontinuity \(wetD2) above ceiling \(ceiling)") }
    if db(wetTP) > max(db(dryTP) + 0.5, -0.3) { out.failures.append("\(label) \(id) \(move.kind): true peak \(db(wetTP)) dBTP (dry \(db(dryTP)))") }
    if null > -40 { out.failures.append("\(label) \(id) \(move.kind): does not return to the grid, residual \(null) dB") }
    if changed < -30 { out.failures.append("\(label) \(id) \(move.kind): move inaudible (\(changed) dB)") }
    if vocal > MixPerformancePlanner.vocalMarginSeconds { out.failures.append("\(label) \(id) \(move.kind): \(vocal) s of vocals under the move") }
    if !(onDownbeat && startOnGrid && eventsOnGrid) { out.failures.append("\(label) \(id) \(move.kind): off the grid") }
    if write {
        let clipFrom = frame(move.startSeconds - 10)
        let clipTo = min(wet.left.count, frame(move.endSeconds + 8))
        let clip = Render(left: Array(wet.left[max(0, clipFrom)..<clipTo]), right: Array(wet.right[max(0, clipFrom)..<clipTo]), startSeconds: from + Double(max(0, clipFrom)) / sr)
        let dryClip = Render(left: Array(dry.left[max(0, clipFrom)..<clipTo]), right: Array(dry.right[max(0, clipFrom)..<clipTo]), startSeconds: clip.startSeconds)
        let name = "\(label)-\(id)"
        let wav = outputDirectory.appendingPathComponent("\(name).wav")
        try writeWav(clip, to: wav)
        plot(wet: clip, dry: dryClip, move: move, title: name, to: outputDirectory.appendingPathComponent("\(name).png"))
        out.lines.append(String(format: "WAV|%@|move at %.1f s, lands at %.1f s|%@", name, move.startSeconds - clip.startSeconds, move.landingSeconds - clip.startSeconds, wav.path))
    }
    return out
}

var tracks: [String: MixPerformanceTrack] = [:]
var failures: [String] = []

do {
    let bar = 60.0 / 124 * 4
    let downbeats = (0..<200).map { Double($0) * bar }
    let free = downbeats[100]...downbeats[140]
    var synthetic = MixPerformanceTrack(
        trackId: "synthetic", duration: 200 * bar, downbeats: downbeats,
        vocals: [0...(free.lowerBound - 0.01), (free.upperBound + 0.01)...(200 * bar)],
        barLevel: (0..<200).map { $0 % 32 >= 28 ? -18 : -10 }, barDensity: Array(repeating: 0.4, count: 200), barLoop: Array(repeating: 0.9, count: 200)
    )
    let playable = 0...(200 * bar)
    var planned = 0
    for seed in 0..<300 {
        for level in MixPerformanceLevel.allCases {
            let moves = MixPerformancePlanner.plan(.init(track: synthetic, level: level, playable: playable, seed: UInt64(seed + 1)))
            planned += moves.count
            if level == .off, !moves.isEmpty { failures.append("synthetic: Off planned a move") }
            if moves.count > level.maximumMoves { failures.append("synthetic: \(level) planned \(moves.count) moves") }
            for move in moves {
                if !(move.startSeconds >= free.lowerBound && move.endSeconds <= free.upperBound) { failures.append("synthetic: \(move.kind) at bar \(move.landingBar) is outside the vocal-free bars") }
                if !synthetic.isPhraseStart(move.landingBar) { failures.append("synthetic: \(move.kind) lands off a phrase") }
            }
            for (a, b) in zip(moves, moves.dropFirst()) where b.landingBar - a.landingBar < level.minimumGapBars {
                failures.append("synthetic: moves \(b.landingBar - a.landingBar) bars apart")
            }
            let avoided = MixPerformancePlanner.plan(.init(track: synthetic, level: level, playable: playable, avoiding: [free], seed: UInt64(seed + 1)))
            if !avoided.isEmpty { failures.append("synthetic: planned inside an avoided window") }
        }
    }
    synthetic.vocals = nil
    if !MixPerformancePlanner.plan(.init(track: synthetic, level: .lively, playable: playable, seed: 3)).isEmpty { failures.append("synthetic: planned without measured vocals") }
    print("SYNTHETIC|\(planned) moves planned over 300 seeds, all inside the 40 vocal-free bars, phrase-aligned, gaps respected")
}
for id in ids {
    let url = sourceDirectory.appendingPathComponent("\(id).wav")
    let result = try await analysis(id)
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let track = performanceTrack(id, result, duration: duration)
    tracks[id] = track
    let vocals = (track.vocals ?? []).map { String(format: "%.0f-%.0f", $0.lowerBound, $0.upperBound) }.joined(separator: " ")
    print("TRACK|\(id)|bpm \(String(format: "%.1f", result.bpm ?? 0))|bars \(track.downbeats.count)|profile \(track.barLevel != nil)|vocals \(track.vocals == nil ? "unmeasured" : vocals)")
}

func playable(_ track: MixPerformanceTrack) -> ClosedRange<TimeInterval> { 20...(track.duration - 40) }

for level in [MixPerformanceLevel.subtle, .lively] {
    var counts: [MixPerformanceMove.Kind: Int] = [:]
    var tracksWithMoves = 0
    var totalTracks = 0
    for id in ids {
        guard let track = tracks[id] else { continue }
        for variant in 0..<50 {
            totalTracks += 1
            let moves = MixPerformancePlanner.plan(.init(track: track, level: level, playable: playable(track), seed: MixPerformancePlanner.seed("\(id)-\(variant)")))
            if !moves.isEmpty { tracksWithMoves += 1 }
            for move in moves { counts[move.kind, default: 0] += 1 }
        }
    }
    let summary = MixPerformanceMove.Kind.allCases.map { "\($0.displayName) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    print("RATE|\(level.displayName)|\(tracksWithMoves)/\(totalTracks) track plays get a move|\(summary)")
}

for id in ids {
    guard let track = tracks[id] else { continue }
    let url = sourceDirectory.appendingPathComponent("\(id).wav")
    for level in [MixPerformanceLevel.subtle, .lively] {
        let moves = MixPerformancePlanner.plan(.init(track: track, level: level, playable: playable(track)))
        print("PLAN|\(level.displayName)|\(id)|" + (moves.isEmpty ? "none" : moves.map { String(format: "%@ bars %d->%d", $0.kind.displayName, $0.startBar, $0.landingBar) }.joined(separator: ", ")))
        for move in moves {
            let result = try gate(id, url, move, track, label: "plan-\(level.rawValue)", write: false)
            result.lines.forEach { print("GATE|" + $0) }
            failures += result.failures
        }
    }
}

let pack: [(MixPerformanceMove.Kind, String, MixPerformanceLevel)] = [
    (.loopRoll, "1-loop-roll", .lively),
    (.highPassBuild, "2-filter-build", .subtle),
    (.lowPassDip, "3-filter-dip", .subtle),
    (.echoThrow, "4-echo-throw", .subtle)
]
var used = Set<String>()
for (kind, label, level) in pack {
    var best: (String, MixPerformanceMove, Double)?
    for id in ids {
        guard let track = tracks[id] else { continue }
        let request = MixPerformancePlanner.Request(track: track, level: level, playable: playable(track))
        for bar in track.barsPerPhrase..<(track.downbeats.count - 2) where track.isPhraseStart(bar) {
            guard let move = MixPerformancePlanner.shape(kind, landingBar: bar, track: track, level: level),
                  MixPerformancePlanner.admits(move, request: request),
                  let score = MixPerformancePlanner.score(move, track: track, level: level) else { continue }
            let adjusted = score * (used.contains(id) ? 0.5 : 1) + (move.startSeconds > track.duration * 0.3 ? 0.01 : 0)
            if best == nil || adjusted > best!.2 { best = (id, move, adjusted) }
        }
    }
    guard let (id, move, _) = best, let track = tracks[id] else {
        print("PACK|\(label)|no admissible place on any track")
        continue
    }
    used.insert(id)
    let result = try gate(id, sourceDirectory.appendingPathComponent("\(id).wav"), move, track, label: label, write: true)
    result.lines.forEach { print("PACK|" + $0) }
    failures += result.failures
}

print(failures.isEmpty ? "GATES|pass" : "GATES|FAIL\n" + failures.joined(separator: "\n"))
exit(failures.isEmpty ? 0 : 1)
