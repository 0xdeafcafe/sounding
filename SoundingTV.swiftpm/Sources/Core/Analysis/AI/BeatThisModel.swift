#if canImport(MLX)
import Foundation
import MLX

enum AIModelError: Error, Equatable {
    case missingTensor(String)
    case wrongShape(String, [Int])
    case unsupportedFile(String)
}

struct AITensorFile {
    let tensors: [String: MLXArray]

    init(url: URL) throws {
        guard url.pathExtension == "safetensors" else { throw AIModelError.unsupportedFile(url.lastPathComponent) }
        tensors = try loadArrays(url: url)
    }

    func tensor(_ name: String, _ shape: [Int]) throws -> MLXArray {
        guard let value = tensors[name] else { throw AIModelError.missingTensor(name) }
        guard value.shape == shape else { throw AIModelError.wrongShape(name, value.shape) }
        return value.asType(.float32)
    }
}

enum AIOps {
    static func gelu(_ x: MLXArray) -> MLXArray {
        x * 0.5 * (1 + erf(x * Float(1 / 2.0.squareRoot())))
    }

    static func rmsNorm(_ x: MLXArray, _ gamma: MLXArray) -> MLXArray {
        let d = Float(x.dim(-1))
        let norm = maximum(sqrt((x * x).sum(axis: -1, keepDims: true)), MLXArray(Float(1e-12)))
        return x / norm * d.squareRoot() * gamma
    }

    static func linear(_ x: MLXArray, _ weightT: MLXArray, _ bias: MLXArray? = nil) -> MLXArray {
        let y = matmul(x, weightT)
        guard let bias else { return y }
        return y + bias
    }
}

struct BeatThisBatchNorm {
    let scale: MLXArray
    let shift: MLXArray

    init(_ file: AITensorFile, _ prefix: String, _ size: Int) throws {
        let weight = try file.tensor("\(prefix).weight", [size])
        let bias = try file.tensor("\(prefix).bias", [size])
        let mean = try file.tensor("\(prefix).running_mean", [size])
        let variance = try file.tensor("\(prefix).running_var", [size])
        scale = weight * rsqrt(variance + 1e-5)
        shift = bias - mean * scale
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { x * scale + shift }
}

struct BeatThisAttention {
    let heads: Int
    let headDim: Int
    let norm: MLXArray
    let qkvT: MLXArray
    let gatesT: MLXArray
    let gatesBias: MLXArray
    let outT: MLXArray

    init(_ file: AITensorFile, _ prefix: String, dim: Int, headDim: Int) throws {
        heads = dim / headDim
        self.headDim = headDim
        norm = try file.tensor("\(prefix).norm.gamma", [dim])
        qkvT = try file.tensor("\(prefix).to_qkv.weight", [dim * 3, dim]).transposed()
        gatesT = try file.tensor("\(prefix).to_gates.weight", [heads, dim]).transposed()
        gatesBias = try file.tensor("\(prefix).to_gates.bias", [heads])
        outT = try file.tensor("\(prefix).to_out.0.weight", [dim, dim]).transposed()
    }

    func callAsFunction(_ x: MLXArray, rope: BeatThisRotary) -> MLXArray {
        let b = x.dim(0), n = x.dim(1)
        let xn = AIOps.rmsNorm(x, norm)
        let qkv = AIOps.linear(xn, qkvT).reshaped(b, n, 3, heads, headDim).transposed(2, 0, 3, 1, 4)
        let q = rope.apply(qkv[0], length: n)
        let k = rope.apply(qkv[1], length: n)
        let v = qkv[2]
        var out = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1 / Float(headDim).squareRoot(), mask: nil)
        let gates = sigmoid(AIOps.linear(xn, gatesT, gatesBias)).transposed(0, 2, 1).expandedDimensions(axis: -1)
        out = (out * gates).transposed(0, 2, 1, 3).reshaped(b, n, heads * headDim)
        return AIOps.linear(out, outT)
    }
}

struct BeatThisFeedForward {
    let norm: MLXArray
    let w1T: MLXArray
    let b1: MLXArray
    let w2T: MLXArray
    let b2: MLXArray

    init(_ file: AITensorFile, _ prefix: String, dim: Int, mult: Int = 4) throws {
        norm = try file.tensor("\(prefix).net.0.gamma", [dim])
        w1T = try file.tensor("\(prefix).net.1.weight", [dim * mult, dim]).transposed()
        b1 = try file.tensor("\(prefix).net.1.bias", [dim * mult])
        w2T = try file.tensor("\(prefix).net.4.weight", [dim, dim * mult]).transposed()
        b2 = try file.tensor("\(prefix).net.4.bias", [dim])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        AIOps.linear(AIOps.gelu(AIOps.linear(AIOps.rmsNorm(x, norm), w1T, b1)), w2T, b2)
    }
}

final class BeatThisRotary {
    let freqs: MLXArray
    private var cache: [Int: (MLXArray, MLXArray)] = [:]
    private let lock = NSLock()

    init(freqs: MLXArray) { self.freqs = freqs }

    func apply(_ x: MLXArray, length: Int) -> MLXArray {
        let (cos, sin) = tables(length)
        let shape = x.shape
        let pairs = x.reshaped(Array(shape.dropLast()) + [shape.last! / 2, 2])
        let x1 = pairs[.ellipsis, 0]
        let x2 = pairs[.ellipsis, 1]
        let rotated = stacked([-x2, x1], axis: -1).reshaped(shape)
        return x * cos + rotated * sin
    }

    private func tables(_ length: Int) -> (MLXArray, MLXArray) {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[length] { return hit }
        let positions = MLXArray(0..<length).asType(.float32).expandedDimensions(axis: 1)
        let angles = positions * freqs.expandedDimensions(axis: 0)
        let interleaved = stacked([angles, angles], axis: -1).reshaped(length, freqs.dim(0) * 2)
        let result = (MLX.cos(interleaved), MLX.sin(interleaved))
        eval(result.0, result.1)
        cache[length] = result
        return result
    }
}

struct BeatThisFrontendBlock {
    let attnF: BeatThisAttention
    let ffF: BeatThisFeedForward
    let attnT: BeatThisAttention
    let ffT: BeatThisFeedForward
    let conv: MLXArray
    let norm: BeatThisBatchNorm

    init(_ file: AITensorFile, index: Int, dim: Int, headDim: Int) throws {
        let p = "frontend.blocks.\(index)"
        attnF = try BeatThisAttention(file, "\(p).partial.attnF", dim: dim, headDim: headDim)
        ffF = try BeatThisFeedForward(file, "\(p).partial.ffF", dim: dim)
        attnT = try BeatThisAttention(file, "\(p).partial.attnT", dim: dim, headDim: headDim)
        ffT = try BeatThisFeedForward(file, "\(p).partial.ffT", dim: dim)
        conv = try file.tensor("\(p).conv2d.weight", [dim * 2, dim, 2, 3]).transposed(0, 2, 3, 1)
        norm = try BeatThisBatchNorm(file, "\(p).norm", dim * 2)
    }

    func callAsFunction(_ input: MLXArray, rope: BeatThisRotary) -> MLXArray {
        let b = input.dim(0), f = input.dim(1), t = input.dim(2), c = input.dim(3)
        var x = input.transposed(0, 2, 1, 3).reshaped(b * t, f, c)
        x = x + attnF(x, rope: rope)
        x = x + ffF(x)
        x = x.reshaped(b, t, f, c).transposed(0, 2, 1, 3).reshaped(b * f, t, c)
        x = x + attnT(x, rope: rope)
        x = x + ffT(x)
        x = x.reshaped(b, f, t, c)
        x = conv2d(x, conv, stride: [2, 1], padding: [0, 1])
        return AIOps.gelu(norm(x))
    }
}

final class BeatThisModel: @unchecked Sendable {
    static let specBins = 128
    static let fps = 50.0
    static let chunkFrames = 1500
    static let borderFrames = 6

    let bn1d: BeatThisBatchNorm
    let stemConv: MLXArray
    let bn2d: BeatThisBatchNorm
    let blocks: [BeatThisFrontendBlock]
    let projT: MLXArray
    let projBias: MLXArray
    let layers: [(BeatThisAttention, BeatThisFeedForward)]
    let finalNorm: MLXArray
    let headT: MLXArray
    let headBias: MLXArray
    let rope: BeatThisRotary

    init(weights url: URL) throws {
        let file = try AITensorFile(url: url)
        bn1d = try BeatThisBatchNorm(file, "frontend.stem.bn1d", 128)
        stemConv = try file.tensor("frontend.stem.conv2d.weight", [32, 1, 4, 3]).transposed(0, 2, 3, 1)
        bn2d = try BeatThisBatchNorm(file, "frontend.stem.bn2d", 32)
        blocks = try (0..<3).map { try BeatThisFrontendBlock(file, index: $0, dim: 32 << $0, headDim: 32) }
        projT = try file.tensor("frontend.linear.weight", [512, 1024]).transposed()
        projBias = try file.tensor("frontend.linear.bias", [512])
        layers = try (0..<6).map { i in
            (try BeatThisAttention(file, "transformer_blocks.layers.\(i).0", dim: 512, headDim: 32),
             try BeatThisFeedForward(file, "transformer_blocks.layers.\(i).1", dim: 512))
        }
        finalNorm = try file.tensor("transformer_blocks.norm.gamma", [512])
        headT = try file.tensor("task_heads.beat_downbeat_lin.weight", [2, 512]).transposed()
        headBias = try file.tensor("task_heads.beat_downbeat_lin.bias", [2])
        rope = BeatThisRotary(freqs: try file.tensor("frontend.blocks.0.partial.attnF.rotary_embed.freqs", [16]))
        var all: [MLXArray] = [stemConv, projT, projBias, finalNorm, headT, headBias]
        all += [bn1d.scale, bn1d.shift, bn2d.scale, bn2d.shift]
        eval(all)
    }

    func logits(_ spect: MLXArray) -> (beat: MLXArray, downbeat: MLXArray) {
        var x = bn1d(spect).transposed(0, 2, 1).expandedDimensions(axis: -1)
        x = conv2d(x, stemConv, stride: [4, 1], padding: [0, 1])
        x = AIOps.gelu(bn2d(x))
        for block in blocks { x = block(x, rope: rope) }
        let b = x.dim(0), t = x.dim(2)
        x = x.transposed(0, 2, 3, 1).reshaped(b, t, x.dim(3) * x.dim(1))
        x = AIOps.linear(x, projT, projBias)
        for (attention, feedForward) in layers {
            x = attention(x, rope: rope) + x
            x = feedForward(x) + x
        }
        x = AIOps.rmsNorm(x, finalNorm)
        let out = AIOps.linear(x, headT, headBias)
        let downbeat = out[.ellipsis, 1]
        return (out[.ellipsis, 0] + downbeat, downbeat)
    }

    func frameLogits(spect: [Float], frames: Int, shouldContinue: () -> Bool = { true }) -> (beat: [Float], downbeat: [Float])? {
        let chunk = Self.chunkFrames, border = Self.borderFrames
        var starts = Array(stride(from: -border, to: frames - border, by: chunk - 2 * border))
        if frames > chunk - 2 * border, !starts.isEmpty { starts[starts.count - 1] = frames - (chunk - border) }
        var beat = [Float](repeating: -1000, count: frames)
        var downbeat = [Float](repeating: -1000, count: frames)
        for start in starts.reversed() {
            guard shouldContinue() else { return nil }
            let lo = max(start, 0), hi = min(start + chunk, frames)
            let left = max(0, -start)
            let right = max(0, min(border, start + chunk - frames))
            var input = [Float](repeating: 0, count: (left + hi - lo + right) * Self.specBins)
            spect.withUnsafeBufferPointer { source in
                input.withUnsafeMutableBufferPointer { dest in
                    let count = (hi - lo) * Self.specBins
                    dest.baseAddress!.advanced(by: left * Self.specBins).update(from: source.baseAddress!.advanced(by: lo * Self.specBins), count: count)
                }
            }
            let length = input.count / Self.specBins
            let result = autoreleasepool { () -> ([Float], [Float]) in
                let (b, d) = logits(MLXArray(input, [1, length, Self.specBins]))
                eval(b, d)
                return (b.reshaped(-1).asArray(Float.self), d.reshaped(-1).asArray(Float.self))
            }
            let keepFrom = border, keepTo = length - border
            guard keepTo > keepFrom else { continue }
            for i in keepFrom..<keepTo {
                let target = start + i
                guard target >= 0, target < frames else { continue }
                beat[target] = result.0[i]
                downbeat[target] = result.1[i]
            }
            Memory.clearCache()
        }
        return (beat, downbeat)
    }
}

final class BeatThisSpectrogram {
    static let sampleRate = 22_050.0
    static let fft = 1024
    static let hop = 441

    private let filterbank: MLXArray
    private let window: MLXArray
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var nextFrame = 0
    private var originalSamples = 0
    private var padded = false
    private(set) var output: [Float] = []

    var frames: Int { output.count / BeatThisModel.specBins }

    init() {
        filterbank = MLXArray(Self.melFilterbank(), [Self.fft / 2 + 1, BeatThisModel.specBins])
        let norm = 1 / Float(Self.fft).squareRoot()
        window = MLXArray((0..<Self.fft).map { i in (0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(Self.fft))) * norm })
    }

    func push(_ samples: [Float]) {
        originalSamples += samples.count
        buffer += samples
        if !padded, buffer.count > Self.fft / 2 {
            buffer = (1...(Self.fft / 2)).reversed().map { buffer[$0] } + buffer
            padded = true
        }
        if padded { drain(final: false) }
    }

    func finish() {
        if !padded {
            guard buffer.count > Self.fft / 2 else { return }
            buffer = (1...(Self.fft / 2)).reversed().map { buffer[$0] } + buffer
            padded = true
        }
        let n = buffer.count
        buffer += (1...(Self.fft / 2)).map { buffer[n - 1 - $0] }
        drain(final: true)
    }

    private func drain(final: Bool) {
        let totalFrames = 1 + originalSamples / Self.hop
        var ready: [Int] = []
        while true {
            let begin = nextFrame * Self.hop - bufferStart
            if begin + Self.fft > buffer.count { break }
            if final, nextFrame >= totalFrames { break }
            ready.append(begin)
            nextFrame += 1
            if ready.count == 4096 { compute(ready); ready.removeAll(keepingCapacity: true) }
        }
        if !ready.isEmpty { compute(ready) }
        let drop = nextFrame * Self.hop - bufferStart
        if drop > 1 << 20 {
            buffer.removeFirst(drop)
            bufferStart += drop
        }
    }

    private func compute(_ begins: [Int]) {
        var frames = [Float](repeating: 0, count: begins.count * Self.fft)
        buffer.withUnsafeBufferPointer { source in
            frames.withUnsafeMutableBufferPointer { dest in
                for (row, begin) in begins.enumerated() {
                    dest.baseAddress!.advanced(by: row * Self.fft).update(from: source.baseAddress!.advanced(by: begin), count: Self.fft)
                }
            }
        }
        let mel = autoreleasepool { () -> [Float] in
            let x = MLXArray(frames, [begins.count, Self.fft]) * window
            let magnitude = abs(rfft(x, axis: -1))
            let result = log1p(1000 * matmul(magnitude, filterbank))
            eval(result)
            return result.reshaped(-1).asArray(Float.self)
        }
        output += mel
    }

    static func melFilterbank() -> [Float] {
        let bins = fft / 2 + 1
        let mels = BeatThisModel.specBins
        func hzToMel(_ f: Double) -> Double {
            let fsp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fsp, step = log(6.4) / 27
            return f >= minLogHz ? minLogMel + log(f / minLogHz) / step : f / fsp
        }
        func melToHz(_ m: Double) -> Double {
            let fsp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fsp, step = log(6.4) / 27
            return m >= minLogMel ? minLogHz * exp(step * (m - minLogMel)) : fsp * m
        }
        let allFreqs = (0..<bins).map { Double($0) * (sampleRate / 2) / Double(bins - 1) }
        let mMin = hzToMel(30), mMax = hzToMel(11_000)
        let points = (0..<(mels + 2)).map { melToHz(mMin + (mMax - mMin) * Double($0) / Double(mels + 1)) }
        var out = [Float](repeating: 0, count: bins * mels)
        for i in 0..<bins {
            for m in 0..<mels {
                let down = (allFreqs[i] - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - allFreqs[i]) / (points[m + 2] - points[m + 1])
                out[i * mels + m] = Float(max(0, min(down, up)))
            }
        }
        return out
    }
}

struct BeatThisResult: Codable, Sendable, Equatable {
    let beats: [Double]
    let downbeats: [Double]
    let barDownbeats: [Double]
    let bpm: Double?
    let confidence: Double
    let downbeatConfidence: Double
    let beatsPerBar: Int?
}

enum BeatThisPostprocessor {
    static func peaks(_ logits: [Float]) -> [Double] {
        let n = logits.count
        var frames: [Int] = []
        for i in 0..<n where logits[i] > 0 {
            var isMax = true
            for j in max(0, i - 3)...min(n - 1, i + 3) where logits[j] > logits[i] { isMax = false; break }
            if isMax { frames.append(i) }
        }
        var result: [Double] = []
        guard var p = frames.first.map(Double.init) else { return result }
        var c = 1.0
        var last = frames[0]
        for f in frames.dropFirst() {
            if f - last <= 1 {
                c += 1
                p += (Double(f) - p) / c
            } else {
                result.append(p)
                p = Double(f)
                c = 1
            }
            last = f
        }
        result.append(p)
        return result.map { $0 / BeatThisModel.fps }
    }

    static func process(beat: [Float], downbeat: [Float]) -> BeatThisResult {
        let beats = peaks(beat)
        var downs = peaks(downbeat)
        if !beats.isEmpty {
            downs = downs.map { d in beats.min { abs($0 - d) < abs($1 - d) }! }
        }
        downs = Array(Set(downs)).sorted()
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let median = intervals.sorted()[safe: intervals.count / 2]
        let span = min(32, max(beats.count - 1, 1))
        let spans = beats.count > span ? (0..<(beats.count - span)).map { (beats[$0 + span] - beats[$0]) / Double(span) }.sorted() : []
        let bpm = (spans[safe: spans.count / 2] ?? median).map { 60 / $0 }
        let steady = median.map { m in Double(intervals.filter { abs($0 - m) <= 0.06 * m }.count) / Double(max(intervals.count, 1)) } ?? 0
        let strength = beats.isEmpty ? 0 : beats.map { t -> Double in
            let i = min(beat.count - 1, Int((t * BeatThisModel.fps).rounded()))
            return 1 / (1 + exp(-Double(beat[i])))
        }.reduce(0, +) / Double(beats.count)
        let probabilities = beats.map { t -> Double in
            let i = min(downbeat.count - 1, Int((t * BeatThisModel.fps).rounded()))
            return 1 / (1 + exp(-Double(downbeat[i])))
        }
        var best: (meter: Int, phase: Int, score: Double, runnerUp: Double)?
        for meter in [4, 3] {
            var sums = [Double](repeating: 0, count: meter)
            for (i, p) in probabilities.enumerated() { sums[i % meter] += p }
            let order = sums.indices.sorted { sums[$0] > sums[$1] }
            let total = max(sums.reduce(0, +), 1e-9)
            let score = sums[order[0]] / total
            let runnerUp = sums[order[1]] / total
            let weighted = score * Double(meter) / 4
            if best == nil || weighted > best!.score * Double(best!.meter) / 4 {
                best = (meter, order[0], score, runnerUp)
            }
        }
        let meter = best?.meter
        let barDownbeats = best.map { b in beats.enumerated().filter { $0.offset % b.meter == b.phase }.map(\.element) } ?? []
        let onGrid = Set(barDownbeats)
        let agreement = downs.isEmpty ? 0 : Double(downs.filter { onGrid.contains($0) }.count) / Double(downs.count)
        let separation = best.map { max(0, $0.score - $0.runnerUp) / max($0.score, 1e-9) } ?? 0
        return BeatThisResult(beats: beats, downbeats: downs, barDownbeats: barDownbeats, bpm: bpm, confidence: steady * strength, downbeatConfidence: agreement * separation, beatsPerBar: meter)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum BeatThisAnalyzer {
    static func analyze(fileURL: URL, model: BeatThisModel, shouldContinue: @escaping () -> Bool = { true }) throws -> BeatThisResult? {
        let spectrogram = BeatThisSpectrogram()
        let stream = AIAudioStream(url: fileURL, sampleRate: BeatThisSpectrogram.sampleRate, channels: 1)
        var cancelled = false
        try stream.read { planes in
            guard shouldContinue() else { cancelled = true; return false }
            spectrogram.push(planes[0])
            return true
        }
        if cancelled { return nil }
        spectrogram.finish()
        guard let logits = model.frameLogits(spect: spectrogram.output, frames: spectrogram.frames, shouldContinue: shouldContinue) else { return nil }
        return BeatThisPostprocessor.process(beat: logits.beat, downbeat: logits.downbeat)
    }
}
#endif
