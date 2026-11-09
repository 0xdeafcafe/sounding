#if canImport(Metal) && !os(watchOS)
import Accelerate
import Foundation
import Metal

enum AnalysisMel {
    static let fftSize = 1024
    static let hop = 441
    static let bands = 64
    static let framesPerSecond = BeatTracker.sampleRate / Double(hop)
    static let lowHz = 30.0
    static let highHz = 11_000.0

    static func filterbank() -> (ranges: [UInt32], weights: [Float]) {
        let bins = fftSize / 2
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(lowHz), hi = mel(highHz)
        let edges = (0...(bands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
        let step = BeatTracker.sampleRate / Double(fftSize)
        var ranges = [UInt32](repeating: 0, count: bands * 2)
        var weights = [Float](repeating: 0, count: bands * bins)
        for b in 0..<bands {
            let left = edges[b], centre = edges[b + 1], right = edges[b + 2]
            var first = bins, last = 0
            for k in 1..<bins {
                let f = Double(k) * step
                let w = f <= centre ? (f - left) / (centre - left) : (right - f) / (right - centre)
                guard w > 0 else { continue }
                weights[b * bins + k] = Float(w)
                first = min(first, k)
                last = max(last, k + 1)
            }
            if first >= last {
                let k = min(bins - 1, max(1, Int((centre / step).rounded())))
                weights[b * bins + k] = 1
                first = k
                last = k + 1
            }
            ranges[2 * b] = UInt32(first)
            ranges[2 * b + 1] = UInt32(last)
        }
        return (ranges, weights)
    }
}

enum GPUModelShaders {
    static let source = """

    struct MelParams {
        uint frameCount;
        uint hop;
        uint bands;
    };

    kernel void melFrames(
        device const float *samples [[buffer(0)]],
        device const float *window [[buffer(1)]],
        device const float2 *twiddle [[buffer(2)]],
        constant MelParams &p [[buffer(3)]],
        device const uint2 *ranges [[buffer(4)]],
        device const float *weights [[buffer(5)]],
        device half *mel [[buffer(6)]],
        uint group [[threadgroup_position_in_grid]],
        uint tid [[thread_position_in_threadgroup]],
        uint threads [[threads_per_threadgroup]]
    ) {
        const uint size = 1024;
        const uint m = 512;
        const uint bits = 9;
        threadgroup float2 z[512];
        threadgroup float power[512];
        if (group >= p.frameCount) { return; }
        int end = int(group * p.hop + size);
        loadPacked(samples, end, size, bits, window, z, tid, threads);
        complexFFT(z, twiddle, m, bits, tid, threads);
        for (uint bin = tid; bin < m; bin += threads) {
            float a = realMagnitude(z, twiddle, bin, m);
            power[bin] = a * a;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint b = tid; b < p.bands; b += threads) {
            uint2 r = ranges[b];
            float s = 0;
            for (uint k = r.x; k < r.y; k++) { s += weights[b * m + k] * power[k]; }
            mel[group * p.bands + b] = half(log(s + 1e-4f));
        }
    }

    struct AffineParams {
        uint count;
        uint channels;
    };

    kernel void normaliseInput(
        device const half *x [[buffer(0)]],
        device const float *mean [[buffer(1)]],
        device const float *scale [[buffer(2)]],
        constant AffineParams &p [[buffer(3)]],
        device float *y [[buffer(4)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= p.count) { return; }
        uint c = gid % p.channels;
        y[gid] = (float(x[gid]) - mean[c]) * scale[c];
    }

    struct ConvParams {
        uint frames;
        uint cin;
        uint cout;
        uint k;
        uint dilation;
        uint relu;
    };

    kernel void conv1d(
        device const float *x [[buffer(0)]],
        device const float *w [[buffer(1)]],
        device const float *b [[buffer(2)]],
        constant ConvParams &p [[buffer(3)]],
        device float *y [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint co = gid.x;
        uint t = gid.y;
        if (co >= p.cout || t >= p.frames) { return; }
        float s = b[co];
        int halfK = int(p.k / 2);
        for (uint j = 0; j < p.k; j++) {
            int ti = int(t) + (int(j) - halfK) * int(p.dilation);
            if (ti < 0 || ti >= int(p.frames)) { continue; }
            device const float *xr = x + uint(ti) * p.cin;
            device const float *wr = w + (co * p.k + j) * p.cin;
            for (uint ci = 0; ci < p.cin; ci++) { s += wr[ci] * xr[ci]; }
        }
        y[t * p.cout + co] = p.relu != 0 ? max(s, 0.0f) : s;
    }

    struct PoolParams {
        uint frames;
        uint channels;
        uint windows;
        int offset;
        uint firstWindow;
        uint strideNumerator;
        uint strideDenominator;
        uint length;
    };

    kernel void windowPool(
        device const float *x [[buffer(0)]],
        constant PoolParams &p [[buffer(1)]],
        device float *y [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint c = gid.x;
        uint w = gid.y;
        if (c >= p.channels || w >= p.windows) { return; }
        int start = p.offset + int(((p.firstWindow + w) * p.strideNumerator) / p.strideDenominator);
        float sum = 0;
        float top = 0;
        uint n = 0;
        for (uint j = 0; j < p.length; j++) {
            int t = start + int(j);
            if (t < 0 || t >= int(p.frames)) { continue; }
            float v = x[uint(t) * p.channels + c];
            sum += v;
            top = n == 0 ? v : max(top, v);
            n++;
        }
        y[w * 2 * p.channels + c] = n > 0 ? sum / float(n) : 0.0f;
        y[w * 2 * p.channels + p.channels + c] = top;
    }

    struct DenseParams {
        uint rows;
        uint inputs;
        uint outputs;
        uint activation;
    };

    kernel void dense(
        device const float *x [[buffer(0)]],
        device const float *w [[buffer(1)]],
        device const float *b [[buffer(2)]],
        constant DenseParams &p [[buffer(3)]],
        device float *y [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint o = gid.x;
        uint n = gid.y;
        if (o >= p.outputs || n >= p.rows) { return; }
        device const float *xr = x + n * p.inputs;
        device const float *wr = w + o * p.inputs;
        float s = b[o];
        for (uint i = 0; i < p.inputs; i++) { s += wr[i] * xr[i]; }
        if (p.activation == 1) { s = max(s, 0.0f); }
        if (p.activation == 2) { s = 1.0f / (1.0f + exp(-s)); }
        y[n * p.outputs + o] = s;
    }
    """
}

final class GPUModelContext: @unchecked Sendable {
    static let shared: GPUModelContext? = GPUModelContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let mel: MTLComputePipelineState
    let normalise: MTLComputePipelineState
    let conv: MTLComputePipelineState
    let pool: MTLComputePipelineState
    let dense: MTLComputePipelineState
    let window: MTLBuffer
    let twiddle: MTLBuffer
    let melRanges: MTLBuffer
    let melWeights: MTLBuffer

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        guard let library = try? device.makeLibrary(source: GPUAnalysisShaders.source + GPUModelShaders.source, options: options) else { return nil }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        let size = AnalysisMel.fftSize
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var twiddle = [Float](repeating: 0, count: size)
        for k in 0..<(size / 2) {
            let angle = -2 * Double.pi * Double(k) / Double(size)
            twiddle[2 * k] = Float(cos(angle))
            twiddle[2 * k + 1] = Float(sin(angle))
        }
        let bank = AnalysisMel.filterbank()
        guard let mel = pipeline("melFrames"), let normalise = pipeline("normaliseInput"), let conv = pipeline("conv1d"),
              let pool = pipeline("windowPool"), let dense = pipeline("dense"), mel.maxTotalThreadsPerThreadgroup >= 256,
              let w = device.makeBuffer(bytes: window, length: size * 4, options: .storageModeShared),
              let t = device.makeBuffer(bytes: twiddle, length: size * 4, options: .storageModeShared),
              let r = device.makeBuffer(bytes: bank.ranges, length: bank.ranges.count * 4, options: .storageModeShared),
              let mw = device.makeBuffer(bytes: bank.weights, length: bank.weights.count * 4, options: .storageModeShared)
        else { return nil }
        self.device = device
        self.queue = queue
        self.mel = mel
        self.normalise = normalise
        self.conv = conv
        self.pool = pool
        self.dense = dense
        self.window = w
        self.twiddle = t
        self.melRanges = r
        self.melWeights = mw
    }
}

struct AnalysisMelFrames: Sendable {
    let frames: Int
    let sampleCount: Int
    let values: [UInt16]
}

private struct MelParams {
    var frameCount: UInt32
    var hop: UInt32
    var bands: UInt32
}

final class GPUMelSink: AnalysisPCMSink, @unchecked Sendable {
    static let blockFrames = 8192

    private let context: GPUModelContext
    private let staging: MTLBuffer
    private let output: MTLBuffer
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock = NSLock()
    private var fill = 0
    private var firstFrame = 0
    private var total = 0
    private var values: [UInt16] = []
    private var failed = false

    init?(context: GPUModelContext? = GPUModelContext.shared, expectedSeconds: Double = 0) {
        guard let context else { return nil }
        self.context = context
        capacity = Self.blockFrames * AnalysisMel.hop + AnalysisMel.fftSize
        guard let staging = context.device.makeBuffer(length: capacity * 4, options: .storageModeShared),
              let output = context.device.makeBuffer(length: Self.blockFrames * AnalysisMel.bands * 2, options: .storageModeShared)
        else { return nil }
        self.staging = staging
        self.output = output
        samples = staging.contents().bindMemory(to: Float.self, capacity: capacity)
        values.reserveCapacity(Int(expectedSeconds * AnalysisMel.framesPerSecond + 64) * AnalysisMel.bands)
    }

    func consume(_ input: UnsafeBufferPointer<Float>) {
        guard let base = input.baseAddress else { return }
        lock.lock()
        defer { lock.unlock() }
        var offset = 0
        while offset < input.count {
            let take = min(capacity - fill, input.count - offset)
            (samples + fill).update(from: base + offset, count: take)
            fill += take
            offset += take
            if fill == capacity { flush(frames: Self.blockFrames) }
        }
        total += input.count
    }

    func finish() -> AnalysisMelFrames? {
        lock.lock()
        defer { lock.unlock() }
        let wanted = (total + AnalysisMel.hop - 1) / AnalysisMel.hop
        let remaining = wanted - firstFrame
        if remaining > 0 {
            (samples + fill).initialize(repeating: 0, count: capacity - fill)
            fill = capacity
            flush(frames: remaining)
        }
        guard !failed else { return nil }
        return AnalysisMelFrames(frames: values.count / AnalysisMel.bands, sampleCount: total, values: values)
    }

    private func flush(frames: Int) {
        guard frames > 0 else { return }
        if !failed {
            failed = !run(frames: frames)
        }
        let used = frames * AnalysisMel.hop
        let leftover = fill - used
        memmove(samples, samples + used, leftover * 4)
        fill = leftover
        firstFrame += frames
    }

    private func run(frames: Int) -> Bool {
        guard let commands = context.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return false }
        var params = MelParams(frameCount: UInt32(frames), hop: UInt32(AnalysisMel.hop), bands: UInt32(AnalysisMel.bands))
        encoder.setComputePipelineState(context.mel)
        encoder.setBuffer(staging, offset: 0, index: 0)
        encoder.setBuffer(context.window, offset: 0, index: 1)
        encoder.setBuffer(context.twiddle, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<MelParams>.stride, index: 3)
        encoder.setBuffer(context.melRanges, offset: 0, index: 4)
        encoder.setBuffer(context.melWeights, offset: 0, index: 5)
        encoder.setBuffer(output, offset: 0, index: 6)
        encoder.dispatchThreadgroups(MTLSize(width: frames, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return false }
        values.append(contentsOf: UnsafeBufferPointer(start: output.contents().bindMemory(to: UInt16.self, capacity: frames * AnalysisMel.bands), count: frames * AnalysisMel.bands))
        return true
    }
}

struct AnalysisNetWeights {
    struct Conv {
        let weight: [Float]
        let bias: [Float]
        let cout: Int
        let k: Int
        let cin: Int
        let dilation: Int
    }

    struct Dense {
        let weight: [Float]
        let bias: [Float]
        let outputs: Int
        let inputs: Int
        let activation: Int
    }

    let mean: [Float]
    let scale: [Float]
    let convs: [Conv]
    let denses: [Dense]
    let poolLength: Int
    let poolNumerator: Int
    let poolDenominator: Int
    let poolOffset: Int
    let metadata: [String: String]

    var outputs: Int { denses.last?.outputs ?? 0 }
    var margin: Int { convs.reduce(0) { $0 + ($1.k / 2) * $1.dilation } + 2 }

    init(url: URL) throws {
        let file = try SafeTensorsFile(url: url)
        metadata = file.metadata
        func int(_ key: String) throws -> Int {
            guard let v = file.metadata[key].flatMap(Int.init) else { throw SafeTensorsFile.ReadError.missing(key) }
            return v
        }
        mean = try file.floats("norm.mean")
        scale = try file.floats("norm.scale")
        let dilations = (file.metadata["conv.dilations"] ?? "").split(separator: ",").compactMap { Int($0) }
        convs = try dilations.enumerated().map { i, d in
            let shape = try file.shape("conv\(i).weight")
            guard shape.count == 3 else { throw SafeTensorsFile.ReadError.missing("conv\(i).weight") }
            return Conv(weight: try file.floats("conv\(i).weight"), bias: try file.floats("conv\(i).bias"),
                        cout: shape[0], k: shape[1], cin: shape[2], dilation: d)
        }
        let activations = (file.metadata["dense.activations"] ?? "").split(separator: ",").compactMap { Int($0) }
        denses = try activations.enumerated().map { i, a in
            let shape = try file.shape("dense\(i).weight")
            guard shape.count == 2 else { throw SafeTensorsFile.ReadError.missing("dense\(i).weight") }
            return Dense(weight: try file.floats("dense\(i).weight"), bias: try file.floats("dense\(i).bias"),
                         outputs: shape[0], inputs: shape[1], activation: a)
        }
        poolLength = try int("pool.length")
        poolNumerator = try int("pool.strideNumerator")
        poolDenominator = try int("pool.strideDenominator")
        poolOffset = try int("pool.offset")
    }
}

struct SafeTensorsFile {
    enum ReadError: Error {
        case malformed
        case missing(String)
    }

    let metadata: [String: String]
    private let entries: [String: (dtype: String, shape: [Int], start: Int, end: Int)]
    private let data: Data
    private let base: Int

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else { throw ReadError.malformed }
        let length = data.prefix(8).withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        guard 8 + length <= data.count,
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + length))) as? [String: Any] else { throw ReadError.malformed }
        base = 8 + length
        var entries: [String: (String, [Int], Int, Int)] = [:]
        var metadata: [String: String] = [:]
        for (key, value) in header {
            guard let info = value as? [String: Any] else { continue }
            if key == "__metadata__" {
                for (k, v) in info { metadata[k] = v as? String }
                continue
            }
            guard let dtype = info["dtype"] as? String, let shape = info["shape"] as? [Int],
                  let offsets = info["data_offsets"] as? [Int], offsets.count == 2 else { throw ReadError.malformed }
            entries[key] = (dtype, shape, offsets[0], offsets[1])
        }
        self.entries = entries
        self.metadata = metadata
    }

    func shape(_ name: String) throws -> [Int] {
        guard let entry = entries[name] else { throw ReadError.missing(name) }
        return entry.shape
    }

    func floats(_ name: String) throws -> [Float] {
        guard let entry = entries[name], entry.dtype == "F32", base + entry.end <= data.count else { throw ReadError.missing(name) }
        let count = (entry.end - entry.start) / 4
        return data.subdata(in: (base + entry.start)..<(base + entry.end)).withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}

private struct AffineParams {
    var count: UInt32
    var channels: UInt32
}

private struct ConvParams {
    var frames: UInt32
    var cin: UInt32
    var cout: UInt32
    var k: UInt32
    var dilation: UInt32
    var relu: UInt32
}

private struct PoolParams {
    var frames: UInt32
    var channels: UInt32
    var windows: UInt32
    var offset: Int32
    var firstWindow: UInt32
    var strideNumerator: UInt32
    var strideDenominator: UInt32
    var length: UInt32
}

private struct DenseParams {
    var rows: UInt32
    var inputs: UInt32
    var outputs: UInt32
    var activation: UInt32
}

final class GPUAnalysisNet: @unchecked Sendable {
    static let segmentWindows = 1024

    let weights: AnalysisNetWeights
    private let context: GPUModelContext
    private let mean: MTLBuffer
    private let scale: MTLBuffer
    private let convBuffers: [(MTLBuffer, MTLBuffer)]
    private let denseBuffers: [(MTLBuffer, MTLBuffer)]

    init?(url: URL, context: GPUModelContext? = GPUModelContext.shared) {
        guard let context, let weights = try? AnalysisNetWeights(url: url), weights.mean.count == AnalysisMel.bands,
              weights.scale.count == AnalysisMel.bands, !weights.convs.isEmpty, !weights.denses.isEmpty else { return nil }
        let device = context.device
        func buffer(_ v: [Float]) -> MTLBuffer? { device.makeBuffer(bytes: v, length: max(4, v.count * 4), options: .storageModeShared) }
        var cin = AnalysisMel.bands
        var convs: [(MTLBuffer, MTLBuffer)] = []
        for c in weights.convs {
            guard c.cin == cin, c.weight.count == c.cout * c.k * c.cin, c.bias.count == c.cout,
                  let w = buffer(c.weight), let b = buffer(c.bias) else { return nil }
            convs.append((w, b))
            cin = c.cout
        }
        var inputs = cin * 2
        var denses: [(MTLBuffer, MTLBuffer)] = []
        for d in weights.denses {
            guard d.inputs == inputs, d.weight.count == d.outputs * d.inputs, d.bias.count == d.outputs,
                  let w = buffer(d.weight), let b = buffer(d.bias) else { return nil }
            denses.append((w, b))
            inputs = d.outputs
        }
        guard let mean = buffer(weights.mean), let scale = buffer(weights.scale) else { return nil }
        self.weights = weights
        self.context = context
        self.mean = mean
        self.scale = scale
        convBuffers = convs
        denseBuffers = denses
    }

    static func vocalWindows(sampleCount: Int) -> Int {
        let window = Int(BeatTracker.sampleRate), hop = window / 2
        return sampleCount < window ? 0 : (sampleCount - window) / hop + 2
    }

    static func timbreWindows(sampleCount: Int) -> Int {
        sampleCount / Int(BeatTracker.sampleRate * 0.975)
    }

    func vocalCurve(_ mel: AnalysisMelFrames) -> [Float]? {
        guard weights.outputs == 1, var curve = run(mel, windows: Self.vocalWindows(sampleCount: mel.sampleCount)) else { return nil }
        if !curve.isEmpty { curve[0] = 0 }
        return curve.map { ($0 * 1000).rounded() / 1000 }
    }

    func timbreFrames(_ mel: AnalysisMelFrames) -> [[Float]]? {
        let dimension = weights.outputs
        let count = Self.timbreWindows(sampleCount: mel.sampleCount)
        guard dimension > 1, let flat = run(mel, windows: count) else { return nil }
        return (0..<count).map { Array(flat[($0 * dimension)..<(($0 + 1) * dimension)]) }
    }

    func windowStart(_ w: Int) -> Int {
        weights.poolOffset + (w * weights.poolNumerator) / weights.poolDenominator
    }

    func run(_ mel: AnalysisMelFrames, windows: Int) -> [Float]? {
        guard windows > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(windows * weights.outputs)
        var first = 0
        while first < windows {
            let count = min(Self.segmentWindows, windows - first)
            guard let part = runSegment(mel, firstWindow: first, windows: count) else { return nil }
            out.append(contentsOf: part)
            first += count
        }
        return out
    }

    private func runSegment(_ mel: AnalysisMelFrames, firstWindow: Int, windows: Int) -> [Float]? {
        let bands = AnalysisMel.bands
        let lo = max(0, windowStart(firstWindow) - weights.margin)
        let hi = min(mel.frames, windowStart(firstWindow + windows - 1) + weights.poolLength + weights.margin)
        let frames = max(1, hi - lo)
        let device = context.device
        let widest = max(bands, weights.convs.map(\.cout).max() ?? bands)
        let widestDense = max(weights.convs.last!.cout * 2, weights.denses.map(\.outputs).max() ?? 1)
        guard let input = device.makeBuffer(length: frames * bands * 2, options: .storageModeShared),
              let a = device.makeBuffer(length: frames * widest * 4, options: .storageModeShared),
              let b = device.makeBuffer(length: frames * widest * 4, options: .storageModeShared),
              let p = device.makeBuffer(length: windows * widestDense * 4, options: .storageModeShared),
              let q = device.makeBuffer(length: windows * widestDense * 4, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return nil }
        if hi > lo {
            mel.values.withUnsafeBytes { raw in
                input.contents().copyMemory(from: raw.baseAddress! + lo * bands * 2, byteCount: (hi - lo) * bands * 2)
            }
        } else {
            memset(input.contents(), 0, frames * bands * 2)
        }
        func threads(_ pipeline: MTLComputePipelineState, _ width: Int, _ height: Int) {
            let w = min(width, pipeline.threadExecutionWidth)
            let h = max(1, min(height, pipeline.maxTotalThreadsPerThreadgroup / w))
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        }
        var affine = AffineParams(count: UInt32(frames * bands), channels: UInt32(bands))
        encoder.setComputePipelineState(context.normalise)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(mean, offset: 0, index: 1)
        encoder.setBuffer(scale, offset: 0, index: 2)
        encoder.setBytes(&affine, length: MemoryLayout<AffineParams>.stride, index: 3)
        encoder.setBuffer(a, offset: 0, index: 4)
        threads(context.normalise, frames * bands, 1)
        var source = a, target = b
        var channels = bands
        for (conv, buffers) in zip(weights.convs, convBuffers) {
            var params = ConvParams(frames: UInt32(frames), cin: UInt32(conv.cin), cout: UInt32(conv.cout), k: UInt32(conv.k), dilation: UInt32(conv.dilation), relu: 1)
            encoder.setComputePipelineState(context.conv)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(buffers.0, offset: 0, index: 1)
            encoder.setBuffer(buffers.1, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<ConvParams>.stride, index: 3)
            encoder.setBuffer(target, offset: 0, index: 4)
            threads(context.conv, conv.cout, frames)
            swap(&source, &target)
            channels = conv.cout
        }
        var pool = PoolParams(
            frames: UInt32(frames), channels: UInt32(channels), windows: UInt32(windows), offset: Int32(weights.poolOffset - lo), firstWindow: UInt32(firstWindow),
            strideNumerator: UInt32(weights.poolNumerator), strideDenominator: UInt32(weights.poolDenominator), length: UInt32(weights.poolLength)
        )
        encoder.setComputePipelineState(context.pool)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBytes(&pool, length: MemoryLayout<PoolParams>.stride, index: 1)
        encoder.setBuffer(p, offset: 0, index: 2)
        threads(context.pool, channels, windows)
        var dsource = p, dtarget = q
        var inputs = channels * 2
        for (layer, buffers) in zip(weights.denses, denseBuffers) {
            var params = DenseParams(rows: UInt32(windows), inputs: UInt32(inputs), outputs: UInt32(layer.outputs), activation: UInt32(layer.activation))
            encoder.setComputePipelineState(context.dense)
            encoder.setBuffer(dsource, offset: 0, index: 0)
            encoder.setBuffer(buffers.0, offset: 0, index: 1)
            encoder.setBuffer(buffers.1, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<DenseParams>.stride, index: 3)
            encoder.setBuffer(dtarget, offset: 0, index: 4)
            threads(context.dense, layer.outputs, windows)
            swap(&dsource, &dtarget)
            inputs = layer.outputs
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        let count = windows * inputs
        return Array(UnsafeBufferPointer(start: dsource.contents().bindMemory(to: Float.self, capacity: count), count: count))
    }
}
#endif
