import Foundation
import MLX

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: analysis-model-trainer vocal|timbre|dedupe <labels root> <out dir> [steps] [width]")
    exit(1)
}
let task = args[1]
let rootURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
let steps = args.count > 4 ? Int(args[4]) ?? 3000 : 3000
let width = args.count > 5 ? Int(args[5]) ?? 64 : 64
let env = ProcessInfo.processInfo.environment
let sources = (env["SOURCES"] ?? "corpus").split(separator: ",").map(String.init)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

if task == "dedupe" {
    try Fingerprint.run(root: rootURL, sources: sources.filter { $0 != "corpus" }, threshold: Int(env["THRESHOLD"] ?? "30") ?? 30)
    exit(0)
}

let t0 = now()
let tracks = try loadTracks(rootURL, sources: Array(Set(sources + ["corpus"])).sorted())
let usable = tracks.filter { $0.split == .train && sources.contains($0.source) }
let train = subsample(usable, hours: env["TRAIN_HOURS"].flatMap(Double.init))
let validation = tracks.filter { $0.split == .validation }
let test = tracks.filter { $0.split == .test }
let evaluation = env["EVAL_SPLIT"] == "test" ? test : validation
let trainHours = train.map(\.hours).reduce(0, +)
print("loaded \(tracks.count) files in \(String(format: "%.1f", now() - t0))s; train \(train.count) files \(String(format: "%.1f", trainHours)) h from \(sources.joined(separator: "+")) (\(tracks.filter { $0.split == .excluded }.count) excluded files, \(tracks.filter { !$0.excluded.isEmpty }.count) with excluded ranges); validation \(validation.count) test \(test.count)")
for source in Set(train.map(\.source)).sorted() {
    let s = train.filter { $0.source == source }
    print("  \(source): \(s.count) files, \(String(format: "%.1f", s.map(\.hours).reduce(0, +))) h")
}

let bands = tracks[0].bands
var mean = [Double](repeating: 0, count: bands)
var square = [Double](repeating: 0, count: bands)
var total = 0.0
for track in train {
    for t in Swift.stride(from: 0, to: track.frames, by: 8) {
        for c in 0..<bands {
            let v = Double(track.melValue(t, c))
            mean[c] += v
            square[c] += v * v
        }
        total += 1
    }
}
let melMean = mean.map { Float($0 / total) }
let melScale = zip(mean, square).map { Float(1 / max(1e-3, ($1 / total - ($0 / total) * ($0 / total)).squareRoot())) }
print("mel mean range \(String(format: "%.2f", melMean.min() ?? 0))...\(String(format: "%.2f", melMean.max() ?? 0))")

var rng = SplitMix(seed: UInt64(env["SEED"] ?? "1") ?? 1)
let batch = Int(env["BATCH"] ?? "32") ?? 32
let lr0 = Float(env["LR"] ?? "0.002") ?? 0.002
let decay = Float(env["DECAY"] ?? "0.0001") ?? 0.0001
let depth = Int(env["DEPTH"] ?? "5") ?? 5
let augmenting = env["AUGMENT"] != "0"
let dilations = [1, 2, 4, 8, 16, 1, 2, 4]

func cosine(_ step: Int) -> Float { lr0 * Float(0.5 * (1 + cos(Double.pi * Double(step) / Double(steps)))) + lr0 * 0.01 }

func weightedPicker(_ pool: [LabelTrack], weight: (LabelTrack) -> Double) -> () -> LabelTrack {
    var cumulative: [Double] = []
    var sum = 0.0
    for t in pool { sum += weight(t); cumulative.append(sum) }
    return {
        let r = Double.random(in: 0..<sum, using: &rng)
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] > r { hi = mid } else { lo = mid + 1 }
        }
        return pool[lo]
    }
}

switch task {
case "vocal":
    let classWeight = Float(env["CLASS_WEIGHT"] ?? "1") ?? 1
    let barWeight = Float(env["BAR_WEIGHT"] ?? "0.5") ?? 0.5
    let classCount = classWeight > 0 ? tracks[0].classCount : 0
    let spec = NetSpec(
        name: "vocal",
        convs: (0..<depth).map { (cout: width, k: 5, dilation: dilations[$0]) },
        denses: [(outputs: Int(env["HIDDEN"] ?? "\(width)") ?? width, activation: 1), (outputs: 1 + classCount, activation: 2)],
        poolLength: 50, poolNumerator: 25, poolDenominator: 1, poolOffset: -25
    )
    let net = Net(spec: spec, bands: bands, mean: melMean, scale: melScale, seed: UInt64(env["SEED"] ?? "1") ?? 1)
    let n = 64
    let windows = n - 1
    let maxBars = 24
    let margin = spec.margin + 2
    let pool = train.filter { $0.curve.count >= n + 2 && $0.classWindows >= $0.curve.count - 1 }
    let pick = weightedPicker(pool) { Double($0.curve.count) }
    let cropFrames = 25 * n + 2 * margin
    let (idx, mask) = net.poolIndices(frames: cropFrames, firstWindow: 1, windows: windows, frameOffset: -margin)
    let outputs = 1 + classCount
    let lossAndGrad = valueAndGrad({ (a: [MLXArray]) -> [MLXArray] in
        let p = Array(a[0..<(a.count - 6)])
        let x = a[a.count - 6], y = a[a.count - 5], c = a[a.count - 4], barMask = a[a.count - 3], barTarget = a[a.count - 2], barValid = a[a.count - 1]
        let z = net.forward(p, x, indices: idx, mask: mask, windows: windows).reshaped([-1, windows, outputs])
        let zv = z[0..., 0..., 0]
        var loss = (logAddExp(MLXArray(Float(0)), zv) - y * zv).mean()
        if classCount > 0 {
            let zc = z[0..., 0..., 1...]
            loss = loss + classWeight * (logAddExp(MLXArray(Float(0)), zc) - c * zc).mean() * Float(classCount) / 32
        }
        if barWeight > 0 {
            let barLogit = (zv.expandedDimensions(axis: 1) + (barMask - 1) * 1e4).max(axis: 2)
            let bce = (logAddExp(MLXArray(Float(0)), barLogit) - barTarget * barLogit) * barValid
            loss = loss + barWeight * bce.sum() / maximum(barValid.sum(), 1)
        }
        return [loss]
    }, argumentNumbers: Array(0..<net.params.count))
    let adam = Adam(net.params)
    var running: Float = 0
    let start = now()
    for step in 0..<steps {
        var x = [Float]()
        x.reserveCapacity(batch * cropFrames * bands)
        var y = [Float](), c = [Float]()
        var bm = [Float](repeating: 0, count: batch * maxBars * windows)
        var bt = [Float](repeating: 0, count: batch * maxBars), bv = [Float](repeating: 0, count: batch * maxBars)
        for b in 0..<batch {
            var track = pick()
            var j0 = Int.random(in: 0...(track.curve.count - n), using: &rng)
            var tries = 0
            while track.isExcluded(from: Double(j0) * 0.5 - 1, to: Double(j0 + n) * 0.5 + 1) && tries < 20 {
                track = pick()
                j0 = Int.random(in: 0...(track.curve.count - n), using: &rng)
                tries += 1
            }
            let aug = augmenting ? Augment.random(bands: bands, using: &rng) : nil
            x.append(contentsOf: net.normalised(track, from: 25 * j0 - margin, to: 25 * j0 - margin + cropFrames, augment: aug))
            y.append(contentsOf: track.curve[(j0 + 1)..<(j0 + n)])
            if classCount > 0 {
                for i in (j0 + 1)..<(j0 + n) {
                    let w = i - 1
                    for k in 0..<classCount { c.append(Float(track.classes[w * classCount + k])) }
                }
            }
            if barWeight > 0 {
                let lo = Double(j0 + 1) * 0.5, hi = Double(j0 + n - 1) * 0.5
                var k = 0
                let sung = track.sung
                for bar in track.downbeats.indices where k < maxBars {
                    let s = track.downbeats[bar]
                    let e = bar + 1 < track.downbeats.count ? track.downbeats[bar + 1] : track.seconds
                    guard s >= lo, e <= hi, e > s else { continue }
                    var any = false
                    for w in 0..<windows {
                        let centre = Double(j0 + 1 + w) * 0.5
                        if centre >= s - 0.5 && centre < e + 0.5 { bm[(b * maxBars + k) * windows + w] = 1; any = true }
                    }
                    if any {
                        bt[b * maxBars + k] = sung[bar] ? 1 : 0
                        bv[b * maxBars + k] = 1
                        k += 1
                    }
                }
            }
        }
        let inputs = [
            MLXArray(x, [batch, cropFrames, bands]), MLXArray(y, [batch, windows]),
            classCount > 0 ? MLXArray(c, [batch, windows, classCount]) : MLXArray(Float(0)),
            MLXArray(bm, [batch, maxBars, windows]), MLXArray(bt, [batch, maxBars]), MLXArray(bv, [batch, maxBars])
        ]
        let (loss, grads) = lossAndGrad(net.params + inputs)
        adam.update(&net.params, grads, lr: cosine(step), decay: decay)
        running = running * 0.98 + loss[0].item(Float.self) * 0.02
        if step % 500 == 0 || step == steps - 1 {
            print("step \(step) loss \(String(format: "%.4f", running / Float(1 - pow(0.98, Double(step + 1))))) \(String(format: "%.0f", now() - start))s")
        }
    }
    if classCount > 0 {
        let k = net.params.count
        net.params[k - 2] = net.params[k - 2][0..<1]
        net.params[k - 1] = net.params[k - 1][0..<1]
        eval(net.params)
    }
    let prunedSpec = NetSpec(name: spec.name, convs: spec.convs, denses: [spec.denses[0], (outputs: 1, activation: 2)], poolLength: spec.poolLength, poolNumerator: spec.poolNumerator, poolDenominator: spec.poolDenominator, poolOffset: spec.poolOffset)
    let pruned = Net(spec: prunedSpec, bands: bands, mean: melMean, scale: melScale, seed: 1)
    pruned.params = net.params
    if env["CALIBRATE"] != "0" {
        let logits = validation.map { track in pruned.predict(track, windows: track.curve.count).map { p -> Float in
            let q = min(max(p, 1e-6), 1 - 1e-6)
            return log(q / (1 - q))
        } }
        var best = (Float(1), Float(0)), bestAgree = -1
        for a in [0.8, 0.9, 1.0, 1.15, 1.3, 1.5] as [Float] {
            for c in Swift.stride(from: Float(-1), through: 1, by: 0.125) {
                var agree = 0
                for (track, z) in zip(validation, logits) {
                    var curve = z.map { (1 / (1 + exp(-(a * $0 + c))) * 1000).rounded() / 1000 }
                    if !curve.isEmpty { curve[0] = 0 }
                    agree += zip(track.sung, VocalRules.sung(curve, bars: track.downbeats, end: track.seconds)).filter { $0 == $1 }.count
                }
                if a == 1 && c == 0 { print("uncalibrated validation agreement \(agree)") }
                if agree > bestAgree { bestAgree = agree; best = (a, c) }
            }
        }
        print("calibration (validation): scale \(best.0) shift \(best.1) agreement \(bestAgree)")
        let k = pruned.params.count
        pruned.params[k - 2] = pruned.params[k - 2] * best.0
        pruned.params[k - 1] = pruned.params[k - 1] * best.0 + best.1
        eval(pruned.params)
    }
    try pruned.save(to: outURL.appendingPathComponent("VocalModel.safetensors"), extra: ["trainHours": String(format: "%.1f", trainHours), "classWeight": "\(classWeight)", "barWeight": "\(barWeight)"])
    var agree = 0, bars = 0, under99 = 0, over1 = 0, abs = 0.0, points = 0, worst = 0
    var lines: [String] = []
    for track in evaluation {
        var curve = pruned.predict(track, windows: track.curve.count).map { ($0 * 1000).rounded() / 1000 }
        if !curve.isEmpty { curve[0] = 0 }
        for i in curve.indices { abs += Double(Swift.abs(curve[i] - track.curve[i])); points += 1 }
        let a = track.sung
        let b = VocalRules.sung(curve, bars: track.downbeats, end: track.seconds)
        let same = zip(a, b).filter { $0 == $1 }.count
        agree += same
        bars += a.count
        let diff = a.count - same
        worst = max(worst, diff)
        if a.count > 0 && Double(same) / Double(a.count) < 0.99 { under99 += 1 }
        if diff > 1 { over1 += 1 }
        lines.append("\(track.index)\t\(a.count)\t\(diff)")
    }
    try lines.joined(separator: "\n").write(to: outURL.appendingPathComponent("vocal-eval.tsv"), atomically: true, encoding: .utf8)
    print("RESULT vocal \(env["EVAL_SPLIT"] ?? "validation") hours \(String(format: "%.1f", trainHours)) classW \(classWeight) barW \(barWeight): \(evaluation.count) tracks; curve MAE \(String(format: "%.4f", abs / Double(max(1, points)))); bar agreement \(String(format: "%.4f", Double(agree) / Double(max(1, bars)))) of \(bars); within 1 bar \(evaluation.count - over1)/\(evaluation.count) (\(String(format: "%.1f", 100 * Double(evaluation.count - over1) / Double(max(1, evaluation.count))))%); under 99%: \(under99); worst \(worst)")

case "timbre":
    let dim = tracks[0].timbreDim
    let spec = NetSpec(
        name: "timbre",
        convs: (0..<depth).map { (cout: width, k: 5, dilation: dilations[$0]) },
        denses: [(outputs: Int(env["HIDDEN"] ?? "512") ?? 512, activation: 1), (outputs: dim, activation: 0)],
        poolLength: 49, poolNumerator: 195, poolDenominator: 4, poolOffset: 0
    )
    let net = Net(spec: spec, bands: bands, mean: melMean, scale: melScale, seed: UInt64(env["SEED"] ?? "1") ?? 1)
    let timbreTrain = train.filter { $0.source != "sets" }
    var tMean = [Double](repeating: 0, count: dim), tSquare = [Double](repeating: 0, count: dim), tCount = 0.0
    for track in timbreTrain {
        for f in Swift.stride(from: 0, to: track.timbreCount, by: 2) {
            for d in 0..<dim {
                let v = Double(track.timbre[f * dim + d])
                tMean[d] += v
                tSquare[d] += v * v
            }
            tCount += 1
        }
    }
    let mu = tMean.map { Float($0 / tCount) }
    let sigma = zip(tMean, tSquare).map { Float(max(1e-4, ($1 / tCount - ($0 / tCount) * ($0 / tCount)).squareRoot())) }
    let simWeight = Float(env["SIM_WEIGHT"] ?? "1") ?? 1
    let simScale = Float(env["SIM_SCALE"] ?? "0.02") ?? 0.02
    let n = Int(env["CROP"] ?? "24") ?? 24
    let margin = spec.margin + 2
    let pool = timbreTrain.filter { $0.timbreCount >= n + 4 }
    print("timbre train: \(pool.count) files (sets excluded)")
    let cropFrames = spec.windowStart(n - 1) + spec.poolLength + 2 * margin
    let (idx, mask) = net.poolIndices(frames: cropFrames, firstWindow: 0, windows: n, frameOffset: -margin)
    let muArray = MLXArray(mu), sigmaArray = MLXArray(sigma)
    func rowCosine(_ m: MLXArray) -> MLXArray {
        let unit = m / sqrt((m * m).sum(axis: -1, keepDims: true) + 1e-8)
        return matmul(unit, unit.transposed())
    }
    let lossAndGrad = valueAndGrad({ (a: [MLXArray]) -> [MLXArray] in
        let p = Array(a[0..<(a.count - 2)])
        let z = net.forward(p, a[a.count - 2], indices: idx, mask: mask, windows: n)
        let target = a[a.count - 1]
        let y = (target - muArray) / sigmaArray
        var loss = (z - y).square().mean()
        if simWeight > 0 {
            let predicted = z * sigmaArray + muArray
            let sp = rowCosine(predicted.mean(axis: 1)), st = rowCosine(target.mean(axis: 1))
            loss = loss + simWeight * ((sp - st) / simScale).square().mean()
        }
        return [loss]
    }, argumentNumbers: Array(0..<net.params.count))
    let adam = Adam(net.params)
    var running: Float = 0
    let start = now()
    for step in 0..<steps {
        var x = [Float]()
        x.reserveCapacity(batch * cropFrames * bands)
        var y = [Float]()
        var chosen = Set<Int>()
        for _ in 0..<batch {
            var t = Int.random(in: 0..<pool.count, using: &rng)
            while chosen.contains(t) && chosen.count < pool.count { t = Int.random(in: 0..<pool.count, using: &rng) }
            chosen.insert(t)
            var track = pool[t]
            var k0 = Int.random(in: 0...(track.timbreCount - n), using: &rng)
            var tries = 0
            while track.isExcluded(from: Double(k0) * 0.975 - 1, to: Double(k0 + n) * 0.975 + 1) && tries < 20 {
                track = pool[Int.random(in: 0..<pool.count, using: &rng)]
                k0 = Int.random(in: 0...(track.timbreCount - n), using: &rng)
                tries += 1
            }
            let from = spec.windowStart(k0) - margin
            let aug = augmenting ? Augment.random(bands: bands, using: &rng) : nil
            x.append(contentsOf: net.normalised(track, from: from, to: from + cropFrames, augment: aug))
            y.append(contentsOf: track.timbre[(k0 * dim)..<((k0 + n) * dim)].map { Float($0) })
        }
        let (loss, grads) = lossAndGrad(net.params + [MLXArray(x, [batch, cropFrames, bands]), MLXArray(y, [batch, n, dim])])
        adam.update(&net.params, grads, lr: cosine(step), decay: decay)
        running = running * 0.98 + loss[0].item(Float.self) * 0.02
        if step % 500 == 0 || step == steps - 1 {
            print("step \(step) loss \(String(format: "%.4f", running / Float(1 - pow(0.98, Double(step + 1))))) \(String(format: "%.0f", now() - start))s")
        }
    }
    let k = net.params.count
    net.params[k - 2] = net.params[k - 2] * sigmaArray.reshaped([dim, 1])
    net.params[k - 1] = net.params[k - 1] * sigmaArray + muArray
    eval(net.params)
    let calibrationPredictions: [[Float]] = validation.map { net.predict($0, windows: $0.timbreCount) }
    func embeddings(_ set: [LabelTrack], _ predictions: [[Float]], alpha: Float) -> ([Embedding], [Embedding]) {
        var a: [Embedding] = [], o: [Embedding] = []
        for (track, predicted) in zip(set, predictions) {
            let frames = (0..<track.timbreCount).map { f in (0..<dim).map { mu[$0] + alpha * (predicted[f * dim + $0] - mu[$0]) } }
            a.append(Embedding(frames: (0..<track.timbreCount).map { f in (0..<dim).map { Float(track.timbre[f * dim + $0]) } }))
            o.append(Embedding(frames: frames))
        }
        return (a, o)
    }
    var bestAlpha: Float = 1, bestScore = -1.0
    for alpha in [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.75, 2.0] as [Float] {
        let (a, o) = embeddings(validation, calibrationPredictions, alpha: alpha)
        let g = TimbreGate.measure(apple: a, ours: o)
        print("alpha \(alpha) (validation): Spearman \(String(format: "%.4f", g.spearman)) top-5 \(String(format: "%.3f", g.top5))")
        if g.spearman > bestScore { bestScore = g.spearman; bestAlpha = alpha }
    }
    net.params[k - 2] = net.params[k - 2] * bestAlpha
    net.params[k - 1] = net.params[k - 1] * bestAlpha + (1 - bestAlpha) * muArray
    eval(net.params)
    try net.save(to: outURL.appendingPathComponent("TimbreModel.safetensors"), extra: ["trainHours": String(format: "%.1f", trainHours), "alpha": "\(bestAlpha)", "simWeight": "\(simWeight)"])
    let predictions: [[Float]] = evaluation.map { net.predict($0, windows: $0.timbreCount) }
    let (apple, ours) = embeddings(evaluation, predictions, alpha: 1)
    var frameCos = 0.0, frameCount = 0
    for (track, predicted) in zip(evaluation, predictions) {
        for f in 0..<track.timbreCount {
            frameCos += Embedding.cosine(Array(predicted[(f * dim)..<((f + 1) * dim)]), (0..<dim).map { Float(track.timbre[f * dim + $0]) })
            frameCount += 1
        }
    }
    let gate = TimbreGate.measure(apple: apple, ours: ours)
    print("RESULT timbre \(env["EVAL_SPLIT"] ?? "validation") hours \(String(format: "%.1f", timbreTrain.map(\.hours).reduce(0, +))) simW \(simWeight) alpha \(bestAlpha): \(evaluation.count) tracks; frame cosine \(String(format: "%.4f", frameCos / Double(max(1, frameCount)))); whole self-cosine min \(String(format: "%.4f", gate.minSelf)) median \(String(format: "%.4f", gate.medianSelf)); pair-cost Spearman \(String(format: "%.4f", gate.spearman)) over \(gate.pairs) pairs; top-5 \(String(format: "%.3f", gate.top5)) (blend \(String(format: "%.3f", gate.top5Blend)))")

default:
    print("unknown task \(task)")
}
