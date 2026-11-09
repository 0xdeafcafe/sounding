import Foundation

struct WaveformBandFrames: Equatable, Sendable {
    var amplitude: [Float] = []
    var low: [Float] = []
    var mid: [Float] = []
    var high: [Float] = []

    var count: Int { amplitude.count }

    mutating func reserve(_ n: Int) {
        amplitude.reserveCapacity(n)
        low.reserveCapacity(n)
        mid.reserveCapacity(n)
        high.reserveCapacity(n)
    }

    mutating func append(contentsOf other: WaveformBandFrames) {
        amplitude += other.amplitude
        low += other.low
        mid += other.mid
        high += other.high
    }
}

struct WaveformBandFilter: Sendable {
    static let lowCutoff = 200.0
    static let midCutoff = 2500.0
    static let warmupSamples = 2048

    let window: Int
    let lowCoefficient: Float
    let midCoefficient: Float

    init(sampleRate: Double, entriesPerSecond: Double) {
        window = max(1, Int((sampleRate / entriesPerSecond).rounded()))
        lowCoefficient = Float(1 - exp(-2 * Double.pi * Self.lowCutoff / sampleRate))
        midCoefficient = Float(1 - exp(-2 * Double.pi * Self.midCutoff / sampleRate))
    }

    func windowCount(samples: Int) -> Int {
        samples == 0 ? 0 : (samples + window - 1) / window
    }
}

struct WaveformBandAccumulator: Sendable {
    let filter: WaveformBandFilter
    private var lp1: Float = 0
    private var lp2: Float = 0
    private var peak: Float = 0
    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var filled = 0
    private(set) var frames = WaveformBandFrames()

    init(filter: WaveformBandFilter, expectedSamples: Int = 0) {
        self.filter = filter
        frames.reserve(filter.windowCount(samples: expectedSamples))
    }

    mutating func consume(_ x: UnsafeBufferPointer<Float>) {
        let a = filter.lowCoefficient, b = filter.midCoefficient, window = filter.window
        for s in x {
            lp1 += a * (s - lp1)
            lp2 += b * (s - lp2)
            let h = s - lp2, m = lp2 - lp1
            peak = max(peak, abs(s))
            low += lp1 * lp1
            mid += m * m
            high += h * h
            filled += 1
            if filled == window { flush() }
        }
    }

    mutating func finish() -> WaveformBandFrames {
        if filled > 0 { flush() }
        return frames
    }

    private mutating func flush() {
        let n = Float(max(filled, 1))
        frames.amplitude.append(peak)
        frames.low.append((low / n).squareRoot())
        frames.mid.append((mid / n).squareRoot())
        frames.high.append((high / n).squareRoot())
        peak = 0; low = 0; mid = 0; high = 0; filled = 0
    }
}

enum WaveformBandsCPU {
    static func serial(_ x: UnsafeBufferPointer<Float>, filter: WaveformBandFilter) -> WaveformBandFrames {
        var accumulator = WaveformBandAccumulator(filter: filter, expectedSamples: x.count)
        accumulator.consume(x)
        return accumulator.finish()
    }

    static func parallel(_ x: UnsafeBufferPointer<Float>, filter: WaveformBandFilter, prefix: Int = 0, windowsPerTask: Int = 2048) -> WaveformBandFrames {
        let windows = filter.windowCount(samples: x.count - prefix)
        guard prefix > 0 || windows > windowsPerTask * 2 else { return serial(x, filter: filter) }
        var amplitude = [Float](repeating: 0, count: windows)
        var low = amplitude, mid = amplitude, high = amplitude
        let tasks = (windows + windowsPerTask - 1) / windowsPerTask
        amplitude.withUnsafeMutableBufferPointer { amp in
            low.withUnsafeMutableBufferPointer { lo in
                mid.withUnsafeMutableBufferPointer { mi in
                    high.withUnsafeMutableBufferPointer { hi in
                        let out = UnsafeOutputs(input: x, amplitude: amp, low: lo, mid: mi, high: hi)
                        DispatchQueue.concurrentPerform(iterations: tasks) { task in
                            run(out.input, filter: filter, prefix: prefix, firstWindow: task * windowsPerTask, windows: min(windowsPerTask, windows - task * windowsPerTask), into: out)
                        }
                    }
                }
            }
        }
        return WaveformBandFrames(amplitude: amplitude, low: low, mid: mid, high: high)
    }

    private struct UnsafeOutputs: @unchecked Sendable {
        let input: UnsafeBufferPointer<Float>
        let amplitude: UnsafeMutableBufferPointer<Float>
        let low: UnsafeMutableBufferPointer<Float>
        let mid: UnsafeMutableBufferPointer<Float>
        let high: UnsafeMutableBufferPointer<Float>
    }

    private static func run(_ x: UnsafeBufferPointer<Float>, filter: WaveformBandFilter, prefix: Int, firstWindow: Int, windows: Int, into out: UnsafeOutputs) {
        let a = filter.lowCoefficient, b = filter.midCoefficient, window = filter.window
        let start = prefix + firstWindow * window
        var lp1: Float = 0, lp2: Float = 0
        for i in max(0, start - WaveformBandFilter.warmupSamples) ..< start {
            let s = x[i]
            lp1 += a * (s - lp1)
            lp2 += b * (s - lp2)
        }
        for w in firstWindow ..< firstWindow + windows {
            let lower = prefix + w * window, upper = min(lower + window, x.count)
            var peak: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0
            for i in lower ..< upper {
                let s = x[i]
                lp1 += a * (s - lp1)
                lp2 += b * (s - lp2)
                let h = s - lp2, m = lp2 - lp1
                peak = max(peak, abs(s))
                low += lp1 * lp1
                mid += m * m
                high += h * h
            }
            let n = Float(max(upper - lower, 1))
            out.amplitude[w] = peak
            out.low[w] = (low / n).squareRoot()
            out.mid[w] = (mid / n).squareRoot()
            out.high[w] = (high / n).squareRoot()
        }
    }
}

struct WaveformBandStream {
    typealias Compute = (UnsafeBufferPointer<Float>, WaveformBandFilter, Int) -> WaveformBandFrames

    let filter: WaveformBandFilter
    let segmentWindows: Int
    private let compute: Compute
    private var buffer: [Float] = []
    private var prefix = 0
    private(set) var frames = WaveformBandFrames()

    init(filter: WaveformBandFilter, segmentWindows: Int = 1 << 13, expectedSamples: Int = 0, compute: @escaping Compute) {
        self.filter = filter
        self.segmentWindows = segmentWindows
        self.compute = compute
        buffer.reserveCapacity(WaveformBandFilter.warmupSamples + segmentWindows * filter.window)
        frames.reserve(filter.windowCount(samples: expectedSamples))
    }

    static func cpu(filter: WaveformBandFilter, expectedSamples: Int = 0) -> WaveformBandStream {
        WaveformBandStream(filter: filter, expectedSamples: expectedSamples) { x, filter, prefix in
            WaveformBandsCPU.parallel(x, filter: filter, prefix: prefix)
        }
    }

    mutating func append(_ x: UnsafeBufferPointer<Float>) {
        let segment = segmentWindows * filter.window
        var offset = 0
        while offset < x.count {
            let take = min(x.count - offset, prefix + segment - buffer.count)
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: x[offset ..< offset + take]))
            offset += take
            if buffer.count == prefix + segment { flush() }
        }
    }

    mutating func finish() -> WaveformBandFrames {
        if buffer.count > prefix { flush() }
        return frames
    }

    private mutating func flush() {
        let result = buffer.withUnsafeBufferPointer { compute($0, filter, prefix) }
        frames.append(contentsOf: result)
        let keep = min(WaveformBandFilter.warmupSamples, buffer.count)
        buffer.removeFirst(buffer.count - keep)
        prefix = keep
    }
}
