import Foundation

struct OffSample {
    let id: String
    let x: [Double]
    let off: Bool
    let confirmed: Bool
}

func logistic(_ samples: [OffSample], l2: Double = 0.01) -> [Double] {
    guard let dim = samples.first?.x.count else { return [] }
    var w = [Double](repeating: 0, count: dim + 1)
    for _ in 0..<4000 {
        var g = [Double](repeating: 0, count: dim + 1)
        for s in samples {
            var z = w[dim]
            for i in 0..<dim { z += w[i] * s.x[i] }
            let p = 1 / (1 + exp(-z))
            let e = p - (s.off ? 1 : 0)
            for i in 0..<dim { g[i] += e * s.x[i] }
            g[dim] += e
        }
        for i in 0...dim { w[i] -= 0.5 * (g[i] / Double(samples.count) + (i < dim ? l2 * w[i] : 0)) }
    }
    return w
}

func probability(_ w: [Double], _ x: [Double]) -> Double {
    var z = w[x.count]
    for i in x.indices { z += w[i] * x[i] }
    return 1 / (1 + exp(-z))
}

func runOffFit(_ samples: [OffSample]) {
    let names = ["low", "lowMid", "mid", "high", "midAlt", "lowAlt"]
    print("offbeat samples \(samples.count), off \(samples.filter(\.off).count), confirmed by Beat This \(samples.filter(\.confirmed).count)")
    for i in names.indices {
        let on = samples.filter { !$0.off }.map { $0.x[i] }, off = samples.filter(\.off).map { $0.x[i] }
        print("  \(names[i]): on mean \(s(on.reduce(0, +) / Double(max(1, on.count)))) off mean \(s(off.reduce(0, +) / Double(max(1, off.count))))")
    }
    let w = logistic(samples)
    print("weights " + zip(names + ["bias"], w).map { "\($0)=\(s($1))" }.joined(separator: " "))
    let even = samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    let odd = samples.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    let we = logistic(even), wo = logistic(odd)
    func acc(_ w: [Double], _ set: [OffSample], threshold: Double) -> String {
        let flagged = set.filter { probability(w, $0.x) >= threshold }
        let tp = flagged.filter(\.off).count
        return "flag \(flagged.count) right \(tp)/\(set.filter(\.off).count) off, wrong \(flagged.count - tp)/\(set.filter { !$0.off }.count) on"
    }
    for t in [0.5, 0.7, 0.85, 0.95] {
        print("  p>=\(t): train \(acc(w, samples, threshold: t)); held-out \(acc(we, odd, threshold: t)) | \(acc(wo, even, threshold: t))")
    }
    let missed = samples.filter { $0.off && probability(w, $0.x) < 0.7 }.map(\.id)
    let wrong = samples.filter { !$0.off && probability(w, $0.x) >= 0.7 }.map(\.id)
    print("missed off \(missed.prefix(24)) false \(wrong)")
}
