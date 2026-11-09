import Foundation

enum Learner {
    case logistic, mlp

    var config: TrainConfig {
        switch self {
        case .logistic:
            var c = TrainConfig(hidden: [], dropout: 0)
            c.learningRate = 0.01
            return c
        case .mlp:
            return TrainConfig()
        }
    }
}

struct Trained {
    var net: MLP
    var standard: Standardiser
    var features: [String]

    func score(_ r: Row) -> Double { net.predict(standard.apply(features.map { Float(r.f[$0] ?? .nan) })).good }
}

func train(_ rows: [Row], features: [String], learner: Learner, seed: UInt64 = 7) -> Trained? {
    let usable = rows.filter { !$0.borderline }
    guard usable.contains(where: \.good), usable.contains(where: { !$0.good }) else { return nil }
    let x = usable.map { r in features.map { Float(r.f[$0] ?? .nan) } }
    let standard = Standardiser(x)
    let examples = usable.indices.map { Example(x: standard.apply(x[$0]), good: usable[$0].good ? 1 : 0, rating: nil) }
    var c = learner.config
    c.seed = seed
    c.ratingWeight = 0
    return Trained(net: fit(examples, config: c).model, standard: standard, features: features)
}

func groupedScores(_ rows: [Row], features: [String], learner: Learner, holdout: (Row) -> String = { $0.group }) -> [Double] {
    var scores = [Double](repeating: .nan, count: rows.count)
    let groups = Array(Set(rows.map(holdout))).sorted()
    for (k, g) in groups.enumerated() {
        let trainRows = rows.filter { holdout($0) != g }
        guard let model = train(trainRows, features: features, learner: learner, seed: 7 &+ UInt64(k)) else { continue }
        for i in rows.indices where holdout(rows[i]) == g { scores[i] = model.score(rows[i]) }
    }
    return scores
}

func gateScores(_ rows: [Row]) -> [Double] { rows.map { 1 / Double(1 + $0.gates.count) } }

func vetoed(_ gates: [Double], _ learned: [Double]) -> [Double] {
    zip(gates, learned).map { g, p in g < 1 ? 0.001 * p : p }
}

struct Priors {
    static let names = ["blendLength", "energyStep", "vocalOverlap", "lowOverlap", "maxLevelJump"]
    static let floors: [String: Double] = ["blendLength": 0.5, "energyStep": 1, "vocalOverlap": 1, "lowOverlap": 0.05, "maxLevelJump": 1]
    var centre: [String: Double] = [:]
    var spread: [String: Double] = [:]
    var count = 0

    init(_ rows: [Row]) {
        count = rows.count
        for n in Self.names {
            let v = rows.compactMap { $0.f[n] }.filter(\.isFinite).sorted()
            guard !v.isEmpty else { continue }
            let med = v[v.count / 2]
            let mad = v.map { abs($0 - med) }.sorted()[v.count / 2] * 1.4826
            centre[n] = med
            spread[n] = max(mad, Self.floors[n] ?? 1)
        }
    }

    func score(_ r: Row) -> Double {
        var total = 0.0, n = 0.0
        for (k, c) in centre {
            guard let x = r.f[k], x.isFinite, let s = spread[k] else { continue }
            let z = (x - c) / s
            total += -0.5 * z * z
            n += 1
        }
        return n == 0 ? 0.5 : exp(total / n)
    }
}

struct Score {
    var n = 0
    var accuracy = Double.nan
    var auc = Double.nan
    var badRecall = Double.nan
    var falseAlarm = Double.nan
    var brier = Double.nan
    var ece = Double.nan

    init(_ scores: [Double], _ labels: [Bool], threshold: Double = 0.5) {
        let pairs = zip(scores, labels).filter { $0.0.isFinite }
        n = pairs.count
        guard n > 0 else { return }
        let s = pairs.map(\.0), y = pairs.map(\.1)
        accuracy = Double(zip(s, y).filter { ($0 >= threshold) == $1 }.count) / Double(n)
        auc = areaUnderCurve(s, y)
        let bad = y.filter { !$0 }.count, good = n - bad
        badRecall = bad == 0 ? .nan : Double(zip(s, y).filter { $0 < threshold && !$1 }.count) / Double(bad)
        falseAlarm = good == 0 ? .nan : Double(zip(s, y).filter { $0 < threshold && $1 }.count) / Double(good)
        brier = zip(s, y).map { pow($0 - ($1 ? 1 : 0), 2) }.reduce(0, +) / Double(n)
        var e = 0.0
        for b in 0..<5 {
            let lo = Double(b) / 5, hi = Double(b + 1) / 5
            let bin = zip(s, y).filter { $0.0 >= lo && ($0.0 < hi || (b == 4 && $0.0 <= hi)) }
            guard !bin.isEmpty else { continue }
            let conf = bin.map(\.0).reduce(0, +) / Double(bin.count)
            let acc = Double(bin.filter(\.1).count) / Double(bin.count)
            e += Double(bin.count) / Double(n) * abs(conf - acc)
        }
        ece = e
    }
}

struct Interval {
    var low: Double
    var high: Double
    var text: String { low.isFinite ? String(format: "[%.2f, %.2f]", low, high) : "n/a" }
    var excludesZero: Bool { low > 0 || high < 0 }
}

func percentile(_ v: [Double], _ p: Double) -> Double {
    let s = v.filter(\.isFinite).sorted()
    guard !s.isEmpty else { return .nan }
    return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
}

func bootstrap(_ rows: [Row], iterations: Int = 1000, seed: UInt64 = 11, _ statistic: ([Int]) -> Double) -> Interval {
    let groups = Dictionary(grouping: rows.indices, by: { rows[$0].group }).values.map { $0 }
    var rng = SeededRandom(seed: seed)
    var values: [Double] = []
    for _ in 0..<iterations {
        var idx: [Int] = []
        for _ in 0..<groups.count { idx += groups[Int(rng.next() % UInt64(groups.count))] }
        values.append(statistic(idx))
    }
    return Interval(low: percentile(values, 0.025), high: percentile(values, 0.975))
}

func f2(_ x: Double) -> String { x.isFinite ? String(format: "%.2f", x) : "n/a" }
func f3(_ x: Double) -> String { x.isFinite ? String(format: "%.3f", x) : "n/a" }
func pct(_ x: Double) -> String { x.isFinite ? String(format: "%.0f %%", x * 100) : "n/a" }
