#if canImport(Metal) && !os(watchOS)
import Foundation
import Metal

final class MetalWaveformContext: @unchecked Sendable {
    static let shared: MetalWaveformContext? = MetalWaveformContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let bandsPipeline: MTLComputePipelineState
    let reducePipeline: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalWaveformShaders.source, options: nil),
              let bands = library.makeFunction(name: "waveformBands"),
              let reduce = library.makeFunction(name: "waveformReduce"),
              let bandsPipeline = try? device.makeComputePipelineState(function: bands),
              let reducePipeline = try? device.makeComputePipelineState(function: reduce)
        else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        self.bandsPipeline = bandsPipeline
        self.reducePipeline = reducePipeline
    }
}

private struct BandParams {
    var window: UInt32
    var windowsPerThread: UInt32
    var warmup: UInt32
    var prefix: UInt32
    var sampleCount: UInt32
    var windowCount: UInt32
    var lowCoefficient: Float
    var midCoefficient: Float
}

enum WaveformBandsGPU {
    static let windowsPerThread = 8
    static let chunkWindows = 1 << 15

    static func compute(_ x: UnsafeBufferPointer<Float>, filter: WaveformBandFilter, prefix leading: Int = 0, context: MetalWaveformContext) -> WaveformBandFrames? {
        let windows = filter.windowCount(samples: x.count - leading)
        guard windows > 0, let base = x.baseAddress else { return WaveformBandFrames() }
        let device = context.device
        let floatSize = MemoryLayout<Float>.stride
        guard let amplitude = device.makeBuffer(length: windows * floatSize, options: .storageModeShared),
              let low = device.makeBuffer(length: windows * floatSize, options: .storageModeShared),
              let mid = device.makeBuffer(length: windows * floatSize, options: .storageModeShared),
              let high = device.makeBuffer(length: windows * floatSize, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer()
        else { return nil }
        let warmup = WaveformBandFilter.warmupSamples
        var first = 0
        while first < windows {
            let count = min(chunkWindows, windows - first)
            let start = leading + first * filter.window
            let prefix = min(warmup, start)
            let end = min(x.count, leading + (first + count) * filter.window)
            let length = end - (start - prefix)
            guard let input = device.makeBuffer(bytes: base + (start - prefix), length: length * floatSize, options: .storageModeShared),
                  let encoder = commands.makeComputeCommandEncoder()
            else { return nil }
            var params = BandParams(
                window: UInt32(filter.window), windowsPerThread: UInt32(windowsPerThread),
                warmup: UInt32(warmup), prefix: UInt32(prefix), sampleCount: UInt32(length),
                windowCount: UInt32(count), lowCoefficient: filter.lowCoefficient, midCoefficient: filter.midCoefficient
            )
            encoder.setComputePipelineState(context.bandsPipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(amplitude, offset: first * floatSize, index: 1)
            encoder.setBuffer(low, offset: first * floatSize, index: 2)
            encoder.setBuffer(mid, offset: first * floatSize, index: 3)
            encoder.setBuffer(high, offset: first * floatSize, index: 4)
            encoder.setBytes(&params, length: MemoryLayout<BandParams>.stride, index: 5)
            let threads = (count + windowsPerThread - 1) / windowsPerThread
            let width = min(context.bandsPipeline.maxTotalThreadsPerThreadgroup, 64)
            encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            first += count
        }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        func read(_ buffer: MTLBuffer) -> [Float] {
            Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: windows))
        }
        return WaveformBandFrames(amplitude: read(amplitude), low: read(low), mid: read(mid), high: read(high))
    }
}

extension WaveformBandStream {
    static func best(filter: WaveformBandFilter, expectedSamples: Int = 0) -> WaveformBandStream {
        guard let context = MetalWaveformContext.shared else { return .cpu(filter: filter, expectedSamples: expectedSamples) }
        return WaveformBandStream(filter: filter, expectedSamples: expectedSamples) { x, filter, prefix in
            WaveformBandsGPU.compute(x, filter: filter, prefix: prefix, context: context)
                ?? WaveformBandsCPU.parallel(x, filter: filter, prefix: prefix)
        }
    }
}

enum WaveformPyramidGPU {
    static func buildLevels(base: [SIMD2<UInt32>], context: MetalWaveformContext) -> (buffer: MTLBuffer, offsets: [Int], counts: [Int])? {
        let layout = WaveformPyramid.levels(baseCount: max(base.count, 1))
        let total = (layout.offsets.last ?? 0) + (layout.counts.last ?? 0)
        let stride = MemoryLayout<SIMD2<UInt32>>.stride
        guard let buffer = context.device.makeBuffer(length: total * stride, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return nil }
        base.withUnsafeBytes { raw in
            if let source = raw.baseAddress { buffer.contents().copyMemory(from: source, byteCount: raw.count) }
        }
        encoder.setComputePipelineState(context.reducePipeline)
        let width = min(context.reducePipeline.maxTotalThreadsPerThreadgroup, 256)
        for level in 1 ..< layout.offsets.count {
            var sourceCount = UInt32(layout.counts[level - 1])
            encoder.setBuffer(buffer, offset: layout.offsets[level - 1] * stride, index: 0)
            encoder.setBuffer(buffer, offset: layout.offsets[level] * stride, index: 1)
            encoder.setBytes(&sourceCount, length: 4, index: 2)
            encoder.dispatchThreads(MTLSize(width: layout.counts[level], height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.memoryBarrier(scope: .buffers)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        return (buffer, layout.offsets, layout.counts)
    }
}

final class MetalWaveformSource: @unchecked Sendable, Identifiable {
    let id: String
    let bins: MTLBuffer
    let pcm: MTLBuffer?
    let levelOffsets: [Int]
    let levelCounts: [Int]
    let binsPerSecond: Double
    let duration: TimeInterval
    let sampleRate: Double
    let sampleCount: Int
    let sampleGain: Float

    init?(id: String, pyramid: WaveformPyramid, context: MetalWaveformContext? = .shared) {
        guard let context, !pyramid.bins.isEmpty,
              let bins = pyramid.bins.withUnsafeBytes({ context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        self.id = id
        self.bins = bins
        if let samples = pyramid.pcm, !samples.isEmpty {
            pcm = samples.withUnsafeBytes { context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            sampleCount = samples.count
        } else {
            pcm = nil
            sampleCount = 0
        }
        levelOffsets = pyramid.levelOffsets
        levelCounts = pyramid.levelCounts
        binsPerSecond = pyramid.binsPerSecond
        duration = pyramid.duration
        sampleRate = pyramid.sampleRate
        sampleGain = pyramid.sampleGain
    }

    init?(id: String, baseBins: [SIMD2<UInt32>], binsPerSecond: Double, duration: TimeInterval, context: MetalWaveformContext? = .shared) {
        guard let context, !baseBins.isEmpty, let built = WaveformPyramidGPU.buildLevels(base: baseBins, context: context) else { return nil }
        self.id = id
        bins = built.buffer
        pcm = nil
        sampleCount = 0
        levelOffsets = built.offsets
        levelCounts = built.counts
        self.binsPerSecond = binsPerSecond
        self.duration = duration
        sampleRate = 0
        sampleGain = 1
    }

    static func envelope(id: String, samples: [Float], duration: TimeInterval) -> MetalWaveformSource? {
        guard !samples.isEmpty, duration > 0 else { return nil }
        return MetalWaveformSource(id: id, pyramid: WaveformPyramid(envelope: samples, duration: duration))
    }

    static func bands(id: String, frames: WaveformBandFrames, entriesPerSecond: Double, duration: TimeInterval? = nil) -> MetalWaveformSource? {
        guard frames.count > 0 else { return nil }
        return MetalWaveformSource(id: id, pyramid: WaveformPyramid(bands: frames, entriesPerSecond: entriesPerSecond, duration: duration))
    }
}
#endif
