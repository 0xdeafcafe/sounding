import Foundation

struct LocalLoudness: Sendable, Equatable {
    struct Bar: Sendable, Equatable {
        var power: Double
        var low: Double
        var mid: Double
        var high: Double
        var peak: Double

        var lufs: Double { LocalLoudness.lufs(power) }
    }

    struct Body: Sendable, Equatable {
        var lufs: Double
        var low: Double
        var mid: Double
        var high: Double
        var peakDecibels: Double

        static let typical = Body(lufs: -14, low: 0.42, mid: 0.43, high: 0.15, peakDecibels: -1)

        func trimmed(by decibels: Double) -> Body {
            Body(lufs: lufs + decibels, low: low, mid: mid, high: high, peakDecibels: peakDecibels + decibels)
        }
    }

    var barStarts: [TimeInterval]
    var bars: [Int: Bar]

    static func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(1e-12, power)) }

    static let lowCrossoverHertz = 250.0
    static let highCrossoverHertz = 2_500.0

    func body(bars range: Range<Int>) -> Body? {
        let measured = range.compactMap { bars[$0] }.filter { $0.power > 1e-9 }
        guard measured.count >= 2 else { return nil }
        let ordered = measured.sorted { $0.power < $1.power }
        let steady = Array(ordered[(ordered.count / 2)...])
        let power = steady.reduce(0) { $0 + $1.power } / Double(steady.count)
        let low = steady.reduce(0) { $0 + $1.low * $1.power } / max(1e-12, power * Double(steady.count))
        let high = steady.reduce(0) { $0 + $1.high * $1.power } / max(1e-12, power * Double(steady.count))
        let peak = measured.map(\.peak).max() ?? 1
        return Body(
            lufs: Self.lufs(power),
            low: min(1, max(0, low)),
            mid: min(1, max(0, 1 - low - high)),
            high: min(1, max(0, high)),
            peakDecibels: 20 * log10(max(1e-9, peak))
        )
    }

    static func measure(source: MixSource, barStarts: [TimeInterval], bars range: Range<Int>, into existing: LocalLoudness? = nil) -> LocalLoudness {
        var result = existing ?? LocalLoudness(barStarts: barStarts, bars: [:])
        let sr = source.sampleRate
        let lower = max(0, range.lowerBound)
        let upper = min(barStarts.count, range.upperBound)
        guard upper > lower, sr > 0 else { return result }
        let typicalBar = barStarts.count > 1 ? (barStarts[barStarts.count - 1] - barStarts[0]) / Double(barStarts.count - 1) : 2
        var meter = KWeightedMeter(sampleRate: sr)
        var primed = false
        for index in lower..<upper where result.bars[index] == nil {
            let start = Int((barStarts[index] * sr).rounded())
            let end = index + 1 < barStarts.count ? Int((barStarts[index + 1] * sr).rounded()) : start + Int(typicalBar * sr)
            let first = max(0, start)
            let last = min(source.frameCount, end)
            guard last - first > Int(sr * 0.2) else { primed = false; continue }
            if !primed { meter.reset() }
            meter.begin()
            var frame = first
            var complete = true
            while frame < last {
                let chunkIndex = frame >> MixSource.chunkShift
                guard let pointer = source.chunk(chunkIndex) else { complete = false; break }
                let chunkEnd = min(last, (chunkIndex + 1) << MixSource.chunkShift)
                let offset = frame & MixSource.chunkMask
                meter.process(pointer + offset * 2, frames: chunkEnd - frame)
                frame = chunkEnd
            }
            guard complete else { primed = false; continue }
            primed = true
            result.bars[index] = meter.bar()
        }
        return result
    }

    static func measure(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double, barStarts: [TimeInterval]) -> LocalLoudness {
        var result = LocalLoudness(barStarts: barStarts, bars: [:])
        var meter = KWeightedMeter(sampleRate: sampleRate)
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: 8_192)
        defer { interleaved.deallocate() }
        for index in barStarts.indices {
            let start = max(0, Int((barStarts[index] * sampleRate).rounded()))
            let end = index + 1 < barStarts.count ? min(frames, Int((barStarts[index + 1] * sampleRate).rounded())) : start
            guard end - start > Int(sampleRate * 0.2) else { continue }
            meter.begin()
            var frame = start
            while frame < end {
                let count = min(4_096, end - frame)
                for k in 0..<count {
                    interleaved[2 * k] = left[frame + k]
                    interleaved[2 * k + 1] = right[frame + k]
                }
                meter.process(interleaved, frames: count)
                frame += count
            }
            result.bars[index] = meter.bar()
        }
        return result
    }
}

struct KWeightedMeter {
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        @inline(__always)
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func clear() { z1 = 0; z2 = 0 }

        static func lowPass(_ hertz: Double, sampleRate: Double) -> Biquad {
            let k = tan(.pi * hertz / sampleRate)
            let q = 1 / 2.0.squareRoot()
            let norm = 1 / (1 + k / q + k * k)
            return Biquad(b0: k * k * norm, b1: 2 * k * k * norm, b2: k * k * norm, a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
        }

        static func highPass(_ hertz: Double, sampleRate: Double) -> Biquad {
            let k = tan(.pi * hertz / sampleRate)
            let q = 1 / 2.0.squareRoot()
            let norm = 1 / (1 + k / q + k * k)
            return Biquad(b0: norm, b1: -2 * norm, b2: norm, a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
        }
    }

    var shelfL: Biquad
    var shelfR: Biquad
    var rumbleL: Biquad
    var rumbleR: Biquad
    var low: Biquad
    var high: Biquad
    var sum = 0.0
    var lowSum = 0.0
    var highSum = 0.0
    var monoSum = 0.0
    var peak: Float = 0
    var count = 0

    init(sampleRate: Double) {
        let f0 = 1_681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        let f1 = 38.13547087602444
        let q1 = 0.5003270373238773
        let k1 = tan(.pi * f1 / sampleRate)
        let d1 = 1 + k1 / q1 + k1 * k1
        let rumble = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k1 * k1 - 1) / d1, a2: (1 - k1 / q1 + k1 * k1) / d1)
        shelfL = shelf
        shelfR = shelf
        rumbleL = rumble
        rumbleR = rumble
        low = .lowPass(LocalLoudness.lowCrossoverHertz, sampleRate: sampleRate)
        high = .highPass(LocalLoudness.highCrossoverHertz, sampleRate: sampleRate)
    }

    mutating func reset() {
        shelfL.clear(); shelfR.clear(); rumbleL.clear(); rumbleR.clear(); low.clear(); high.clear()
    }

    mutating func begin() {
        sum = 0; lowSum = 0; highSum = 0; monoSum = 0; peak = 0; count = 0
    }

    mutating func process(_ interleaved: UnsafePointer<Float>, frames: Int) {
        for n in 0..<frames {
            let l = interleaved[2 * n]
            let r = interleaved[2 * n + 1]
            peak = max(peak, abs(l), abs(r))
            let kl = rumbleL.run(shelfL.run(Double(l)))
            let kr = rumbleR.run(shelfR.run(Double(r)))
            sum += kl * kl + kr * kr
            let mono = 0.5 * (kl + kr)
            let lo = low.run(mono)
            let hi = high.run(mono)
            monoSum += mono * mono
            lowSum += lo * lo
            highSum += hi * hi
        }
        count += frames
    }

    func bar() -> LocalLoudness.Bar {
        let power = count > 0 ? sum / Double(count) : 0
        let mono = max(1e-15, monoSum)
        let lowShare = min(1, lowSum / mono)
        let highShare = min(1 - lowShare, highSum / mono)
        return LocalLoudness.Bar(power: power, low: lowShare, mid: max(0, 1 - lowShare - highShare), high: highShare, peak: Double(peak))
    }
}

final class LocalLoudnessCache: @unchecked Sendable {
    static let shared = LocalLoudnessCache()
    private let lock = NSLock()
    private var entries: [(key: String, value: LocalLoudness)] = []
    private let limit = 6

    func value(for key: String) -> LocalLoudness? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.key == key }?.value
    }

    func store(_ value: LocalLoudness, for key: String) {
        lock.lock()
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
    }
}

// MARK: - Trim

enum TransitionTrim {
    static let toleranceLU = 1.0
    static let maximumBoostDecibels = 6.0
    static let maximumCutDecibels = 9.0
    static let outgoingMaximumCutDecibels = 4.0
    static let ceilingDecibels = -1.0
    static let peakMarginDecibels = 0.5
    static let gainCeiling = 2.0
    static let referenceBodyLUFS = -13.0

    struct Result: Sendable, Equatable {
        var outgoingGain: Double
        var incomingGain: Double
        var residualLU: Double
    }

    static func decibels(_ gain: Double) -> Double { 20 * log10(max(1e-6, gain)) }
    static func linear(_ decibels: Double) -> Double { pow(10, decibels / 20) }

    static func solve(outgoing: LocalLoudness.Body, incoming: LocalLoudness.Body, outgoingGain: Double, incomingGain: Double) -> Result {
        let outLevel = outgoing.lufs + decibels(outgoingGain)
        let inLevel = incoming.lufs + decibels(incomingGain)
        let target = max(outLevel, min(inLevel, referenceBodyLUFS))
        let difference = target - inLevel
        guard abs(difference) > toleranceLU else {
            return Result(outgoingGain: outgoingGain, incomingGain: incomingGain, residualLU: difference)
        }
        if difference < 0 {
            let cut = min(-difference, maximumCutDecibels)
            return Result(outgoingGain: outgoingGain, incomingGain: incomingGain * linear(-cut), residualLU: difference + cut)
        }
        let headroom = ceilingDecibels - peakMarginDecibels - (incoming.peakDecibels + decibels(incomingGain))
        let gainRoom = decibels(gainCeiling) - decibels(incomingGain)
        let boost = max(0, min(difference, maximumBoostDecibels, headroom, gainRoom))
        let remainder = difference - boost
        let lower = remainder > toleranceLU ? min(remainder, outgoingMaximumCutDecibels) : 0
        return Result(
            outgoingGain: outgoingGain * linear(-lower),
            incomingGain: incomingGain * linear(boost),
            residualLU: remainder - lower
        )
    }
}

// MARK: - Fader law

struct TransitionBandGains: Sendable, Equatable {
    var outLow = 1.0, outMid = 1.0, outHigh = 1.0
    var inLow = 1.0, inMid = 1.0, inHigh = 1.0
}

enum TransitionFaderLaw {
    static let steps = 20
    static let samples = 32

    @inline(__always)
    static func faderGain(side: Double, shape: Double) -> Double {
        let s = min(1, max(0, side))
        let power = sin(s * .pi / 2)
        let full = sin(min(1, s * 2) * .pi / 2)
        return power + (full - power) * shape
    }

    static func predictedDecibels(x: Double, shape: Double, outgoing: LocalLoudness.Body, incoming: LocalLoudness.Body, bands: TransitionBandGains) -> Double {
        let go = faderGain(side: 1 - x, shape: shape)
        let gi = faderGain(side: x, shape: shape)
        let po = pow(10, outgoing.lufs / 10) * (outgoing.low * bands.outLow + outgoing.mid * bands.outMid + outgoing.high * bands.outHigh)
        let pi = pow(10, incoming.lufs / 10) * (incoming.low * bands.inLow + incoming.mid * bands.inMid + incoming.high * bands.inHigh)
        return 10 * log10(max(1e-12, go * go * po + gi * gi * pi))
    }

    static func curveShape(
        outgoing: LocalLoudness.Body,
        incoming: LocalLoudness.Body,
        range: ClosedRange<Double> = 0...1,
        bands: (Double) -> TransitionBandGains
    ) -> Double {
        var best = range.upperBound
        var bestCost = Double.infinity
        let table = (0...samples).map { k -> (Double, TransitionBandGains) in
            let x = Double(k) / Double(samples)
            return (x, bands(x))
        }
        for step in 0...steps {
            let shape = range.lowerBound + (range.upperBound - range.lowerBound) * Double(step) / Double(steps)
            var cost = 0.0
            for (x, gains) in table {
                let target = (1 - x) * outgoing.lufs + x * incoming.lufs
                let error = predictedDecibels(x: x, shape: shape, outgoing: outgoing, incoming: incoming, bands: gains) - target
                cost = max(cost, error < 0 ? -error / 1.5 : error / 3)
            }
            if cost < bestCost - 1e-6 {
                bestCost = cost
                best = shape
            }
        }
        return best
    }
}

// MARK: - Plan

struct TransitionLevel: Sendable, Equatable {
    var outgoing: LocalLoudness.Body
    var incoming: LocalLoudness.Body
    var outgoingGain: Double?
    var incomingGain: Double?
    var legacyFaderLaw = false
    var roomLUFS: Double? = nil

    static let midHandoverDecibels = -6.0

    var riserScale: Double {
        guard let roomLUFS, roomLUFS.isFinite else { return 1 }
        return min(1, pow(10, (roomLUFS - LocalLoudness.Body.typical.lufs) / 20))
    }
    static let busyMidShare = 0.33
    static let busyLevelSpreadLU = 4.0

    static let typical = TransitionLevel(outgoing: .typical, incoming: .typical)
    static let unity = TransitionLevel(outgoing: .typical, incoming: .typical, legacyFaderLaw: true)

    var bothBusy: Bool {
        guard !legacyFaderLaw else { return false }
        return outgoing.mid >= Self.busyMidShare && incoming.mid >= Self.busyMidShare
            && abs(outgoing.lufs - incoming.lufs) <= Self.busyLevelSpreadLU
    }

    static func plan(
        outgoing: LocalLoudness.Body?,
        incoming: LocalLoudness.Body?,
        outgoingGain: Double,
        incomingGain: Double
    ) -> TransitionLevel {
        let o = outgoing ?? .typical
        let i = incoming ?? .typical
        guard let outgoing, let incoming else {
            var flatOutgoing = o
            var flatIncoming = i
            flatOutgoing.lufs = 0
            flatIncoming.lufs = 0
            return TransitionLevel(outgoing: flatOutgoing, incoming: flatIncoming)
        }
        let trim = TransitionTrim.solve(outgoing: outgoing, incoming: incoming, outgoingGain: outgoingGain, incomingGain: incomingGain)
        return TransitionLevel(
            outgoing: outgoing.trimmed(by: TransitionTrim.decibels(trim.outgoingGain)),
            incoming: incoming.trimmed(by: TransitionTrim.decibels(trim.incomingGain)),
            outgoingGain: abs(trim.outgoingGain - outgoingGain) > 1e-4 ? trim.outgoingGain : nil,
            incomingGain: abs(trim.incomingGain - incomingGain) > 1e-4 ? trim.incomingGain : nil
        )
    }
}
