#if DEBUG
import Foundation
import Accelerate

enum MixMetrics {

    // MARK: - Filters

    struct Biquad {
        let b0, b1, b2, a1, a2: Double

        static func lowPass(_ f0: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
            let w = 2 * .pi * f0 / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            return Biquad(
                b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0,
                a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0
            )
        }

        static func highPass(_ f0: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
            let w = 2 * .pi * f0 / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            return Biquad(
                b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
                a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0
            )
        }

        static func kShelf(sampleRate: Double) -> Biquad {
            let f0 = 1681.974450955533
            let g = 3.999843853973347
            let q = 0.7071752369554196
            let k = tan(.pi * f0 / sampleRate)
            let vh = pow(10, g / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            return Biquad(
                b0: (vh + vb * k / q + k * k) / a0,
                b1: 2 * (k * k - vh) / a0,
                b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0,
                a2: (1 - k / q + k * k) / a0
            )
        }

        static func kHighPass(sampleRate: Double) -> Biquad {
            let f0 = 38.13547087602444
            let q = 0.5003270373238773
            let k = tan(.pi * f0 / sampleRate)
            let a0 = 1 + k / q + k * k
            return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
    }

    static func filter(_ input: [Float], _ sections: [Biquad]) -> [Float] {
        guard !input.isEmpty, !sections.isEmpty else { return input }
        var coefficients: [Double] = []
        for s in sections { coefficients += [s.b0, s.b1, s.b2, s.a1, s.a2] }
        guard let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections.count)) else { return input }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
        var output = [Float](repeating: 0, count: input.count)
        vDSP_biquad(setup, &delay, input, 1, &output, 1, vDSP_Length(input.count))
        return output
    }

    // MARK: - Loudness

    static func kWeighted(_ x: [Float], sampleRate: Double) -> [Float] {
        filter(x, [.kShelf(sampleRate: sampleRate), .kHighPass(sampleRate: sampleRate)])
    }

    static func blockMeanSquares(_ x: [Float], window: Int, hop: Int) -> [Double] {
        guard x.count >= window, window > 0, hop > 0 else { return [] }
        var out: [Double] = []
        out.reserveCapacity((x.count - window) / hop + 1)
        x.withUnsafeBufferPointer { buf in
            var start = 0
            while start + window <= x.count {
                var ms: Float = 0
                vDSP_measqv(buf.baseAddress! + start, 1, &ms, vDSP_Length(window))
                out.append(Double(ms))
                start += hop
            }
        }
        return out
    }

    static func lufs(fromMeanSquare ms: Double) -> Double {
        ms > 0 ? -0.691 + 10 * log10(ms) : -120
    }

    static func integratedLoudness(left: [Float], right: [Float], sampleRate: Double) -> Double {
        let kl = kWeighted(left, sampleRate: sampleRate)
        let kr = kWeighted(right, sampleRate: sampleRate)
        let window = Int(0.4 * sampleRate)
        let hop = Int(0.1 * sampleRate)
        let ml = blockMeanSquares(kl, window: window, hop: hop)
        let mr = blockMeanSquares(kr, window: window, hop: hop)
        let blocks = zip(ml, mr).map { $0 + $1 }
        let absolute = blocks.filter { lufs(fromMeanSquare: $0) > -70 }
        guard !absolute.isEmpty else { return -120 }
        let ungated = lufs(fromMeanSquare: absolute.reduce(0, +) / Double(absolute.count))
        let relative = absolute.filter { lufs(fromMeanSquare: $0) > ungated - 10 }
        guard !relative.isEmpty else { return ungated }
        return lufs(fromMeanSquare: relative.reduce(0, +) / Double(relative.count))
    }

    static func loudnessSeries(
        left: [Float], right: [Float], sampleRate: Double, window: TimeInterval, hop: TimeInterval
    ) -> [Double] {
        let kl = kWeighted(left, sampleRate: sampleRate)
        let kr = kWeighted(right, sampleRate: sampleRate)
        let w = Int(window * sampleRate)
        let h = Int(hop * sampleRate)
        let ml = blockMeanSquares(kl, window: w, hop: h)
        let mr = blockMeanSquares(kr, window: w, hop: h)
        return zip(ml, mr).map { lufs(fromMeanSquare: $0 + $1) }
    }

    // MARK: - True peak

    static func truePeakDB(_ channels: [[Float]]) -> Double {
        let taps = 12
        let phases = 4
        var filters: [[Float]] = []
        for p in 1..<phases {
            let shift = Double(p) / Double(phases)
            var h: [Float] = []
            for k in 0..<taps {
                let x = Double(k - taps / 2 + 1) - shift
                let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                let window = 0.5 + 0.5 * cos(.pi * x / Double(taps / 2 + 1))
                h.append(Float(sinc * window))
            }
            filters.append(h.reversed())
        }
        var peak: Float = 0
        for x in channels where x.count > taps {
            var m: Float = 0
            vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
            peak = max(peak, m)
            for h in filters {
                let n = x.count - taps + 1
                var y = [Float](repeating: 0, count: n)
                vDSP_conv(x, 1, h, 1, &y, 1, vDSP_Length(n), vDSP_Length(taps))
                var my: Float = 0
                vDSP_maxmgv(y, 1, &my, vDSP_Length(n))
                peak = max(peak, my)
            }
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -120
    }

    // MARK: - Onsets

    static func kickOnsets(_ x: [Float], sampleRate: Double) -> [TimeInterval] {
        let low = filter(x, [.lowPass(110, sampleRate: sampleRate), .lowPass(110, sampleRate: sampleRate)])
        let frame = Int(sampleRate * 0.001)
        let rms = blockMeanSquares(low, window: frame, hop: frame).map { sqrt($0) }
        guard rms.count > 10 else { return [] }
        var diff = [Double](repeating: 0, count: rms.count)
        for i in 2..<rms.count { diff[i] = max(0, rms[i] - rms[i - 2]) }
        let localWindow = 1500
        var maxima: [Double] = []
        let blockSize = 250
        var blockMax = [Double](repeating: 0, count: rms.count / blockSize + 1)
        for i in 0..<diff.count { blockMax[i / blockSize] = max(blockMax[i / blockSize], diff[i]) }
        maxima.reserveCapacity(diff.count)
        for i in 0..<diff.count {
            let lo = max(0, (i - localWindow) / blockSize)
            let hi = min(blockMax.count - 1, (i + localWindow) / blockSize)
            var m = 0.0
            for b in lo...hi { m = max(m, blockMax[b]) }
            maxima.append(m)
        }
        var onsets: [TimeInterval] = []
        var lastOnset = -1000
        let floor = (rms.max() ?? 0) * 0.02
        for i in 2..<(diff.count - 1) {
            guard diff[i] > 0, diff[i] >= diff[i - 1], diff[i] >= diff[i + 1] else { continue }
            guard diff[i] >= 0.45 * maxima[i], diff[i] > floor else { continue }
            guard i - lastOnset > 180 else { continue }
            let rise = (max(2, i - 10, lastOnset + 1)..<i).first { j in
                diff[j] > 0 && diff[j] >= diff[j - 1] && diff[j] >= diff[j + 1] && diff[j] >= 0.45 * maxima[j]
            } ?? i
            lastOnset = i
            let searchStart = max(0, (rise - 4) * frame)
            let searchEnd = min(low.count, (i + 2) * frame)
            var peak: Float = 0
            for n in searchStart..<searchEnd { peak = max(peak, abs(low[n])) }
            var onsetSample = searchStart
            for n in searchStart..<searchEnd where abs(low[n]) >= 0.25 * peak {
                onsetSample = n
                break
            }
            onsets.append(Double(onsetSample) / sampleRate)
        }
        return onsets
    }

    // MARK: - Band energy

    static func rmsSeries(_ x: [Float], sampleRate: Double, window: TimeInterval, hop: TimeInterval) -> [Double] {
        blockMeanSquares(x, window: Int(window * sampleRate), hop: Int(hop * sampleRate)).map { sqrt($0) }
    }

    static func db(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -120 }

    // MARK: - Statistics

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }

    static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    static func linearSlope(x: [Double], y: [Double]) -> Double {
        guard x.count >= 2, x.count == y.count else { return 0 }
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        var num = 0.0
        var den = 0.0
        for (a, b) in zip(x, y) {
            num += (a - mx) * (b - my)
            den += (a - mx) * (a - mx)
        }
        return den > 0 ? num / den : 0
    }
}

// MARK: - Loop mix gate

enum LoopMixMeasure {
    struct Input {
        var left: [Float]
        var right: [Float]
        var stemOut: [Float]
        var stemIn: [Float]
        var dryOut: [Float]
        var dryIn: [Float]
        var sampleRate: Double
        var start: TimeInterval
        var landing: TimeInterval
        var finish: TimeInterval
        var bar: TimeInterval
    }

    struct Hole: Equatable {
        var time: TimeInterval
        var depth: Double
    }

    struct Result {
        var before: Double
        var after: Double
        var step: Double
        var dip: Double
        var rawDip: Double
        var swell: Double
        var holes: [Hole]
        var outAfter: Double
        var comeback: Double
        var comebackAt: TimeInterval
        var truePeak: Double
    }

    static let block = 0.4
    static let holeDepth = 3.0
    static let shortTermWindow = 3.0
    static let shortTermHop = 0.1
    static let bodyBars = 8.0

    static func shortTerm(_ input: Input, from: TimeInterval, to: TimeInterval) -> [Double] {
        shortTerm(left: input.left, right: input.right, sampleRate: input.sampleRate, from: from, to: to)
    }

    static func shortTerm(left: [Float], right: [Float], sampleRate: Double, from: TimeInterval, to: TimeInterval) -> [Double] {
        let series = MixMetrics.loudnessSeries(left: left, right: right, sampleRate: sampleRate, window: shortTermWindow, hop: shortTermHop)
        return series.enumerated().compactMap { index, value in
            let begin = Double(index) * shortTermHop
            return begin >= from - 1e-6 && begin + shortTermWindow <= to + 1e-6 ? value : nil
        }
    }

    static func engineDip(_ input: Input, before: Double, after: Double, during: [Double]) -> Double {
        let sr = input.sampleRate
        let body = bodyBars * input.bar
        func drops(_ dry: [Float], bodyFrom: TimeInterval, bodyTo: TimeInterval) -> [Double]? {
            let level = MixMetrics.median(shortTerm(left: dry, right: dry, sampleRate: sr, from: bodyFrom, to: bodyTo))
            guard level.isFinite, level > -70 else { return nil }
            return shortTerm(left: dry, right: dry, sampleRate: sr, from: input.start, to: input.finish).map { $0 > -70 ? level - $0 : .infinity }
        }
        let out = drops(input.dryOut, bodyFrom: input.start - body, bodyTo: input.start)
        let inc = drops(input.dryIn, bodyFrom: input.finish, bodyTo: input.finish + body)
        let floor = min(before, after)
        var worst = 0.0
        for (k, level) in during.enumerated() {
            let a = out.flatMap { k < $0.count ? $0[k] : nil } ?? .infinity
            let b = inc.flatMap { k < $0.count ? $0[k] : nil } ?? .infinity
            let music = min(a, b)
            let own = music.isFinite ? max(0, music) : 0
            worst = max(worst, floor - level - own)
        }
        return worst
    }

    static func blocks(_ x: [Float], _ sr: Double) -> [Double] {
        MixMetrics.rmsSeries(x, sampleRate: sr, window: block, hop: block).map(MixMetrics.db)
    }

    static func power(_ db: [Double]) -> Double {
        10 * log10(max(1e-12, db.map { pow(10, $0 / 10) }.reduce(0, +)))
    }

    static func holes(_ input: Input) -> [Hole] {
        let sr = input.sampleRate
        let mono = input.left.indices.map { (input.left[$0] + input.right[$0]) * 0.5 }
        let mix = blocks(mono, sr)
        let decks = [(blocks(input.stemOut, sr), blocks(input.dryOut, sr)), (blocks(input.stemIn, sr), blocks(input.dryIn, sr))]
        let lo = max(5, Int((input.start - 16 * input.bar) / block))
        let hi = min(mix.count - 5, Int((input.finish + 8 * input.bar) / block))
        guard hi > lo else { return [] }
        var found: [Hole] = []
        for k in lo..<hi {
            var expected: [Double] = []
            for (stem, dry) in decks where k < stem.count && k < dry.count && dry[k] > -70 {
                let gains = ((k - 5)...(k + 5)).compactMap { j -> Double? in
                    guard j >= 0, j < stem.count, j < dry.count, dry[j] > -70, stem[j] > -100 else { return nil }
                    return stem[j] - dry[j]
                }
                guard !gains.isEmpty else { continue }
                expected.append(dry[k] + MixMetrics.median(gains))
            }
            guard !expected.isEmpty else { continue }
            let reference = power(expected)
            if reference > -40, reference - mix[k] > holeDepth {
                found.append(Hole(time: Double(k) * block, depth: reference - mix[k]))
            }
        }
        return found
    }

    static func comeback(_ input: Input) -> (Double, TimeInterval) {
        let sr = input.sampleRate
        let beat = input.bar / 4
        var worst = -120.0
        var at = input.landing
        var floor = Double.infinity
        var t = input.landing
        while t + input.bar <= input.finish + 1e-6 {
            let lo = Int(t * sr)
            let hi = min(input.stemOut.count, Int((t + input.bar) * sr))
            guard hi > lo else { break }
            let level = MixMetrics.db(sqrt(MixMetrics.blockMeanSquares(Array(input.stemOut[lo..<hi]), window: hi - lo, hop: hi - lo).first ?? 0))
            if floor.isFinite, level - floor > worst { worst = level - floor; at = t }
            floor = min(floor, level)
            t += beat
        }
        return (worst, at)
    }

    static func measure(_ input: Input) -> Result {
        let before = MixMetrics.median(shortTerm(input, from: input.start - bodyBars * input.bar, to: input.start))
        let after = MixMetrics.median(shortTerm(input, from: input.finish, to: input.finish + bodyBars * input.bar))
        let during = shortTerm(input, from: input.start, to: input.finish)
        let rawDip = max(0, during.map { min(before, after) - $0 }.max() ?? 0)
        let dip = engineDip(input, before: before, after: after, during: during)
        let swell = max(0, during.map { $0 - max(before, after) }.max() ?? 0)
        let stem = blocks(input.stemOut, input.sampleRate)
        let outAfter = stem.indices.filter { Double($0) * block > input.finish + 0.05 }.map { stem[$0] }.max() ?? -120
        let (rise, at) = comeback(input)
        return Result(
            before: before, after: after, step: after - before, dip: dip, rawDip: rawDip, swell: swell,
            holes: holes(input), outAfter: outAfter, comeback: rise, comebackAt: at,
            truePeak: MixMetrics.truePeakDB([input.left, input.right])
        )
    }

    static func lines(_ name: String, _ r: Result) -> [String] {
        let holeText = r.holes.isEmpty ? "none" : r.holes.prefix(6).map { String(format: "%.1fs/%.1fdB", $0.time, $0.depth) }.joined(separator: " ")
        return [
            String(format: "MEASURE|\(name)|step %+.1f LU (%.1f → %.1f LUFS, short-term 3 s K-weighted, median over 8 bars each side)|dip %.1f LU engine-caused (%.1f LU raw, the rest is the music's own quieter bars against its dry stems) swell %.1f LU|engine holes>3dB \(holeText)|outgoing after finish %.1f dBFS|comeback %+.1f dB at %.1f s (1-bar windows, 1-beat hop)|true peak %.2f dBTP", r.step, r.before, r.after, r.dip, r.rawDip, r.swell, r.outAfter, r.comeback, r.comebackAt, r.truePeak)
        ]
    }

    static func passes(_ r: Result) -> Bool {
        abs(r.step) <= 6 && r.holes.isEmpty && r.outAfter < -60 && r.comeback <= 1 && r.truePeak <= -0.5
    }

    static func levelContinuity(_ r: Result) -> Bool {
        r.dip <= 1.5 && r.swell <= 3
    }
}
#endif
