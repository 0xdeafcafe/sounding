import Foundation

struct Embedding {
    let whole: [Int8]
    let opening: [Int8]
    let closing: [Int8]

    init(frames vectors: [[Float]], edgeShare: Double = 0.3) {
        let edge = max(1, Int((Double(vectors.count) * edgeShare).rounded()))
        whole = Self.quantised(Self.pooled(vectors[...]))
        opening = Self.quantised(Self.pooled(vectors.prefix(edge)))
        closing = Self.quantised(Self.pooled(vectors.suffix(edge)))
    }

    static func pooled(_ vectors: ArraySlice<[Float]>) -> [Float] {
        guard let dimension = vectors.first?.count else { return [] }
        var sum = [Float](repeating: 0, count: dimension)
        for vector in vectors { for i in 0..<dimension { sum[i] += vector[i] } }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    static func quantised(_ vector: [Float]) -> [Int8] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let unit = norm > 0 ? vector.map { $0 / norm } : vector
        return unit.map { Int8(max(-127, min(127, ($0 * 127).rounded()))) }
    }

    static func cosine(_ a: [Int8], _ b: [Int8]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
        }
        return na > 0 && nb > 0 ? dot / (na * nb).squareRoot() : 0
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
        }
        return na > 0 && nb > 0 ? dot / (na * nb).squareRoot() : 0
    }

    static func blend(_ from: Embedding, _ to: Embedding) -> Double {
        0.65 * cosine(from.whole, to.whole) + 0.35 * cosine(from.closing, to.opening)
    }

    static func cost(_ from: Embedding, _ to: Embedding) -> Double {
        min(1, max(0, (0.93 - blend(from, to)) / (0.93 - 0.8))) * 0.7
    }
}

struct TimbreGate {
    var spearman = 0.0
    var pairs = 0
    var top5 = 0.0
    var top5Blend = 0.0
    var minSelf = 1.0
    var medianSelf = 1.0

    static func measure(apple: [Embedding], ours: [Embedding]) -> TimbreGate {
        var gate = TimbreGate()
        var a: [Double] = [], b: [Double] = []
        var overlap = 0.0, overlapBlend = 0.0
        for i in apple.indices {
            var rowA: [(Int, Double, Double)] = [], rowB: [(Int, Double, Double)] = []
            for j in apple.indices where j != i {
                let ca = Embedding.cost(apple[i], apple[j]), cb = Embedding.cost(ours[i], ours[j])
                a.append(ca)
                b.append(cb)
                rowA.append((j, ca, -Embedding.blend(apple[i], apple[j])))
                rowB.append((j, cb, -Embedding.blend(ours[i], ours[j])))
            }
            func top(_ row: [(Int, Double, Double)], blend: Bool) -> Set<Int> {
                Set(row.sorted { blend ? $0.2 < $1.2 : ($0.1, $0.0) < ($1.1, $1.0) }.prefix(5).map(\.0))
            }
            overlap += Double(top(rowA, blend: false).intersection(top(rowB, blend: false)).count) / 5
            overlapBlend += Double(top(rowA, blend: true).intersection(top(rowB, blend: true)).count) / 5
        }
        gate.pairs = a.count
        gate.spearman = spearmanRank(a, b)
        gate.top5 = overlap / Double(max(1, apple.count))
        gate.top5Blend = overlapBlend / Double(max(1, apple.count))
        let selves = zip(apple, ours).map { Embedding.cosine($0.whole, $1.whole) }.sorted()
        gate.minSelf = selves.first ?? 0
        gate.medianSelf = selves.isEmpty ? 0 : selves[selves.count / 2]
        return gate
    }
}

func spearmanRank(_ a: [Double], _ b: [Double]) -> Double {
    func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let avg = Double(i + j) / 2
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }
    let ra = ranks(a), rb = ranks(b)
    let ma = ra.reduce(0, +) / Double(max(1, ra.count)), mb = rb.reduce(0, +) / Double(max(1, rb.count))
    var num = 0.0, da = 0.0, db = 0.0
    for i in ra.indices {
        num += (ra[i] - ma) * (rb[i] - mb)
        da += (ra[i] - ma) * (ra[i] - ma)
        db += (rb[i] - mb) * (rb[i] - mb)
    }
    return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
}
