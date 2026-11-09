#if canImport(Metal) && !os(watchOS)
import Accelerate
import Foundation
import Metal

final class GPUAnalysisContext: @unchecked Sendable {
    static let shared: GPUAnalysisContext? = GPUAnalysisContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let onset: MTLComputePipelineState
    let chroma: MTLComputePipelineState
    let onsetTables: Tables
    let chromaTables: Tables
    let classes: MTLBuffer
    let onsetBands: [Range<Int>]
    let chromaBands: [Range<Int>]

    struct Tables {
        let window: MTLBuffer
        let twiddle: MTLBuffer
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        guard let library = try? device.makeLibrary(source: GPUAnalysisShaders.source, options: options),
              let onsetFunction = library.makeFunction(name: "onsetBands"),
              let chromaFunction = library.makeFunction(name: "chromaBands"),
              let onset = try? device.makeComputePipelineState(function: onsetFunction),
              let chroma = try? device.makeComputePipelineState(function: chromaFunction),
              onset.maxTotalThreadsPerThreadgroup >= 256, chroma.maxTotalThreadsPerThreadgroup >= 256,
              let onsetTables = Self.tables(size: BeatTracker.frameSize, device: device),
              let chromaTables = Self.tables(size: BeatTracker.chromaSize, device: device)
        else { return nil }
        let sr = BeatTracker.sampleRate
        func bins(_ lower: Double, _ upper: Double, size: Int) -> Range<Int> {
            let step = sr / Double(size)
            let a = max(1, Int((lower / step).rounded()))
            let b = min(size / 2, max(a + 1, Int((upper / step).rounded())))
            return a..<b
        }
        let edges: [(Double, Double)] = [(30, 150), (150, 1000), (1000, 5000), (5000, 11_000)]
        onsetBands = edges.map { bins($0.0, $0.1, size: BeatTracker.frameSize) }
        chromaBands = edges.map { bins($0.0, $0.1, size: BeatTracker.chromaSize) }
        var classes = [Int32](repeating: -1, count: BeatTracker.chromaSize / 2)
        let step = sr / Double(BeatTracker.chromaSize)
        for k in 1..<(BeatTracker.chromaSize / 2) {
            let f = Double(k) * step
            guard f >= 80, f <= 5000 else { continue }
            let pitch = 12 * log2(f / 440) + 69
            classes[k] = Int32((Int(pitch.rounded()) % 12 + 12) % 12)
        }
        guard let classBuffer = device.makeBuffer(bytes: classes, length: classes.count * 4, options: .storageModeShared) else { return nil }
        self.device = device
        self.queue = queue
        self.onset = onset
        self.chroma = chroma
        self.onsetTables = onsetTables
        self.chromaTables = chromaTables
        self.classes = classBuffer
    }

    private static func tables(size: Int, device: MTLDevice) -> Tables? {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        let half = size / 2
        var twiddle = [Float](repeating: 0, count: size)
        for k in 0..<half {
            let angle = -2 * Double.pi * Double(k) / Double(size)
            twiddle[2 * k] = Float(cos(angle))
            twiddle[2 * k + 1] = Float(sin(angle))
        }
        guard let w = device.makeBuffer(bytes: window, length: size * 4, options: .storageModeShared),
              let t = device.makeBuffer(bytes: twiddle, length: size * 4, options: .storageModeShared) else { return nil }
        return Tables(window: w, twiddle: t)
    }
}

private struct OnsetParams {
    var hop: UInt32
    var firstHop: UInt32
    var hopCount: UInt32
    var hopsPerGroup: UInt32
    var prefix: UInt32
    var bandLower: (UInt32, UInt32, UInt32, UInt32)
    var bandUpper: (UInt32, UInt32, UInt32, UInt32)
}

private struct ChromaParams {
    var hop: UInt32
    var firstHop: UInt32
    var slowCount: UInt32
    var firstSlow: UInt32
    var stride: UInt32
    var prefix: UInt32
    var bandLower: (UInt32, UInt32, UInt32, UInt32)
    var bandUpper: (UInt32, UInt32, UInt32, UInt32)
}

final class GPUFeatureExtractor: BeatTrackerFeatureExtracting {
    static let maxBlockSamples = 1 << 23
    static let hopsPerGroup = 64

    private let context: GPUAnalysisContext
    private let hop: Int
    private let prefix = BeatTracker.chromaSize
    private let blockHops: Int
    private let staging: MTLBuffer
    private let samples: UnsafeMutablePointer<Float>
    private var fill: Int
    private var firstHop = 0
    private(set) var consumedSamples = 0
    private(set) var gpuBlocks = 0
    private(set) var cpuBlocks = 0

    private var low: [Float] = []
    private var lowMid: [Float] = []
    private var mid: [Float] = []
    private var high: [Float] = []
    private var chroma: [Float] = []
    private var bandEnergy: [Float] = []
    private var level: [Float] = []

    init?(hop: Int, expectedSeconds: Double, context: GPUAnalysisContext) {
        guard hop > 0, prefix % hop == 0, (prefix / hop) % BeatTracker.slowStrideHops == 0 else { return nil }
        self.context = context
        self.hop = hop
        let stride = BeatTracker.slowStrideHops
        let expectedHops = Int(expectedSeconds * BeatTracker.sampleRate / Double(hop)) + 64
        let maxHops = Self.maxBlockSamples / hop / stride * stride
        blockHops = max(stride, min(maxHops, (expectedHops + stride - 1) / stride * stride))
        let capacity = prefix + blockHops * hop
        guard let staging = context.device.makeBuffer(length: capacity * MemoryLayout<Float>.stride, options: .storageModeShared) else { return nil }
        self.staging = staging
        samples = staging.contents().bindMemory(to: Float.self, capacity: capacity)
        samples.initialize(repeating: 0, count: prefix)
        fill = prefix
        let frames = expectedHops
        low.reserveCapacity(frames)
        lowMid.reserveCapacity(frames)
        mid.reserveCapacity(frames)
        high.reserveCapacity(frames)
        level.reserveCapacity(frames)
        chroma.reserveCapacity(frames / stride * 12 + 96)
        bandEnergy.reserveCapacity(frames / stride * 4 + 32)
    }

    func consume(_ input: UnsafeBufferPointer<Float>) {
        guard let base = input.baseAddress else { return }
        let capacity = prefix + blockHops * hop
        var offset = 0
        while offset < input.count {
            let take = min(capacity - fill, input.count - offset)
            (samples + fill).update(from: base + offset, count: take)
            fill += take
            offset += take
            if fill == capacity { flush(hops: blockHops) }
        }
        consumedSamples += input.count
    }

    func finish() -> BeatTrackerFeatures {
        let hops = (fill - prefix) / hop
        if hops > 0 { flush(hops: hops) }
        return BeatTrackerFeatures(
            hop: hop,
            sampleRate: BeatTracker.sampleRate,
            slowStride: BeatTracker.slowStrideHops,
            low: low, lowMid: lowMid, mid: mid, high: high,
            chroma: chroma, bandEnergy: bandEnergy,
            analysedSeconds: Double(consumedSamples) / BeatTracker.sampleRate,
            level: level
        )
    }

    private func flush(hops: Int) {
        appendLevels(hops: hops)
        if !runGPU(hops: hops) {
            runCPU(hops: hops)
            cpuBlocks += 1
        } else {
            gpuBlocks += 1
        }
        let used = prefix + hops * hop
        let leftover = fill - used
        memmove(samples, samples + used - prefix, (prefix + leftover) * MemoryLayout<Float>.stride)
        fill = prefix + leftover
        firstHop += hops
    }

    private func appendLevels(hops: Int) {
        for k in 0..<hops {
            var meanSquare: Float = 0
            vDSP_measqv(samples + prefix + k * hop, 1, &meanSquare, vDSP_Length(hop))
            level.append(meanSquare)
        }
    }

    private func slowRange(hops: Int) -> Range<Int> {
        let stride = BeatTracker.slowStrideHops
        let lower = firstHop / stride
        let upper = (firstHop + hops) / stride
        return lower..<max(lower, upper)
    }

    private func runGPU(hops: Int) -> Bool {
        let device = context.device
        let slow = slowRange(hops: hops)
        let floatSize = MemoryLayout<Float>.stride
        guard let bands = device.makeBuffer(length: max(1, hops * 4) * floatSize, options: .storageModeShared),
              let chromaOut = device.makeBuffer(length: max(1, slow.count * 12) * floatSize, options: .storageModeShared),
              let energyOut = device.makeBuffer(length: max(1, slow.count * 4) * floatSize, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        let ob = context.onsetBands.map { UInt32($0.lowerBound) }
        let ou = context.onsetBands.map { UInt32($0.upperBound) }
        var onsetParams = OnsetParams(
            hop: UInt32(hop), firstHop: UInt32(firstHop), hopCount: UInt32(hops), hopsPerGroup: UInt32(Self.hopsPerGroup),
            prefix: UInt32(prefix), bandLower: (ob[0], ob[1], ob[2], ob[3]), bandUpper: (ou[0], ou[1], ou[2], ou[3])
        )
        encoder.setComputePipelineState(context.onset)
        encoder.setBuffer(staging, offset: 0, index: 0)
        encoder.setBuffer(context.onsetTables.window, offset: 0, index: 1)
        encoder.setBuffer(context.onsetTables.twiddle, offset: 0, index: 2)
        encoder.setBytes(&onsetParams, length: MemoryLayout<OnsetParams>.stride, index: 3)
        encoder.setBuffer(bands, offset: 0, index: 4)
        let groups = (hops + Self.hopsPerGroup - 1) / Self.hopsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        if !slow.isEmpty {
            let cb = context.chromaBands.map { UInt32($0.lowerBound) }
            let cu = context.chromaBands.map { UInt32($0.upperBound) }
            var chromaParams = ChromaParams(
                hop: UInt32(hop), firstHop: UInt32(firstHop), slowCount: UInt32(slow.count), firstSlow: UInt32(slow.lowerBound),
                stride: UInt32(BeatTracker.slowStrideHops), prefix: UInt32(prefix),
                bandLower: (cb[0], cb[1], cb[2], cb[3]), bandUpper: (cu[0], cu[1], cu[2], cu[3])
            )
            encoder.setComputePipelineState(context.chroma)
            encoder.setBuffer(staging, offset: 0, index: 0)
            encoder.setBuffer(context.chromaTables.window, offset: 0, index: 1)
            encoder.setBuffer(context.chromaTables.twiddle, offset: 0, index: 2)
            encoder.setBytes(&chromaParams, length: MemoryLayout<ChromaParams>.stride, index: 3)
            encoder.setBuffer(context.classes, offset: 0, index: 4)
            encoder.setBuffer(chromaOut, offset: 0, index: 5)
            encoder.setBuffer(energyOut, offset: 0, index: 6)
            let threads = min(1024, context.chroma.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreadgroups(MTLSize(width: slow.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return false }
        let b = bands.contents().bindMemory(to: Float.self, capacity: hops * 4)
        for k in 0..<hops {
            low.append(b[4 * k])
            lowMid.append(b[4 * k + 1])
            mid.append(b[4 * k + 2])
            high.append(b[4 * k + 3])
        }
        if !slow.isEmpty {
            chroma.append(contentsOf: UnsafeBufferPointer(start: chromaOut.contents().bindMemory(to: Float.self, capacity: slow.count * 12), count: slow.count * 12))
            bandEnergy.append(contentsOf: UnsafeBufferPointer(start: energyOut.contents().bindMemory(to: Float.self, capacity: slow.count * 4), count: slow.count * 4))
        }
        return true
    }

    private func runCPU(hops: Int) {
        let warmHops = prefix / hop
        let extractor = BeatTrackerFeatureExtractor(hop: hop, expectedSeconds: Double(prefix + hops * hop) / BeatTracker.sampleRate)
        extractor.consume(UnsafeBufferPointer(start: samples, count: prefix + hops * hop))
        let part = extractor.finish()
        low.append(contentsOf: part.low[warmHops...])
        lowMid.append(contentsOf: part.lowMid[warmHops...])
        mid.append(contentsOf: part.mid[warmHops...])
        high.append(contentsOf: part.high[warmHops...])
        let warmSlow = warmHops / BeatTracker.slowStrideHops
        chroma.append(contentsOf: part.chroma[(warmSlow * 12)...])
        bandEnergy.append(contentsOf: part.bandEnergy[(warmSlow * 4)...])
    }
}
#endif
