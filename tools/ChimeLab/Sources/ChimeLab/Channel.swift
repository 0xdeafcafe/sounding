import Foundation

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        let u1 = Double.random(in: 1e-12..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float(sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2))
    }

    mutating func code() -> ChimeCode {
        ChimeCode(bytes: (0..<ChimeCode.byteCount).map { _ in UInt8.random(in: 0...255, using: &self) })!
    }
}

enum Channel {
    static let sampleRate = 48_000.0

    static func rms(_ x: [Float]) -> Float {
        sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)))
    }

    static func padded(_ x: [Float], before: Double = 0.7, after: Double = 0.6) -> [Float] {
        [Float](repeating: 0, count: Int(before * sampleRate)) + x + [Float](repeating: 0, count: Int(after * sampleRate))
    }

    static func carrierSeconds(_ layer: ChimeLayer = .carrier) -> Double {
        layer.frameDuration * 2 + 0.8
    }


    static func noise(_ x: [Float], snr: Float, rng: inout SeededGenerator) -> [Float] {
        let level = rms(x.filter { abs($0) > 1e-6 }) / pow(10, snr / 20)
        return x.map { $0 + level * rng.gaussian() }
    }

    static func whiteNoise(_ x: [Float], dBFS: Float, rng: inout SeededGenerator) -> [Float] {
        let level = pow(10, dBFS / 20)
        return x.map { $0 + level * rng.gaussian() }
    }

    static func drift(_ x: [Float], factor: Double) -> [Float] {
        let count = Int(Double(x.count) / factor)
        return (0..<count).map { i in
            let position = Double(i) * factor
            let j = Int(position)
            let fraction = Float(position - Double(j))
            guard j + 1 < x.count else { return 0 }
            return x[j] * (1 - fraction) + x[j + 1] * fraction
        }
    }

    static func reverb(_ x: [Float], rt60: Double, wet: Float) -> [Float] {
        let input = x + [Float](repeating: 0, count: Int(rt60 * sampleRate))
        var y = input
        for (delay, gain) in [(0.011, Float(0.5)), (0.023, 0.35), (0.041, 0.25)] {
            let offset = Int(delay * sampleRate)
            for n in 0..<(input.count - offset) { y[n + offset] += gain * input[n] }
        }
        var diffuse = [Float](repeating: 0, count: input.count)
        for delay in [0.0297, 0.0371, 0.0411, 0.0437] {
            let length = Int(delay * sampleRate)
            let feedback = Float(pow(10, -3 * delay / rt60))
            var comb = [Float](repeating: 0, count: input.count)
            for n in input.indices {
                comb[n] = input[n] + (n >= length ? feedback * comb[n - length] : 0)
                diffuse[n] += comb[n] * 0.25
            }
        }
        for delay in [0.005, 0.0017] {
            let length = Int(delay * sampleRate)
            var output = [Float](repeating: 0, count: diffuse.count)
            for n in diffuse.indices {
                let delayedIn = n >= length ? diffuse[n - length] : 0
                let delayedOut = n >= length ? output[n - length] : 0
                output[n] = -0.7 * diffuse[n] + delayedIn + 0.7 * delayedOut
            }
            diffuse = output
        }
        let scale = wet * rms(x) / max(rms(diffuse), 1e-9)
        return zip(y, diffuse).map { $0 + $1 * scale }
    }

    static func music(count: Int, level: Float, rng: inout SeededGenerator) -> [Float] {
        var y = [Float](repeating: 0, count: count)
        let scale: [Double] = [261.63, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88, 523.25, 587.33, 659.25,
                               698.46, 783.99, 880.0, 987.77, 1046.5, 1174.66, 1318.51, 1567.98]
        var start = 0
        while start < count {
            let frequency = scale.randomElement(using: &rng)!
            let duration = [0.125, 0.25, 0.25, 0.5].randomElement(using: &rng)!
            let length = min(Int(duration * 1.5 * sampleRate), count - start)
            for n in 0..<max(0, length) {
                let t = Double(n) / sampleRate
                let envelope = Float(exp(-t / (duration * 0.6)) * min(1, t / 0.005))
                var sample: Float = 0
                for harmonic in 1...6 {
                    sample += Float(sin(2 * Double.pi * frequency * Double(harmonic) * t)) / Float(harmonic * harmonic) * 1.4
                }
                y[start + n] += envelope * sample
            }
            if Double.random(in: 0..<1, using: &rng) < 0.5 {
                for n in 0..<max(0, min(Int(0.06 * sampleRate), count - start)) {
                    y[start + n] += 0.6 * rng.gaussian() * Float(exp(-Double(n) / (0.015 * sampleRate)))
                }
            }
            for n in 0..<max(0, min(Int(duration * sampleRate), count - start)) {
                y[start + n] += 0.5 * Float(sin(2 * Double.pi * scale[0] / 2 * Double(n) / sampleRate))
            }
            start += Int(duration * sampleRate)
        }
        let current = rms(y)
        return y.map { $0 * level / max(current, 1e-9) }
    }

    static func withMusic(_ x: [Float], relativeLevel: Float, rng: inout SeededGenerator) -> [Float] {
        let interference = music(count: x.count, level: rms(x) * relativeLevel, rng: &rng)
        return zip(x, interference).map { $0 + $1 }
    }

    static func lowpass(_ x: [Float], cutoff: Double, stages: Int) -> [Float] {
        var y = x
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let b0 = (1 - cos(w0)) / 2, b1 = 1 - cos(w0), b2 = (1 - cos(w0)) / 2
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        for _ in 0..<stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in y.indices {
                let xn = Double(y[n])
                let yn = (b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = xn; y2 = y1; y1 = yn
                y[n] = Float(yn)
            }
        }
        return y
    }

    static func toneLoss(_ frequency: Double, cutoff: Double, stages: Int) -> Float {
        let probe = (0..<Int(0.5 * sampleRate)).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        let filtered = lowpass(probe, cutoff: cutoff, stages: stages)
        let settled = Int(0.25 * sampleRate)
        return 20 * log10(rms(Array(filtered[settled...])) / rms(Array(probe[settled...])))
    }

    static func highpass(_ x: [Float], cutoff: Double, stages: Int) -> [Float] {
        var y = x
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let b0 = (1 + cos(w0)) / 2, b1 = -(1 + cos(w0)), b2 = (1 + cos(w0)) / 2
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        for _ in 0..<stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in y.indices {
                let xn = Double(y[n])
                let yn = (b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = xn; y2 = y1; y1 = yn
                y[n] = Float(yn)
            }
        }
        return y
    }
}
