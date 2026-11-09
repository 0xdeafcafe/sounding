import Foundation

func areaUnderCurve(_ scores: [Double], _ labels: [Bool]) -> Double {
    let pos = zip(scores, labels).filter { $0.1 }.map(\.0)
    let neg = zip(scores, labels).filter { !$0.1 }.map(\.0)
    guard !pos.isEmpty, !neg.isEmpty else { return .nan }
    var wins = 0.0
    for p in pos { for n in neg { wins += p > n ? 1 : (p == n ? 0.5 : 0) } }
    return wins / Double(pos.count * neg.count)
}

struct Metrics {
    var accuracy: Double
    var auc: Double
    var badRecall: Double
    var badPrecision: Double
    var count: Int

    init(scores: [Double], labels: [Bool], threshold: Double = 0.5) {
        let predictedGood = scores.map { $0 >= threshold }
        count = labels.count
        accuracy = Double(zip(predictedGood, labels).filter { $0 == $1 }.count) / Double(max(1, labels.count))
        auc = areaUnderCurve(scores, labels)
        let bad = labels.filter { !$0 }.count
        let caught = zip(predictedGood, labels).filter { !$0 && !$1 }.count
        let flagged = predictedGood.filter { !$0 }.count
        badRecall = bad == 0 ? .nan : Double(caught) / Double(bad)
        badPrecision = flagged == 0 ? .nan : Double(caught) / Double(flagged)
    }

    var line: String {
        String(format: "acc %.3f  AUC %.3f  bad-recall %.3f  bad-precision %.3f  (n=%d)", accuracy, auc, badRecall, badPrecision, count)
    }
}

enum Gates {
    static let index = Dictionary(uniqueKeysWithValues: AutoMixNetFeatures.names.enumerated().map { ($1, $0) })

    static func fired(_ x: [Float]) -> [String] {
        func v(_ name: String) -> Float? {
            let value = x[index[name]!]
            return value.isFinite ? value : nil
        }
        var out: [String] = []
        let barSeconds: Float = 1.94
        if let vocal = v("vocalOverlap"), vocal > Float(DJMixRules.keyClashOverlapBars) * barSeconds { out.append("vocal") }
        if let phase = v("phaseError"), phase > Float(DJMixRules.phraseBeatTolerance) { out.append("phase") }
        if let bpm = v("bpmDelta"), bpm > 1.0 { out.append("tempo") }
        if let jump = v("maxLevelJump"), jump > Float(DJMixRules.maxLevelStepDecibels) { out.append("level") }
        if let key = v("keyDistance"), key > 2, let blend = v("blendLength"), blend > log2(1 + Float(DJMixRules.keyClashOverlapBars)) { out.append("key") }
        return out
    }

    static func score(_ x: [Float]) -> Double { 1 / Double(1 + fired(x).count) }
}

struct FoldResult {
    var scores: [Double]
    var ratings: [Double]
    var epochs: [Int]
}

func stratifiedFolds(_ labels: [Bool], k: Int, seed: UInt64) -> [Int] {
    var rng = SeededRandom(seed: seed)
    var fold = [Int](repeating: 0, count: labels.count)
    for value in [true, false] {
        var idx = labels.indices.filter { labels[$0] == value }
        rng.shuffle(&idx)
        for (n, i) in idx.enumerated() { fold[i] = n % k }
    }
    return fold
}

func crossValidate(_ rows: [[Float]], _ labels: [Bool], _ ratings: [Double?], k: Int, config: TrainConfig, permute: Bool) -> (FoldResult, [Double]) {
    let folds = stratifiedFolds(labels, k: k, seed: config.seed)
    var scores = [Double](repeating: .nan, count: rows.count)
    var predictedRatings = [Double](repeating: .nan, count: rows.count)
    var epochs: [Int] = []
    let d = rows[0].count
    var importance = [Double](repeating: 0, count: d)
    for f in 0..<k {
        let trainIdx = rows.indices.filter { folds[$0] != f }
        let testIdx = rows.indices.filter { folds[$0] == f }
        guard !testIdx.isEmpty else { continue }
        let standard = Standardiser(trainIdx.map { rows[$0] })
        let train = trainIdx.map { Example(x: standard.apply(rows[$0]), good: labels[$0] ? 1 : 0, rating: ratings[$0]) }
        var c = config
        c.seed = config.seed &+ UInt64(f)
        let (net, used) = fit(train, config: c)
        epochs.append(used)
        let testX = testIdx.map { standard.apply(rows[$0]) }
        for (n, i) in testIdx.enumerated() {
            let p = net.predict(testX[n])
            scores[i] = p.good
            predictedRatings[i] = p.rating
        }
        if permute {
            let testLabels = testIdx.map { labels[$0] }
            let base = areaUnderCurve(testX.map { net.predict($0).good }, testLabels)
            var rng = SeededRandom(seed: 99 &+ UInt64(f))
            for j in 0..<d {
                var drop = 0.0
                for _ in 0..<3 {
                    var column = testX.map { $0[j] }
                    rng.shuffle(&column)
                    let permuted = testX.enumerated().map { n, x -> [Double] in var y = x; y[j] = column[n]; return y }
                    drop += base - areaUnderCurve(permuted.map { net.predict($0).good }, testLabels)
                }
                importance[j] += drop / 3 / Double(k)
            }
        }
    }
    return (FoldResult(scores: scores, ratings: predictedRatings, epochs: epochs), importance)
}

func ratingError(_ predicted: [Double], _ truth: [Double?]) -> Double {
    let pairs = zip(predicted, truth).compactMap { p, t in t.map { (p, $0) } }
    guard !pairs.isEmpty else { return .nan }
    return pairs.map { abs($0 - $1) }.reduce(0, +) / Double(pairs.count)
}
