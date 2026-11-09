import Foundation

struct FitSample {
    let id: String
    let cues: [[Double]]
    let parity: Double
    let halfBar: Double
    let truth: Int
    let baselineConfidence: Double
}

func combined(_ s: FitSample, _ w: [Double]) -> [Double] {
    (0..<4).map { d in
        var v = 0.0
        for c in s.cues.indices { v += w[c] * s.cues[c][d] }
        v += w[s.cues.count] * s.parity * (d % 2 == 0 ? 1 : -1)
        v += w[s.cues.count + 1] * s.halfBar * (d == 0 ? 1 : d == 2 ? -1 : 0)
        return v
    }
}

func posterior(_ l: [Double], kappa: Double) -> [Double] {
    let m = l.max() ?? 0
    let e = l.map { exp(kappa * ($0 - m)) }
    let t = e.reduce(0, +)
    return e.map { $0 / t }
}

func accuracy(_ samples: [FitSample], _ w: [Double]) -> Double {
    let hits = samples.filter { s in
        let l = combined(s, w)
        return l.indices.max { l[$0] < l[$1] } == s.truth
    }.count
    return Double(hits) / Double(max(1, samples.count))
}

func logLikelihood(_ samples: [FitSample], _ w: [Double], kappa: Double) -> Double {
    samples.reduce(0) { $0 + log(max(1e-6, posterior(combined($1, w), kappa: kappa)[$1.truth])) }
}

func bestKappa(_ samples: [FitSample], _ w: [Double]) -> Double {
    var best = (k: 1.0, ll: -Double.infinity)
    for k in stride(from: 0.05, through: 3.0, by: 0.05) {
        let ll = logLikelihood(samples, w, kappa: k)
        if ll > best.ll { best = (k, ll) }
    }
    return best.k
}

func fitWeights(_ samples: [FitSample], names: [String]) -> [Double] {
    var w = [Double](repeating: 0, count: names.count)
    w[names.count - 2] = 1
    w[names.count - 1] = 1
    let grid = [0, 0.25, 0.5, 1, 1.5, 2, 3]
    func objective(_ w: [Double]) -> Double { accuracy(samples, w) * 1000 + logLikelihood(samples, w, kappa: bestKappa(samples, w)) * 0.01 }
    var current = objective(w)
    for _ in 0..<3 {
        for c in w.indices {
            for g in grid {
                var t = w
                t[c] = g
                let o = objective(t)
                if o > current + 1e-9 { current = o; w = t }
            }
        }
    }
    return w
}

func runFit(_ samples: [FitSample]) {
    let names = ["novelty", "rise", "kickReturn", "harmonicChange", "crash", "kick", "harmonic4", "lowEnergy4", "parity", "halfBar"]
    print("fit samples \(samples.count); truth shifts \((0..<4).map { d in samples.filter { $0.truth == d }.count })")
    print("baseline (no shift) accuracy \(s(Double(samples.filter { $0.truth == 0 }.count) / Double(max(1, samples.count))))")
    for c in 0..<(names.count - 2) {
        var w = [Double](repeating: 0, count: names.count)
        w[c] = 1
        print("  \(names[c]) alone: \(s(accuracy(samples, w)))")
    }
    var drums = [Double](repeating: 0, count: names.count)
    drums[names.count - 2] = 1
    drums[names.count - 1] = 1
    print("  parity+halfBar: \(s(accuracy(samples, drums)))")
    let w = fitWeights(samples, names: names)
    let k = bestKappa(samples, w)
    print("fitted \(zip(names, w).map { "\($0)=\($1)" }.joined(separator: " ")) kappa \(s(k, 2)) accuracy \(s(accuracy(samples, w)))")
    let even = samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    let odd = samples.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    let we = fitWeights(even, names: names), wo = fitWeights(odd, names: names)
    print("2-fold held-out accuracy: \(s(accuracy(odd, we))) / \(s(accuracy(even, wo)))")
    print("calibration (fitted): bin / correct")
    for lo in stride(from: 0.25, to: 1.0, by: 0.15) {
        let bin = samples.filter { s in
            let p = posterior(combined(s, w), kappa: k).max()!
            return p >= lo && p < lo + 0.15 + (lo > 0.8 ? 0.01 : 0)
        }
        let hits = bin.filter { s in let l = combined(s, w); return l.indices.max { l[$0] < l[$1] } == s.truth }.count
        print(String(format: "  %.2f-%.2f: %@", lo, lo + 0.15, pct(hits, bin.count)))
    }
    let wrong = samples.filter { s in let l = combined(s, w); return l.indices.max { l[$0] < l[$1] } != s.truth }
    print("wrong: " + wrong.map { "\($0.id)(t\($0.truth) p\(s(posterior(combined($0, w), kappa: k).max()!, 2)))" }.joined(separator: " "))
}
