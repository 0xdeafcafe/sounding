import Foundation
import MLX

struct NetSpec {
    let name: String
    let convs: [(cout: Int, k: Int, dilation: Int)]
    let denses: [(outputs: Int, activation: Int)]
    let poolLength: Int
    let poolNumerator: Int
    let poolDenominator: Int
    let poolOffset: Int

    var margin: Int { convs.reduce(0) { $0 + ($1.k / 2) * $1.dilation } + 2 }

    func windowStart(_ w: Int) -> Int { poolOffset + (w * poolNumerator) / poolDenominator }
}

final class Net {
    let spec: NetSpec
    let bands: Int
    var params: [MLXArray]
    var mean: [Float]
    var scale: [Float]

    init(spec: NetSpec, bands: Int, mean: [Float], scale: [Float], seed: UInt64) {
        self.spec = spec
        self.bands = bands
        self.mean = mean
        self.scale = scale
        MLXRandom.seed(seed)
        var params: [MLXArray] = []
        var cin = bands
        for c in spec.convs {
            let bound = Float((6.0 / Double(cin * c.k)).squareRoot())
            params.append(MLXRandom.uniform(low: -bound, high: bound, [c.cout, c.k, cin]))
            params.append(MLXArray.zeros([c.cout]))
            cin = c.cout
        }
        var inputs = cin * 2
        for (i, d) in spec.denses.enumerated() {
            let gain = i == spec.denses.count - 1 ? 1.0 : 2.0
            let bound = Float((3.0 * gain / Double(inputs)).squareRoot())
            params.append(MLXRandom.uniform(low: -bound, high: bound, [d.outputs, inputs]))
            params.append(MLXArray.zeros([d.outputs]))
            inputs = d.outputs
        }
        self.params = params
    }

    func forward(_ p: [MLXArray], _ x: MLXArray, indices: MLXArray, mask: MLXArray, windows: Int) -> MLXArray {
        var h = x
        var k = 0
        for c in spec.convs {
            h = conv1d(h, p[k], padding: (c.k / 2) * c.dilation, dilation: c.dilation) + p[k + 1]
            h = maximum(h, 0)
            k += 2
        }
        let batch = h.dim(0)
        let channels = h.dim(2)
        let g = take(h, indices, axis: 1).reshaped([batch, windows, spec.poolLength, channels])
        let count = mask.sum(axis: 2)
        let pooledMean = (g * mask).sum(axis: 2) / maximum(count, 1)
        let pooledMax = which(count .> 0, (g + (mask - 1) * 1e9).max(axis: 2), MLXArray(Float(0)))
        var z = concatenated([pooledMean, pooledMax], axis: -1)
        for (i, d) in spec.denses.enumerated() {
            z = matmul(z, p[k].transposed()) + p[k + 1]
            if d.activation == 1 { z = maximum(z, 0) }
            if d.activation == 2 && i < spec.denses.count - 1 { z = sigmoid(z) }
            k += 2
        }
        return z
    }

    func poolIndices(frames: Int, firstWindow: Int, windows: Int, frameOffset: Int) -> (MLXArray, MLXArray) {
        var idx = [Int32](repeating: 0, count: windows * spec.poolLength)
        var mask = [Float](repeating: 0, count: windows * spec.poolLength)
        for w in 0..<windows {
            let start = spec.windowStart(firstWindow + w) - frameOffset
            for j in 0..<spec.poolLength {
                let t = start + j
                let valid = t >= 0 && t < frames
                idx[w * spec.poolLength + j] = Int32(valid ? t : 0)
                mask[w * spec.poolLength + j] = valid ? 1 : 0
            }
        }
        return (MLXArray(idx), MLXArray(mask, [1, windows, spec.poolLength, 1]))
    }

    func normalised(_ track: LabelTrack, from: Int, to: Int, augment: Augment? = nil) -> [Float] {
        var out = [Float](repeating: 0, count: (to - from) * bands)
        let shift = augment?.shift ?? 0
        for t in max(0, from)..<min(track.frames, to) {
            let s = min(track.frames - 1, max(0, t + shift))
            let src = s * bands
            let dst = (t - from) * bands
            if let augment {
                for c in 0..<bands {
                    var v = Float(track.mel[src + c]) + augment.offsets[c]
                    if augment.noise > 0 { v = log(exp(v) + augment.noise) }
                    out[dst + c] = (v - mean[c]) * scale[c]
                }
            } else {
                for c in 0..<bands { out[dst + c] = (Float(track.mel[src + c]) - mean[c]) * scale[c] }
            }
        }
        return out
    }

    func predict(_ track: LabelTrack, windows: Int) -> [Float] {
        let x = MLXArray(normalised(track, from: 0, to: track.frames), [1, track.frames, bands])
        let (idx, mask) = poolIndices(frames: track.frames, firstWindow: 0, windows: windows, frameOffset: 0)
        var z = forward(params, x, indices: idx, mask: mask, windows: windows)
        if spec.denses.last?.activation == 2 { z = sigmoid(z) }
        eval(z)
        return z.asArray(Float.self)
    }

    func save(to url: URL, extra: [String: String] = [:]) throws {
        var tensors: [(String, [Int], [Float])] = [("norm.mean", [bands], mean), ("norm.scale", [bands], scale)]
        var k = 0
        for i in spec.convs.indices {
            tensors.append(("conv\(i).weight", params[k].shape, params[k].asArray(Float.self)))
            tensors.append(("conv\(i).bias", params[k + 1].shape, params[k + 1].asArray(Float.self)))
            k += 2
        }
        for i in spec.denses.indices {
            tensors.append(("dense\(i).weight", params[k].shape, params[k].asArray(Float.self)))
            tensors.append(("dense\(i).bias", params[k + 1].shape, params[k + 1].asArray(Float.self)))
            k += 2
        }
        var metadata = extra
        metadata["format"] = "sounding.analysisNet.v1"
        metadata["model"] = spec.name
        metadata["conv.dilations"] = spec.convs.map { String($0.dilation) }.joined(separator: ",")
        metadata["dense.activations"] = spec.denses.map { String($0.activation) }.joined(separator: ",")
        metadata["pool.length"] = String(spec.poolLength)
        metadata["pool.strideNumerator"] = String(spec.poolNumerator)
        metadata["pool.strideDenominator"] = String(spec.poolDenominator)
        metadata["pool.offset"] = String(spec.poolOffset)
        try SafeTensorsWriter.write(tensors, metadata: metadata, to: url)
    }
}

final class Adam {
    var m: [MLXArray]
    var v: [MLXArray]
    var step = 0
    let beta1: Float = 0.9
    let beta2: Float = 0.999

    init(_ params: [MLXArray]) {
        m = params.map { MLXArray.zeros(like: $0) }
        v = params.map { MLXArray.zeros(like: $0) }
    }

    func update(_ params: inout [MLXArray], _ grads: [MLXArray], lr: Float, decay: Float) {
        step += 1
        let c1 = 1 - pow(beta1, Float(step))
        let c2 = 1 - pow(beta2, Float(step))
        for i in params.indices {
            m[i] = beta1 * m[i] + (1 - beta1) * grads[i]
            v[i] = beta2 * v[i] + (1 - beta2) * grads[i].square()
            let update = (m[i] / c1) / (sqrt(v[i] / c2) + 1e-8)
            params[i] = params[i] - lr * (update + decay * params[i])
        }
        eval(params + m + v)
    }
}

struct Augment {
    var offsets: [Float]
    var noise: Float
    var shift: Int

    static func random(bands: Int, using rng: inout some RandomNumberGenerator) -> Augment {
        let gain = Float.random(in: -6...6, using: &rng) * 0.2303
        let tilt = Float.random(in: -3...3, using: &rng) * 0.2303
        let offsets = (0..<bands).map { gain + tilt * (Float($0) / Float(bands - 1) - 0.5) }
        let noise: Float = Float.random(in: 0..<1, using: &rng) < 0.3 ? exp(Float.random(in: -2 ... 0.5, using: &rng)) : 0
        return Augment(offsets: offsets, noise: noise, shift: Int.random(in: -2...2, using: &rng))
    }
}
