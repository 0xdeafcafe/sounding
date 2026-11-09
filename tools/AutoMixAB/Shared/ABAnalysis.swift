import Foundation

struct ABComparisonReport: Codable {
    struct Interval: Codable { var low: Double; var high: Double }
    struct Split: Codable { var heldOut: String; var pairs: Int; var rate: Double }
    struct HeldOut: Codable { var by: String; var splits: [Split]; var lowest: Double?; var highest: Double?; var flips: Int }

    var focus: String
    var other: String
    var kind: String
    var judgments: Int
    var pairs: Int
    var wins: Int
    var losses: Int
    var ties: Int
    var preferenceRate: Double
    var interval: Interval
    var faults: [String: [String: Int]]
    var faultRates: [String: [String: Double]]
    var heldOut: [HeldOut]
}

enum ABAnalysis {
    struct Vote {
        var pair: String
        var score: Double
        var tracks: [ABTrack]
        var focusFaults: [ABFault]
        var otherFaults: [ABFault]
    }

    static func votes(_ judgments: [ABJudgment], focus: String, other: String) -> [Vote] {
        judgments.compactMap { j in
            let variants = Set([j.aVariant, j.bVariant])
            guard variants == Set([focus, other]) else { return nil }
            let score: Double
            switch j.preference {
            case .neither: score = 0.5
            case .a: score = j.aVariant == focus ? 1 : 0
            case .b: score = j.bVariant == focus ? 1 : 0
            }
            let focusIsA = j.aVariant == focus
            return Vote(pair: j.pair, score: score, tracks: j.tracks, focusFaults: focusIsA ? j.aFaults : j.bFaults, otherFaults: focusIsA ? j.bFaults : j.aFaults)
        }
    }

    static func pairScores(_ votes: [Vote]) -> [String: Double] {
        var grouped: [String: [Double]] = [:]
        for v in votes { grouped[v.pair, default: []].append(v.score) }
        return grouped.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    static func rate(_ scores: [Double]) -> Double {
        scores.isEmpty ? .nan : scores.reduce(0, +) / Double(scores.count)
    }

    static func bootstrap(_ scores: [Double], resamples: Int = 5000, seed: UInt64 = 0xAB_2026) -> ABComparisonReport.Interval {
        guard !scores.isEmpty else { return .init(low: .nan, high: .nan) }
        var rng = ABRandom(state: seed)
        var means: [Double] = []
        means.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var s = 0.0
            for _ in scores.indices { s += scores[rng.below(scores.count)] }
            means.append(s / Double(scores.count))
        }
        means.sort()
        return .init(low: means[Int(Double(resamples) * 0.025)], high: means[min(resamples - 1, Int(Double(resamples) * 0.975))])
    }

    static func heldOut(_ votes: [Vote], by: String, key: (ABTrack) -> String) -> ABComparisonReport.HeldOut {
        let groups = Set(votes.flatMap { $0.tracks.map(key) }).sorted()
        var splits: [ABComparisonReport.Split] = []
        for g in groups {
            let kept = votes.filter { !$0.tracks.map(key).contains(g) }
            let scores = Array(pairScores(kept).values)
            guard !scores.isEmpty else { continue }
            splits.append(.init(heldOut: g, pairs: scores.count, rate: rate(scores)))
        }
        let all = rate(Array(pairScores(votes).values))
        let flips = splits.filter { ($0.rate - 0.5) * (all - 0.5) < 0 }.count
        return .init(by: by, splits: splits, lowest: splits.map(\.rate).min(), highest: splits.map(\.rate).max(), flips: flips)
    }

    static func compare(_ judgments: [ABJudgment], focus: String, other: String, kind: String) -> ABComparisonReport {
        let v = votes(judgments, focus: focus, other: other)
        let scores = Array(pairScores(v).values)
        var faults: [String: [String: Int]] = [focus: [:], other: [:]]
        for vote in v {
            for f in vote.focusFaults { faults[focus, default: [:]][f.rawValue, default: 0] += 1 }
            for f in vote.otherFaults { faults[other, default: [:]][f.rawValue, default: 0] += 1 }
        }
        let n = Double(max(1, v.count))
        let rates = faults.mapValues { $0.mapValues { Double($0) / n } }
        return ABComparisonReport(
            focus: focus, other: other, kind: kind, judgments: v.count, pairs: scores.count,
            wins: v.filter { $0.score == 1 }.count, losses: v.filter { $0.score == 0 }.count, ties: v.filter { $0.score == 0.5 }.count,
            preferenceRate: rate(scores), interval: bootstrap(scores), faults: faults, faultRates: rates,
            heldOut: [heldOut(v, by: "artist") { $0.artist.lowercased() }, heldOut(v, by: "track") { $0.id }]
        )
    }

    static func loadSessions(_ urls: [URL]) -> [ABSession] {
        urls.compactMap { try? ABCoding.decoder.decode(ABSession.self, from: Data(contentsOf: $0)) }
    }

    static func resultFiles(near manifest: URL) -> [URL] {
        let dir = manifest.deletingLastPathComponent().appendingPathComponent("results")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    static func text(_ r: ABComparisonReport) -> String {
        func pct(_ x: Double) -> String { x.isNaN ? "n/a" : String(format: "%.0f%%", x * 100) }
        var lines: [String] = []
        lines.append("\(r.focus) vs \(r.other) [\(r.kind)]: \(r.judgments) judgments over \(r.pairs) pairs")
        lines.append("  \(r.focus) preferred \(pct(r.preferenceRate)) (95% pair bootstrap \(pct(r.interval.low))–\(pct(r.interval.high))); wins \(r.wins), losses \(r.losses), no preference \(r.ties)")
        if !r.interval.low.isNaN {
            let verdict = r.interval.low > 0.5 ? "\(r.focus) is better" : r.interval.high < 0.5 ? "\(r.other) is better" : "not separable yet"
            lines.append("  verdict: \(verdict)")
        }
        for variant in [r.focus, r.other] {
            let tags = (r.faults[variant] ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
            lines.append("  faults in \(variant): " + (tags.isEmpty ? "none" : tags.joined(separator: ", ")))
        }
        for h in r.heldOut {
            let range = h.lowest.map { "\(pct($0))–\(pct(h.highest ?? $0))" } ?? "n/a"
            lines.append("  leave one \(h.by) out: \(h.splits.count) splits, rate \(range), \(h.flips) flip the verdict side")
        }
        return lines.joined(separator: "\n")
    }
}
