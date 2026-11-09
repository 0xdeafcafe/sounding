import Foundation

struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u = max(1e-12, uniform()), v = uniform()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }

    mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
    }
}

struct Example {
    var x: [Double]
    var good: Double
    var rating: Double?
}

struct TrainConfig {
    var hidden: [Int] = [24, 16]
    var dropout = 0.2
    var learningRate = 0.003
    var l2 = 0.001
    var epochs = 600
    var batch = 16
    var patience = 50
    var validationFraction = 0.2
    var ratingWeight = 0.5
    var seed: UInt64 = 7
}

final class MLP {
    var sizes: [Int]
    var w: [[Double]]
    var b: [[Double]]
    var rw: [Double]
    var rb: Double
    var mw: [[Double]], vw: [[Double]], mb: [[Double]], vb: [[Double]]
    var mrw: [Double], vrw: [Double], mrb = 0.0, vrb = 0.0
    var step = 0

    init(inputs: Int, hidden: [Int], rng: inout SeededRandom) {
        sizes = [inputs] + hidden + [1]
        w = []; b = []
        for l in 0..<(sizes.count - 1) {
            let fanIn = sizes[l], fanOut = sizes[l + 1]
            let scale = l == sizes.count - 2 ? sqrt(1.0 / Double(fanIn)) : sqrt(2.0 / Double(fanIn))
            w.append((0..<(fanIn * fanOut)).map { _ in rng.gaussian() * scale })
            b.append([Double](repeating: 0, count: fanOut))
        }
        let last = sizes[sizes.count - 2]
        rw = (0..<last).map { _ in rng.gaussian() * sqrt(1.0 / Double(last)) }
        rb = 0
        mw = w.map { [Double](repeating: 0, count: $0.count) }; vw = mw
        mb = b.map { [Double](repeating: 0, count: $0.count) }; vb = mb
        mrw = [Double](repeating: 0, count: rw.count); vrw = mrw
    }

    struct Pass {
        var activations: [[Double]]
        var masks: [[Double]]
        var logit: Double
        var ratingLogit: Double
    }

    func forward(_ x: [Double], dropout: Double, rng: inout SeededRandom?) -> Pass {
        var a = x
        var acts = [x]
        var masks: [[Double]] = []
        let layers = sizes.count - 1
        for l in 0..<(layers - 1) {
            let n = sizes[l + 1], m = sizes[l]
            var z = b[l]
            for o in 0..<n {
                var s = z[o]
                for i in 0..<m { s += w[l][o * m + i] * a[i] }
                z[o] = s
            }
            var mask = [Double](repeating: 1, count: n)
            for o in 0..<n {
                z[o] = max(0, z[o])
                if dropout > 0, var r = rng {
                    mask[o] = r.uniform() < dropout ? 0 : 1 / (1 - dropout)
                    rng = r
                }
                z[o] *= mask[o]
            }
            masks.append(mask)
            a = z
            acts.append(a)
        }
        let m = sizes[layers - 1]
        var logit = b[layers - 1][0]
        for i in 0..<m { logit += w[layers - 1][i] * a[i] }
        var r = rb
        for i in 0..<m { r += rw[i] * a[i] }
        return Pass(activations: acts, masks: masks, logit: logit, ratingLogit: r)
    }

    static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-max(-30, min(30, z)))) }

    func predict(_ x: [Double]) -> (good: Double, rating: Double) {
        var none: SeededRandom? = nil
        let p = forward(x, dropout: 0, rng: &none)
        return (Self.sigmoid(p.logit), 1 + 4 * Self.sigmoid(p.ratingLogit))
    }

    func loss(_ data: [Example], ratingWeight: Double) -> Double {
        var total = 0.0
        for e in data {
            let p = predict(e.x)
            let q = min(1 - 1e-7, max(1e-7, p.good))
            total -= e.good * log(q) + (1 - e.good) * log(1 - q)
            if let r = e.rating { total += ratingWeight * pow((p.rating - r) / 4, 2) }
        }
        return total / Double(max(1, data.count))
    }

    func train(batch: [Example], config: TrainConfig, rng: inout SeededRandom) {
        var gw = w.map { [Double](repeating: 0, count: $0.count) }
        var gb = b.map { [Double](repeating: 0, count: $0.count) }
        var grw = [Double](repeating: 0, count: rw.count)
        var grb = 0.0
        let layers = sizes.count - 1
        var r: SeededRandom? = rng
        for e in batch {
            let p = forward(e.x, dropout: config.dropout, rng: &r)
            let top = p.activations[layers - 1]
            let dLogit = Self.sigmoid(p.logit) - e.good
            var dRating = 0.0
            if let target = e.rating {
                let s = Self.sigmoid(p.ratingLogit)
                dRating = config.ratingWeight * 2 * ((1 + 4 * s - target) / 4) * s * (1 - s)
            }
            var delta = [Double](repeating: 0, count: top.count)
            for i in 0..<top.count {
                gw[layers - 1][i] += dLogit * top[i]
                grw[i] += dRating * top[i]
                delta[i] = dLogit * w[layers - 1][i] + dRating * rw[i]
            }
            gb[layers - 1][0] += dLogit
            grb += dRating
            for l in stride(from: layers - 2, through: 0, by: -1) {
                let n = sizes[l + 1], m = sizes[l]
                let input = p.activations[l]
                let output = p.activations[l + 1]
                var next = [Double](repeating: 0, count: m)
                for o in 0..<n {
                    let d = output[o] > 0 ? delta[o] * p.masks[l][o] : 0
                    guard d != 0 else { continue }
                    gb[l][o] += d
                    for i in 0..<m {
                        gw[l][o * m + i] += d * input[i]
                        next[i] += d * w[l][o * m + i]
                    }
                }
                delta = next
            }
        }
        if let r { rng = r }
        let scale = 1 / Double(max(1, batch.count))
        step += 1
        let b1 = 0.9, b2 = 0.999, eps = 1e-8
        let c1 = 1 - pow(b1, Double(step)), c2 = 1 - pow(b2, Double(step))
        func adam(_ p: inout Double, _ g: Double, _ m: inout Double, _ v: inout Double) {
            m = b1 * m + (1 - b1) * g
            v = b2 * v + (1 - b2) * g * g
            p -= config.learningRate * (m / c1) / (sqrt(v / c2) + eps)
        }
        for l in 0..<layers {
            for k in 0..<w[l].count { adam(&w[l][k], gw[l][k] * scale + config.l2 * w[l][k], &mw[l][k], &vw[l][k]) }
            for k in 0..<b[l].count { adam(&b[l][k], gb[l][k] * scale, &mb[l][k], &vb[l][k]) }
        }
        for k in 0..<rw.count { adam(&rw[k], grw[k] * scale + config.l2 * rw[k], &mrw[k], &vrw[k]) }
        adam(&rb, grb * scale, &mrb, &vrb)
    }

    func copy() -> MLP {
        var dummy = SeededRandom(seed: 0)
        let c = MLP(inputs: sizes[0], hidden: Array(sizes.dropFirst().dropLast()), rng: &dummy)
        c.w = w; c.b = b; c.rw = rw; c.rb = rb
        return c
    }

    func export(featureNames: [String], mean: [Double], scale: [Double]) -> AutoMixNetModel {
        let layers = sizes.count - 1
        let hidden = (0..<(layers - 1)).map { l in
            AutoMixNetModel.Dense(inputs: sizes[l], outputs: sizes[l + 1], weights: w[l].map(Float.init), bias: b[l].map(Float.init))
        }
        let m = sizes[layers - 1]
        return AutoMixNetModel(
            featureNames: featureNames, mean: mean.map(Float.init), scale: scale.map(Float.init), hidden: hidden,
            good: .init(inputs: m, outputs: 1, weights: w[layers - 1].map(Float.init), bias: b[layers - 1].map(Float.init)),
            rating: .init(inputs: m, outputs: 1, weights: rw.map(Float.init), bias: [Float(rb)])
        )
    }
}

struct Standardiser {
    var mean: [Double]
    var scale: [Double]

    init(_ rows: [[Float]]) {
        let d = rows.first?.count ?? 0
        mean = (0..<d).map { j in
            let v = rows.map { Double($0[j]) }.filter(\.isFinite)
            return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        scale = (0..<d).map { _ in 1 }
        for j in 0..<d {
            let v = rows.map { Double($0[j]) }.filter(\.isFinite)
            guard v.count > 1 else { continue }
            let s = sqrt(v.map { ($0 - mean[j]) * ($0 - mean[j]) }.reduce(0, +) / Double(v.count - 1))
            scale[j] = s > 1e-6 ? s : 1
        }
    }

    func apply(_ x: [Float]) -> [Double] {
        (0..<x.count).map { x[$0].isFinite ? (Double(x[$0]) - mean[$0]) / scale[$0] : 0 }
    }
}

func fit(_ train: [Example], config: TrainConfig) -> (model: MLP, epochs: Int) {
    var rng = SeededRandom(seed: config.seed)
    var shuffled = train
    rng.shuffle(&shuffled)
    let holdout = config.validationFraction > 0 && shuffled.count >= 20 ? max(4, Int(Double(shuffled.count) * config.validationFraction)) : 0
    let validation = Array(shuffled.prefix(holdout))
    var fitting = Array(shuffled.dropFirst(holdout))
    let net = MLP(inputs: train[0].x.count, hidden: config.hidden, rng: &rng)
    var best = net.copy()
    var bestLoss = Double.infinity
    var bestEpoch = 0
    for epoch in 0..<config.epochs {
        rng.shuffle(&fitting)
        var i = 0
        while i < fitting.count {
            net.train(batch: Array(fitting[i..<min(fitting.count, i + config.batch)]), config: config, rng: &rng)
            i += config.batch
        }
        let loss = net.loss(validation.isEmpty ? fitting : validation, ratingWeight: config.ratingWeight)
        if loss < bestLoss - 1e-5 {
            bestLoss = loss
            best = net.copy()
            bestEpoch = epoch
        } else if epoch - bestEpoch > config.patience {
            break
        }
    }
    return (best, bestEpoch + 1)
}
