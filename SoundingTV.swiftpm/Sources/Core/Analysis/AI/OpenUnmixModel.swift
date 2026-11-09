#if canImport(MLX)
import Foundation
import MLX

enum StemKind: String, CaseIterable, Codable, Sendable {
    case vocals, drums, bass, other
}

struct OpenUnmixStem {
    let inputMean: MLXArray
    let inputScale: MLXArray
    let outputMean: MLXArray
    let outputScale: MLXArray
    let fc1T: MLXArray
    let bn1: BeatThisBatchNorm
    let fc2T: MLXArray
    let bn2: BeatThisBatchNorm
    let fc3T: MLXArray
    let bn3: BeatThisBatchNorm
    let ihT: [[MLXArray]]
    let hhT: [[MLXArray]]
    let bias: [[MLXArray]]

    init(url: URL) throws {
        let file = try AITensorFile(url: url)
        let bins = OpenUnmixModel.maxBin, full = OpenUnmixModel.bins
        inputMean = try file.tensor("input_mean", [bins])
        inputScale = try file.tensor("input_scale", [bins])
        outputMean = try file.tensor("output_mean", [full])
        outputScale = try file.tensor("output_scale", [full])
        fc1T = try file.tensor("fc1.weight", [512, bins * 2]).transposed()
        bn1 = try BeatThisBatchNorm(file, "bn1", 512)
        fc2T = try file.tensor("fc2.weight", [512, 1024]).transposed()
        bn2 = try BeatThisBatchNorm(file, "bn2", 512)
        fc3T = try file.tensor("fc3.weight", [full * 2, 512]).transposed()
        bn3 = try BeatThisBatchNorm(file, "bn3", full * 2)
        var ih: [[MLXArray]] = [], hh: [[MLXArray]] = [], b: [[MLXArray]] = []
        for layer in 0..<3 {
            var li: [MLXArray] = [], lh: [MLXArray] = [], lb: [MLXArray] = []
            for direction in ["forward", "backward"] {
                let p = "lstm.layers.\(layer).\(direction)"
                li.append(try file.tensor("\(p).weight_ih", [1024, 512]).transposed())
                lh.append(try file.tensor("\(p).weight_hh", [1024, 256]).transposed())
                lb.append(try file.tensor("\(p).bias_ih", [1024]) + file.tensor("\(p).bias_hh", [1024]))
            }
            ih.append(li); hh.append(lh); b.append(lb)
        }
        ihT = ih; hhT = hh; bias = b
    }

    func encode(_ magnitude: MLXArray) -> MLXArray {
        let b = magnitude.dim(0), t = magnitude.dim(1)
        let cropped = magnitude[.ellipsis, 0..<OpenUnmixModel.maxBin]
        let x = ((cropped + inputMean) * inputScale).reshaped(b, t, OpenUnmixModel.maxBin * 2)
        return tanh(bn1(matmul(x, fc1T)))
    }

    func decode(_ encoded: MLXArray, _ recurrent: MLXArray, magnitude: MLXArray) -> MLXArray {
        let b = magnitude.dim(0), t = magnitude.dim(1)
        var x = concatenated([encoded, recurrent], axis: -1)
        x = maximum(bn2(matmul(x, fc2T)), 0)
        x = bn3(matmul(x, fc3T)).reshaped(b, t, 2, OpenUnmixModel.bins)
        x = x * outputScale + outputMean
        return maximum(x, 0) * magnitude
    }
}

final class OpenUnmixModel: @unchecked Sendable {
    static let sampleRate = 44_100.0
    static let fft = 4096
    static let hop = 1024
    static let bins = 2049
    static let maxBin = 1487
    static let chunkFrames = 512
    static let contextFrames = 48
    static let batch = 8

    let stems: [OpenUnmixStem]
    private let window: MLXArray
    private let ih: [[MLXArray]]
    private let hh: [MLXArray]
    private let bias: [[MLXArray]]

    init(directory: URL) throws {
        let loaded = try StemKind.allCases.map { try OpenUnmixStem(url: directory.appendingPathComponent("\($0.rawValue).safetensors")) }
        stems = loaded
        window = MLXArray((0..<Self.fft).map { i in 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(Self.fft)) })
        let ih = (0..<3).map { l in (0..<2).map { d in stacked(loaded.map { $0.ihT[l][d] }).expandedDimensions(axis: 1) } }
        let hh = (0..<3).map { l in concatenated((0..<2).map { d in stacked(loaded.map { $0.hhT[l][d] }) }, axis: 0) }
        let bias = (0..<3).map { l in (0..<2).map { d in stacked(loaded.map { $0.bias[l][d] }).reshaped(4, 1, 1, 1024) } }
        eval(ih.flatMap { $0 } + hh + bias.flatMap { $0 })
        self.ih = ih
        self.hh = hh
        self.bias = bias
    }

    private func recurrent(_ input: MLXArray) -> MLXArray {
        let steps = input.dim(2), groups = input.dim(0) * 2, b = input.dim(1)
        let reversed = MLXArray((0..<steps).reversed().map { Int32($0) })
        var y = input
        for layer in 0..<3 {
            let forward = matmul(y, ih[layer][0]) + bias[layer][0]
            let backward = (matmul(y, ih[layer][1]) + bias[layer][1]).take(reversed, axis: 2)
            let projected = concatenated([forward, backward], axis: 0)
            eval(projected)
            var h = MLXArray.zeros([groups, b, 256])
            var c = MLXArray.zeros([groups, b, 256])
            var outputs: [MLXArray] = []
            outputs.reserveCapacity(steps)
            for t in 0..<steps {
                let gates = projected[0..., 0..., t, 0...] + matmul(h, hh[layer])
                let parts = split(gates, parts: 4, axis: -1)
                c = sigmoid(parts[1]) * c + sigmoid(parts[0]) * tanh(parts[2])
                h = sigmoid(parts[3]) * tanh(c)
                outputs.append(h)
                if t % 64 == 63 { eval(h, c) }
            }
            let all = stacked(outputs, axis: 2)
            let halves = split(all, parts: 2, axis: 0)
            y = concatenated([halves[0], halves[1].take(reversed, axis: 2)], axis: -1)
            eval(y)
        }
        return y
    }

    func energies(left: [Float], right: [Float], origin: Int, ranges: [Range<Int>]) -> [[[Float]]] {
        let span = Self.chunkFrames + 2 * Self.contextFrames
        var buffer = [Float](repeating: 0, count: ranges.count * span * 2 * Self.fft)
        for (k, range) in ranges.enumerated() {
            let first = range.lowerBound - Self.contextFrames
            for f in 0..<span {
                let start = (first + f) * Self.hop - Self.fft / 2 - origin
                for (c, plane) in [left, right].enumerated() {
                    let base = ((k * span + f) * 2 + c) * Self.fft
                    let lo = max(0, start), hi = min(plane.count, start + Self.fft)
                    guard hi > lo else { continue }
                    plane.withUnsafeBufferPointer { src in
                        buffer.withUnsafeMutableBufferPointer { dst in
                            dst.baseAddress!.advanced(by: base + lo - start).update(from: src.baseAddress!.advanced(by: lo), count: hi - lo)
                        }
                    }
                }
            }
        }
        return autoreleasepool {
            let magnitude = abs(rfft(MLXArray(buffer, [ranges.count, span, 2, Self.fft]) * window, axis: -1))
            let encoded = stems.map { $0.encode(magnitude) }
            let recurrentOut = recurrent(stacked(encoded, axis: 0))
            var estimates: [MLXArray] = []
            for (s, stem) in stems.enumerated() {
                let estimate = stem.decode(encoded[s], recurrentOut[s], magnitude: magnitude)
                eval(estimate)
                estimates.append(estimate)
            }
            let total = estimates.reduce(MLXArray(Float(1e-10)), +)
            let keep = Self.contextFrames..<(Self.contextFrames + Self.chunkFrames)
            var energies: [MLXArray] = estimates.map { e in
                let masked = e / total * magnitude
                return (masked * masked).sum(axes: [2, 3])[0..., keep]
            }
            energies.append((magnitude * magnitude).sum(axes: [2, 3])[0..., keep])
            let result = stacked(energies, axis: -1)
            eval(result)
            let flat = result.asArray(Float.self)
            Memory.clearCache()
            return ranges.enumerated().map { k, range in
                (0..<range.count).map { i in
                    let o = (k * Self.chunkFrames + i) * 5
                    return Array(flat[o..<(o + 5)])
                }
            }
        }
    }
}

struct StemEnergyCurve: Codable, Sendable, Equatable {
    static let framesPerSecond = OpenUnmixModel.sampleRate / Double(OpenUnmixModel.hop)
    var vocals: [Float] = []
    var drums: [Float] = []
    var bass: [Float] = []
    var other: [Float] = []
    var mix: [Float] = []

    var count: Int { mix.count }

    mutating func append(_ frame: [Float]) {
        vocals.append(frame[0]); drums.append(frame[1]); bass.append(frame[2]); other.append(frame[3]); mix.append(frame[4])
    }

    func curve(_ kind: StemKind) -> [Float] {
        switch kind {
        case .vocals: vocals
        case .drums: drums
        case .bass: bass
        case .other: other
        }
    }
}

enum OpenUnmixAnalyzer {
    static func analyze(fileURL: URL, model: OpenUnmixModel, shouldContinue: @escaping () -> Bool = { true }) throws -> StemEnergyCurve? {
        let stream = AIAudioStream(url: fileURL, sampleRate: OpenUnmixModel.sampleRate, channels: 2)
        let hop = OpenUnmixModel.hop, chunk = OpenUnmixModel.chunkFrames, context = OpenUnmixModel.contextFrames
        var left: [Float] = [], right: [Float] = []
        var origin = 0
        var nextFrame = 0
        var curve = StemEnergyCurve()
        var cancelled = false

        func process(final: Bool) {
            while true {
                let available = origin + left.count
                let totalFrames = available / hop + 1
                var ranges: [Range<Int>] = []
                var frame = nextFrame
                while ranges.count < OpenUnmixModel.batch {
                    let needed = (frame + chunk + context) * hop + OpenUnmixModel.fft / 2
                    if final {
                        if frame >= totalFrames { break }
                        ranges.append(frame..<min(frame + chunk, totalFrames))
                    } else {
                        if needed > available { break }
                        ranges.append(frame..<(frame + chunk))
                    }
                    frame += chunk
                }
                if ranges.isEmpty || (!final && ranges.count < OpenUnmixModel.batch) { return }
                for chunkFrames in model.energies(left: left, right: right, origin: origin, ranges: ranges) {
                    for f in chunkFrames { curve.append(f) }
                }
                nextFrame = frame
                let keepFrom = min(left.count, (nextFrame - context) * hop - OpenUnmixModel.fft / 2 - origin)
                if keepFrom > 0 {
                    left.removeFirst(keepFrom); right.removeFirst(keepFrom)
                    origin += keepFrom
                }
                if !shouldContinue() { cancelled = true; return }
            }
        }

        try stream.read { planes in
            left += planes[0]
            right += planes[1]
            process(final: false)
            return !cancelled
        }
        if cancelled { return nil }
        process(final: true)
        return cancelled ? nil : curve
    }
}

struct StemTimeline: Codable, Sendable, Equatable {
    struct Span: Codable, Sendable, Equatable {
        let start: Double
        let end: Double
    }

    let vocalRanges: [Span]
    let drumsOnlyRanges: [Span]
    let bassRanges: [Span]
    let bassEntries: [Double]
    let bassExits: [Double]

    static func shares(_ curve: StemEnergyCurve, window seconds: Double) -> (times: [Double], share: [StemKind: [Double]], level: [Double]) {
        let w = max(1, Int(seconds * StemEnergyCurve.framesPerSecond))
        var times: [Double] = [], level: [Double] = []
        var share: [StemKind: [Double]] = [:]
        var i = 0
        while i < curve.count {
            let r = i..<min(curve.count, i + w)
            let sums = StemKind.allCases.map { k in Double(curve.curve(k)[r].reduce(0, +)) }
            let total = max(sums.reduce(0, +), 1e-12)
            for (k, s) in zip(StemKind.allCases, sums) { share[k, default: []].append(s / total) }
            level.append(10 * log10(total / Double(r.count) + 1e-12))
            times.append(Double(i) / StemEnergyCurve.framesPerSecond)
            i += w
        }
        return (times, share, level)
    }

    static func spans(_ flags: [Bool], times: [Double], step: Double, minimum: Double, bridge: Double) -> [Span] {
        var raw: [Span] = []
        var start: Double?
        for (i, on) in flags.enumerated() {
            if on, start == nil { start = times[i] }
            if !on, let s = start { raw.append(Span(start: s, end: times[i])); start = nil }
        }
        if let s = start, let last = times.last { raw.append(Span(start: s, end: last + step)) }
        var merged: [Span] = []
        for span in raw {
            if let previous = merged.last, span.start - previous.end <= bridge {
                merged[merged.count - 1] = Span(start: previous.start, end: span.end)
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.end - $0.start >= minimum }
    }

    init(_ curve: StemEnergyCurve) {
        let step = 0.5
        let (times, share, level) = Self.shares(curve, window: step)
        let peak = level.max() ?? 0
        let audible = level.map { $0 > peak - 30 }
        let vocals = share[.vocals] ?? [], drums = share[.drums] ?? [], bass = share[.bass] ?? [], other = share[.other] ?? []
        let vocalFlags = vocals.indices.map { audible[$0] && vocals[$0] > 0.12 }
        let drumFlags = drums.indices.map { audible[$0] && drums[$0] > 0.6 && vocals[$0] + other[$0] < 0.15 && bass[$0] < 0.2 }
        let bassFlags = bass.indices.map { audible[$0] && bass[$0] > 0.15 }
        vocalRanges = Self.spans(vocalFlags, times: times, step: step, minimum: 1.5, bridge: 1.0)
        drumsOnlyRanges = Self.spans(drumFlags, times: times, step: step, minimum: 4, bridge: 0.5)
        bassRanges = Self.spans(bassFlags, times: times, step: step, minimum: 2, bridge: 1.0)
        bassEntries = bassRanges.map(\.start)
        bassExits = bassRanges.map(\.end)
    }

    func bassOverlap(with incoming: StemTimeline, incomingStartsAt offset: Double, window: ClosedRange<Double>) -> Double {
        var overlap = 0.0
        for a in bassRanges {
            for b in incoming.bassRanges {
                let lo = max(a.start, b.start + offset, window.lowerBound)
                let hi = min(a.end, b.end + offset, window.upperBound)
                if hi > lo { overlap += hi - lo }
            }
        }
        return overlap
    }

    func snapped(_ spans: [Span], to downbeats: [Double]) -> [Span] {
        guard !downbeats.isEmpty else { return spans }
        func snap(_ t: Double) -> Double { downbeats.min { abs($0 - t) < abs($1 - t) }! }
        return spans.compactMap { s in
            let a = snap(s.start), b = snap(s.end)
            return b > a ? Span(start: a, end: b) : nil
        }
    }
}
#endif
