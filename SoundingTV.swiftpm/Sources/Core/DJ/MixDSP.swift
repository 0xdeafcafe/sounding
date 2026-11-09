import Foundation
import Accelerate

struct MixBiquad {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
    var z1: Double = 0
    var z2: Double = 0

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    static func lowPass(_ frequency: Double, q: Double, sampleRate: Double) -> MixBiquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return MixBiquad(
            b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
            a1: -2 * c / a0, a2: (1 - alpha) / a0
        )
    }

    static func highPass(_ frequency: Double, q: Double, sampleRate: Double) -> MixBiquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return MixBiquad(
            b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
            a1: -2 * c / a0, a2: (1 - alpha) / a0
        )
    }

    static func allPass(_ frequency: Double, q: Double, sampleRate: Double) -> MixBiquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return MixBiquad(
            b0: (1 - alpha) / a0, b1: -2 * c / a0, b2: (1 + alpha) / a0,
            a1: -2 * c / a0, a2: (1 - alpha) / a0
        )
    }
}

struct MixIsolatorChannel {
    var lowA: MixBiquad
    var lowB: MixBiquad
    var restA: MixBiquad
    var restB: MixBiquad
    var midA: MixBiquad
    var midB: MixBiquad
    var highA: MixBiquad
    var highB: MixBiquad
    var lowPhase: MixBiquad

    init(sampleRate: Double) {
        let q = 1 / 2.0.squareRoot()
        let low = MixIsolator.lowCrossoverHertz
        let high = MixIsolator.highCrossoverHertz
        lowA = .lowPass(low, q: q, sampleRate: sampleRate)
        lowB = lowA
        restA = .highPass(low, q: q, sampleRate: sampleRate)
        restB = restA
        midA = .lowPass(high, q: q, sampleRate: sampleRate)
        midB = midA
        highA = .highPass(high, q: q, sampleRate: sampleRate)
        highB = highA
        lowPhase = .allPass(high, q: q, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ x: Double, low gl: Double, mid gm: Double, high gh: Double) -> Double {
        let low = lowPhase.process(lowB.process(lowA.process(x)))
        let rest = restB.process(restA.process(x))
        let mid = midB.process(midA.process(rest))
        let high = highB.process(highA.process(rest))
        return gl * low + gm * mid + gh * high
    }

    mutating func reset() {
        lowA.reset(); lowB.reset(); restA.reset(); restB.reset()
        midA.reset(); midB.reset(); highA.reset(); highB.reset(); lowPhase.reset()
    }
}

enum MixIsolator {
    static let lowCrossoverHertz: Double = 250
    static let highCrossoverHertz: Double = 2_500
    static let killDecibels: Double = -59.5

    @inline(__always)
    static func linearGain(decibels: Double) -> Double {
        decibels <= killDecibels ? 0 : pow(10, decibels / 20)
    }
}

struct MixStateVariableFilter {
    var ic1: Double = 0
    var ic2: Double = 0
    var a1: Double = 1
    var a2: Double = 0
    var a3: Double = 0
    var k: Double = 1.414

    mutating func configure(cutoff: Double, q: Double, sampleRate: Double) {
        let clamped = min(sampleRate * 0.45, max(10, cutoff))
        let g = tan(Double.pi * clamped / sampleRate)
        k = 1 / max(0.5, q)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always)
    mutating func lowPass(_ x: Double) -> Double {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return v2
    }

    @inline(__always)
    mutating func highPass(_ x: Double) -> Double {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return x - k * v1 - v2
    }

    mutating func reset() {
        ic1 = 0
        ic2 = 0
    }
}

struct MixOnePole {
    var coefficient: Double = 0
    var state: Double = 0

    static func lowPass(_ frequency: Double, sampleRate: Double) -> MixOnePole {
        MixOnePole(coefficient: exp(-2 * Double.pi * frequency / sampleRate), state: 0)
    }

    @inline(__always)
    mutating func lowPass(_ x: Double) -> Double {
        state = x + coefficient * (state - x)
        return state
    }

    @inline(__always)
    mutating func highPass(_ x: Double) -> Double {
        state = x + coefficient * (state - x)
        return x - state
    }
}

final class MixEcho {
    static let maximumSeconds: Double = 2.5
    let capacity: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    var writeIndex = 0
    var delayFrames: Double
    var targetDelayFrames: Double
    var feedback: Double = 0.45
    var dampL: MixOnePole
    var dampR: MixOnePole
    var lowCutL: MixOnePole
    var lowCutR: MixOnePole
    var energy: Double = 0
    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(Self.maximumSeconds * sampleRate) + 8
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        delayFrames = 0.375 * sampleRate
        targetDelayFrames = delayFrames
        dampL = .lowPass(6_500, sampleRate: sampleRate)
        dampR = dampL
        lowCutL = .lowPass(150, sampleRate: sampleRate)
        lowCutR = lowCutL
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func setDelay(seconds: Double) {
        guard seconds.isFinite else { return }
        targetDelayFrames = min(Double(capacity - 4), max(32, seconds * sampleRate))
    }

    func clear() {
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
        energy = 0
    }

    @inline(__always)
    func read(_ buffer: UnsafeMutablePointer<Float>, delay: Double) -> Double {
        var position = Double(writeIndex) - delay
        while position < 0 { position += Double(capacity) }
        let index = Int(position)
        let fraction = position - Double(index)
        let next = index + 1 == capacity ? 0 : index + 1
        return Double(buffer[index]) * (1 - fraction) + Double(buffer[next]) * fraction
    }

    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frames: Int,
        feedbackGain: UnsafePointer<Float>
    ) {
        var peak = 0.0
        let slew = 1.0 / (0.05 * sampleRate)
        for n in 0..<frames {
            delayFrames += (targetDelayFrames - delayFrames) * min(1, slew * 4)
            let yl = read(left, delay: delayFrames)
            let yr = read(right, delay: delayFrames)
            let fb = Double(feedbackGain[n])
            let wl = Double(inputLeft[n]) + fb * lowCutL.highPass(dampL.lowPass(yl))
            let wr = Double(inputRight[n]) + fb * lowCutR.highPass(dampR.lowPass(yr))
            left[writeIndex] = Float(wl)
            right[writeIndex] = Float(wr)
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
            outputLeft[n] = Float(yl)
            outputRight[n] = Float(yr)
            peak = max(peak, abs(yl) + abs(yr) + abs(wl))
        }
        energy = peak
    }
}

final class MixReverb {
    static let lengths = [1_557, 1_617, 1_491, 1_422, 1_277, 1_356, 1_188, 1_116]
    let lines: [UnsafeMutablePointer<Float>]
    let sizes: [Int]
    var indices: [Int]
    var damping: [MixOnePole]
    var decay: Double
    var energy: Double = 0
    let lineCount: Int

    init(sampleRate: Double, seconds: Double = 2.8) {
        let scale = sampleRate / 44_100
        sizes = Self.lengths.map { Int(Double($0) * scale * 1.6) }
        lineCount = sizes.count
        lines = sizes.map { size in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: size)
            pointer.initialize(repeating: 0, count: size)
            return pointer
        }
        indices = Array(repeating: 0, count: sizes.count)
        damping = Array(repeating: .lowPass(5_000, sampleRate: sampleRate), count: sizes.count)
        let meanDelay = Double(sizes.reduce(0, +)) / Double(sizes.count) / sampleRate
        decay = pow(10, -3 * meanDelay / seconds)
    }

    deinit {
        for line in lines { line.deallocate() }
    }

    func clear() {
        for (line, size) in zip(lines, sizes) { line.update(repeating: 0, count: size) }
        energy = 0
    }

    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        var taps = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        var peak = 0.0
        let householder = 2.0 / Double(lineCount)
        for n in 0..<frames {
            let input = (Double(inputLeft[n]) + Double(inputRight[n])) * 0.35
            withUnsafeMutableBytes(of: &taps) { raw in
                let t = raw.baseAddress!.assumingMemoryBound(to: Double.self)
                var sum = 0.0
                for i in 0..<lineCount {
                    t[i] = damping[i].lowPass(Double(lines[i][indices[i]]))
                    sum += t[i]
                }
                let reflection = sum * householder
                var l = 0.0
                var r = 0.0
                for i in 0..<lineCount {
                    let value = (t[i] - reflection) * decay + input
                    lines[i][indices[i]] = Float(value)
                    indices[i] += 1
                    if indices[i] == sizes[i] { indices[i] = 0 }
                    if i & 1 == 0 { l += t[i] } else { r += t[i] }
                }
                outputLeft[n] = Float(l * 0.35)
                outputRight[n] = Float(r * 0.35)
                peak = max(peak, abs(l) + abs(r) + abs(input))
            }
        }
        energy = peak
    }
}

final class MixLimiter {
    static let taps = 12
    static let phases: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750]
    ]
    static let window = 64
    static let detectorDelay = taps / 2
    static let lookahead = window - 1 + detectorDelay
    static let chunk = 512
    static let marginDecibels = 0.1

    let ceiling: Double
    let detectCeiling: Double
    let release: Double
    var reduction: Double = 1

    private let history = taps - 1
    private let reversed: UnsafeMutablePointer<Float>
    private let inputLeft: UnsafeMutablePointer<Float>
    private let inputRight: UnsafeMutablePointer<Float>
    private let interpolated: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Float>
    private let delayLeft: UnsafeMutablePointer<Float>
    private let delayRight: UnsafeMutablePointer<Float>
    private let holdValue: UnsafeMutablePointer<Float>
    private let holdIndex: UnsafeMutablePointer<Int>
    private let box: UnsafeMutablePointer<Double>
    private var holdHead = 0
    private var holdCount = 0
    private var counter = 0
    private var delayCursor = 0
    private var boxCursor = 0
    private var boxSum = Double(window)
    private var smoothed: Double = 1
    private var previousInterval: Float = 0

    init(sampleRate: Double, ceilingDecibels: Double = -1) {
        ceiling = pow(10, ceilingDecibels / 20)
        detectCeiling = pow(10, (ceilingDecibels - Self.marginDecibels) / 20)
        release = 1 - exp(-1 / (0.12 * sampleRate))
        let taps = Self.taps
        reversed = .allocate(capacity: taps * Self.phases.count)
        for (p, h) in Self.phases.enumerated() {
            for t in 0..<taps { reversed[p * taps + t] = h[taps - 1 - t] }
        }
        inputLeft = .allocate(capacity: Self.chunk + taps)
        inputRight = .allocate(capacity: Self.chunk + taps)
        interpolated = .allocate(capacity: Self.chunk)
        peaks = .allocate(capacity: Self.chunk)
        delayLeft = .allocate(capacity: Self.lookahead)
        delayRight = .allocate(capacity: Self.lookahead)
        holdValue = .allocate(capacity: Self.window + 1)
        holdIndex = .allocate(capacity: Self.window + 1)
        box = .allocate(capacity: Self.window)
        reset()
    }

    deinit {
        reversed.deallocate()
        inputLeft.deallocate()
        inputRight.deallocate()
        interpolated.deallocate()
        peaks.deallocate()
        delayLeft.deallocate()
        delayRight.deallocate()
        holdValue.deallocate()
        holdIndex.deallocate()
        box.deallocate()
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var lowest = 1.0
        var offset = 0
        while offset < frames {
            let count = min(Self.chunk, frames - offset)
            detect(left: left + offset, right: right + offset, count: count)
            apply(left: left + offset, right: right + offset, count: count, lowest: &lowest)
            offset += count
        }
        reduction = lowest
    }

    private func detect(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let taps = Self.taps
        (inputLeft + history).update(from: left, count: count)
        (inputRight + history).update(from: right, count: count)
        peaks.update(repeating: 0, count: count)
        for p in 0..<Self.phases.count {
            vDSP_conv(inputLeft, 1, reversed + p * taps, 1, interpolated, 1, vDSP_Length(count), vDSP_Length(taps))
            vDSP_vmaxmg(interpolated, 1, peaks, 1, peaks, 1, vDSP_Length(count))
            vDSP_conv(inputRight, 1, reversed + p * taps, 1, interpolated, 1, vDSP_Length(count), vDSP_Length(taps))
            vDSP_vmaxmg(interpolated, 1, peaks, 1, peaks, 1, vDSP_Length(count))
        }
        let centre = history - Self.detectorDelay
        for n in 0..<count {
            let interval = peaks[n]
            let sample = max(abs(inputLeft[n + centre]), abs(inputRight[n + centre]))
            peaks[n] = max(sample, interval, previousInterval)
            previousInterval = interval
        }
        memmove(inputLeft, inputLeft + count, history * MemoryLayout<Float>.stride)
        memmove(inputRight, inputRight + count, history * MemoryLayout<Float>.stride)
    }

    private func apply(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, lowest: inout Double) {
        let window = Self.window
        let slots = window + 1
        let invWindow = 1 / Double(window)
        for n in 0..<count {
            let peak = peaks[n]
            while holdCount > 0 {
                let back = (holdHead + holdCount - 1) % slots
                guard holdValue[back] <= peak else { break }
                holdCount -= 1
            }
            let tail = (holdHead + holdCount) % slots
            holdValue[tail] = peak
            holdIndex[tail] = counter
            holdCount += 1
            if holdIndex[holdHead] <= counter - window {
                holdHead = (holdHead + 1) % slots
                holdCount -= 1
            }
            counter += 1
            let held = Double(holdValue[holdHead])
            let target = held > detectCeiling ? detectCeiling / held : 1
            if target < smoothed {
                smoothed = target
            } else {
                smoothed += (target - smoothed) * release
            }
            boxSum += smoothed - box[boxCursor]
            box[boxCursor] = smoothed
            boxCursor += 1
            if boxCursor == window { boxCursor = 0 }
            let gain = min(1, boxSum * invWindow)
            let outL = Double(delayLeft[delayCursor]) * gain
            let outR = Double(delayRight[delayCursor]) * gain
            delayLeft[delayCursor] = left[n]
            delayRight[delayCursor] = right[n]
            delayCursor += 1
            if delayCursor == Self.lookahead { delayCursor = 0 }
            left[n] = Float(max(-ceiling, min(ceiling, outL)))
            right[n] = Float(max(-ceiling, min(ceiling, outR)))
            if gain < lowest { lowest = gain }
        }
    }

    func reset() {
        let taps = Self.taps
        inputLeft.initialize(repeating: 0, count: Self.chunk + taps)
        inputRight.initialize(repeating: 0, count: Self.chunk + taps)
        interpolated.initialize(repeating: 0, count: Self.chunk)
        peaks.initialize(repeating: 0, count: Self.chunk)
        delayLeft.initialize(repeating: 0, count: Self.lookahead)
        delayRight.initialize(repeating: 0, count: Self.lookahead)
        holdValue.initialize(repeating: 0, count: Self.window + 1)
        holdIndex.initialize(repeating: 0, count: Self.window + 1)
        box.initialize(repeating: 1, count: Self.window)
        holdHead = 0
        holdCount = 0
        counter = 0
        delayCursor = 0
        boxCursor = 0
        boxSum = Double(Self.window)
        smoothed = 1
        previousInterval = 0
    }
}

final class MixRiser {
    static let fullScale = 0.32
    static let lowHertz = 350.0
    static let highHertz = 7_000.0
    static let toneLowHertz = 110.0
    static let toneHighHertz = 880.0
    static let coefficientInterval = 32

    let sampleRate: Double
    private var seedL: UInt32 = 0x9E37_79B9
    private var seedR: UInt32 = 0x85EB_CA6B
    private var low1L = 0.0, band1L = 0.0, low1R = 0.0, band1R = 0.0
    private var f = 0.0
    private var damp = 1.0
    private var phase1 = 0.0
    private var phase2 = 0.0
    private var countdown = 0
    private(set) var active = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func reset() {
        low1L = 0; band1L = 0; low1R = 0; band1R = 0
        phase1 = 0; phase2 = 0
        countdown = 0
        active = false
    }

    @inline(__always)
    private static func noise(_ seed: inout UInt32) -> Double {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Double(Int32(bitPattern: seed)) / Double(Int32.max)
    }

    private func configure(sweep: Double) {
        let s = min(1, max(0, sweep))
        let cutoff = Self.lowHertz * pow(Self.highHertz / Self.lowHertz, s)
        f = 2 * sin(Double.pi * min(cutoff, sampleRate * 0.16) / sampleRate)
        let q = 1.2 + 3.5 * s
        damp = 1 / q
    }

    func process(
        gain: UnsafePointer<Float>,
        sweep: UnsafePointer<Float>,
        addingTo left: UnsafeMutablePointer<Float>,
        _ right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        active = true
        let twoPi = 2 * Double.pi
        for n in 0..<frames {
            let s = min(1, max(0, Double(sweep[n])))
            if countdown <= 0 {
                configure(sweep: s)
                countdown = Self.coefficientInterval
            }
            countdown -= 1
            let g = Double(gain[n])
            let nl = Self.noise(&seedL)
            let nr = Self.noise(&seedR)
            low1L += f * band1L
            let highL = nl - low1L - damp * band1L
            band1L += f * highL
            low1R += f * band1R
            let highR = nr - low1R - damp * band1R
            band1R += f * highR
            let tone = Self.toneLowHertz * pow(Self.toneHighHertz / Self.toneLowHertz, s * s)
            phase1 += tone / sampleRate
            phase2 += tone * 1.006 / sampleRate
            if phase1 >= 1 { phase1 -= 1 }
            if phase2 >= 1 { phase2 -= 1 }
            let pitched = 0.5 * (sin(twoPi * phase1) + sin(twoPi * phase2))
            let swell = 0.2 + 0.8 * s * s
            let toneMix = 0.35 * s
            let scale = 0.9 * damp.squareRoot()
            let outL = (band1L * scale * (1 - toneMix) + pitched * toneMix) * swell * g
            let outR = (band1R * scale * (1 - toneMix) + pitched * toneMix) * swell * g
            left[n] += Float(outL)
            right[n] += Float(outR)
        }
    }
}

final class MixLatencyDelay {
    static let capacity = 16_384
    static let maximumDelay = capacity - 4_097
    static let fadeLength = 256
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var write = 0
    private(set) var delay = 0
    private var previous = 0
    private var fade = 0

    init() {
        left = .allocate(capacity: Self.capacity)
        right = .allocate(capacity: Self.capacity)
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func setDelay(_ frames: Int) {
        let clamped = min(max(0, frames), Self.maximumDelay)
        guard clamped != delay else { return }
        previous = fade > 0 ? previous : delay
        delay = clamped
        fade = Self.fadeLength
    }

    func process(left inLeft: UnsafeMutablePointer<Float>, right inRight: UnsafeMutablePointer<Float>, frames: Int) {
        let mask = Self.capacity - 1
        if delay == 0, fade == 0 {
            var done = 0
            while done < frames {
                let run = min(frames - done, Self.capacity - write)
                (left + write).update(from: inLeft + done, count: run)
                (right + write).update(from: inRight + done, count: run)
                write = (write + run) & mask
                done += run
            }
            return
        }
        for n in 0..<frames {
            left[write] = inLeft[n]
            right[write] = inRight[n]
            let tap = (write - delay) & mask
            var l = left[tap]
            var r = right[tap]
            if fade > 0 {
                let t = Float(fade) / Float(Self.fadeLength)
                let old = (write - previous) & mask
                l = l * (1 - t) + left[old] * t
                r = r * (1 - t) + right[old] * t
                fade -= 1
            }
            inLeft[n] = l
            inRight[n] = r
            write = (write + 1) & mask
        }
    }
}
