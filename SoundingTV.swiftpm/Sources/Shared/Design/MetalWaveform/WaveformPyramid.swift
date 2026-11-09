import Foundation

struct WaveformPyramid: Sendable {
    static let samplesPerBaseBin = 64

    var bins: [SIMD2<UInt32>]
    var levelOffsets: [Int]
    var levelCounts: [Int]
    var binsPerSecond: Double
    var duration: TimeInterval
    var pcm: [Int16]?
    var sampleRate: Double
    var sampleGain: Float = 1

    var levelCount: Int { levelOffsets.count }

    static func pack(min lo: Float, max hi: Float, rms: Float, low: Float, mid: Float, high: Float) -> SIMD2<UInt32> {
        func snorm(_ v: Float) -> UInt32 { UInt32(UInt8(bitPattern: Int8((Swift.min(1, Swift.max(-1, v)) * 127).rounded()))) }
        func unorm(_ v: Float) -> UInt32 { UInt32((Swift.min(1, Swift.max(0, v)) * 255).rounded()) }
        return SIMD2(snorm(lo) | snorm(hi) << 8, unorm(rms) | unorm(low) << 8 | unorm(mid) << 16 | unorm(high) << 24)
    }

    static func unpack(_ bin: SIMD2<UInt32>) -> (min: Float, max: Float, bands: SIMD4<Float>) {
        func snorm(_ v: UInt32) -> Float { Swift.max(-1, Float(Int8(bitPattern: UInt8(v & 0xFF))) / 127) }
        func unorm(_ v: UInt32) -> Float { Float(v & 0xFF) / 255 }
        return (snorm(bin.x), snorm(bin.x >> 8), SIMD4(unorm(bin.y), unorm(bin.y >> 8), unorm(bin.y >> 16), unorm(bin.y >> 24)))
    }

    static func reduce(_ a: SIMD2<UInt32>, _ b: SIMD2<UInt32>) -> SIMD2<UInt32> {
        let x = unpack(a), y = unpack(b)
        let bands = SIMD4<Float>(
            Swift.max(x.bands.x, y.bands.x), Swift.max(x.bands.y, y.bands.y),
            Swift.max(x.bands.z, y.bands.z), Swift.max(x.bands.w, y.bands.w)
        )
        return pack(min: Swift.min(x.min, y.min), max: Swift.max(x.max, y.max), rms: bands.x, low: bands.y, mid: bands.z, high: bands.w)
    }

    static func levels(baseCount: Int) -> (offsets: [Int], counts: [Int]) {
        var offsets: [Int] = [], counts: [Int] = []
        var offset = 0, count = baseCount
        while true {
            offsets.append(offset)
            counts.append(count)
            offset += count
            if count <= 1 { break }
            count = (count + 1) / 2
        }
        return (offsets, counts)
    }

    static func buildLevels(base: [SIMD2<UInt32>]) -> (bins: [SIMD2<UInt32>], offsets: [Int], counts: [Int]) {
        let layout = levels(baseCount: base.count)
        var bins = [SIMD2<UInt32>](repeating: .zero, count: (layout.offsets.last ?? 0) + (layout.counts.last ?? 0))
        bins.withUnsafeMutableBufferPointer { out in
            for i in base.indices { out[i] = base[i] }
            for level in 1 ..< layout.offsets.count {
                let source = layout.offsets[level - 1], sourceCount = layout.counts[level - 1]
                let destination = layout.offsets[level]
                for i in 0 ..< layout.counts[level] {
                    let a = source + i * 2
                    out[destination + i] = a + 1 < source + sourceCount ? reduce(out[a], out[a + 1]) : out[a]
                }
            }
        }
        return (bins, layout.offsets, layout.counts)
    }

    static func baseBins(bands: WaveformBandFrames, signed: (min: [Float], max: [Float])? = nil) -> [SIMD2<UInt32>] {
        let n = bands.count
        guard n > 0 else { return [] }
        func peak(_ v: [Float]) -> Float { Swift.max(v.max() ?? 0, 1e-6) }
        let ampScale = 1 / peak(bands.amplitude)
        let lowScale = 1 / peak(bands.low), midScale = 1 / peak(bands.mid), highScale = 1 / peak(bands.high)
        let hasBands = bands.low.count == n && bands.mid.count == n && bands.high.count == n
        var out = [SIMD2<UInt32>](repeating: .zero, count: n)
        for i in 0 ..< n {
            let a = bands.amplitude[i] * ampScale
            let lo = signed.map { $0.min[i] * ampScale } ?? -a
            let hi = signed.map { $0.max[i] * ampScale } ?? a
            if hasBands {
                out[i] = pack(min: lo, max: hi, rms: a, low: bands.low[i] * lowScale, mid: bands.mid[i] * midScale, high: bands.high[i] * highScale)
            } else {
                out[i] = pack(min: lo, max: hi, rms: a, low: a, mid: a, high: a)
            }
        }
        return out
    }

    init(bins: [SIMD2<UInt32>], levelOffsets: [Int], levelCounts: [Int], binsPerSecond: Double, duration: TimeInterval, pcm: [Int16]? = nil, sampleRate: Double = 0) {
        self.bins = bins
        self.levelOffsets = levelOffsets
        self.levelCounts = levelCounts
        self.binsPerSecond = binsPerSecond
        self.duration = duration
        self.pcm = pcm
        self.sampleRate = sampleRate
    }

    init(bands: WaveformBandFrames, entriesPerSecond: Double, duration: TimeInterval? = nil) {
        let built = Self.buildLevels(base: Self.baseBins(bands: bands))
        self.init(
            bins: built.bins, levelOffsets: built.offsets, levelCounts: built.counts,
            binsPerSecond: entriesPerSecond,
            duration: duration ?? Double(bands.count) / entriesPerSecond
        )
    }

    init(envelope: [Float], duration: TimeInterval) {
        let rate = duration > 0 ? Double(envelope.count) / duration : 1
        self.init(bands: WaveformBandFrames(amplitude: envelope), entriesPerSecond: rate, duration: duration)
    }

    init(mono: UnsafeBufferPointer<Float>, sampleRate: Double, keepSamples: Bool = true) {
        let filter = WaveformBandFilter(sampleRate: sampleRate, entriesPerSecond: sampleRate / Double(Self.samplesPerBaseBin))
        let bands = WaveformBandsCPU.parallel(mono, filter: filter)
        let n = bands.count
        var mins = [Float](repeating: 0, count: n), maxs = mins
        for w in 0 ..< n {
            let lower = w * filter.window, upper = Swift.min(lower + filter.window, mono.count)
            var lo: Float = 0, hi: Float = 0
            for i in lower ..< upper { lo = Swift.min(lo, mono[i]); hi = Swift.max(hi, mono[i]) }
            mins[w] = lo; maxs[w] = hi
        }
        let built = Self.buildLevels(base: Self.baseBins(bands: bands, signed: (mins, maxs)))
        let peak = Swift.max(bands.amplitude.max() ?? 0, 1e-6)
        self.init(
            bins: built.bins, levelOffsets: built.offsets, levelCounts: built.counts,
            binsPerSecond: sampleRate / Double(filter.window),
            duration: Double(mono.count) / sampleRate,
            pcm: keepSamples ? mono.map { Int16((Swift.min(1, Swift.max(-1, $0)) * 32767).rounded()) } : nil,
            sampleRate: sampleRate
        )
        sampleGain = 1 / peak
    }
}
