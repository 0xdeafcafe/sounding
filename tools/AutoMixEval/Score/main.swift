import Foundation

struct Review: Decodable {
    var id: String
    var verdict: String
    var score: Double
    var confidence: Double
    var reason: String?
}

var labelsPath: String?
var reviewPaths: [String] = []
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIterator.next() {
    if a == "--labels" { labelsPath = argIterator.next() } else { reviewPaths.append(a) }
}
guard let labelsPath, !reviewPaths.isEmpty else {
    print("usage: score --labels <truth/labels.json> <reviewer.json> [reviewer.json ...]")
    exit(2)
}

let labelRows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: labelsPath))) as! [[String: Any]]
var labels: [String: [String: Any]] = [:]
for row in labelRows { labels[row["id"] as! String] = row }
let truth = labels.mapValues { $0["truth"] as! String }
let metricNames = ["energyStepDB", "maxLevelJumpDB", "vocalOverlapSeconds", "vocalUnderBlendSeconds", "phaseErrorMs", "doubleBassSeconds", "clicks", "payoffOverlapSeconds", "incomingEntryRMSDB", "peakDBFS"]

func faultKey(_ id: String) -> String {
    let l = labels[id]!
    return (l["fault"] as? String) ?? "none (\(l["source"] as! String))"
}

func metric(_ id: String, _ name: String) -> Double? {
    guard let m = labels[id]?["metrics"] as? [String: Any], let v = m[name] as? Double else { return nil }
    return name == "phaseErrorMs" || name == "energyStepDB" ? abs(v) : v
}

func fmt(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "n/a" }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func ranks(_ xs: [Double]) -> [Double] {
    let order = xs.indices.sorted { xs[$0] < xs[$1] }
    var r = [Double](repeating: 0, count: xs.count)
    var i = 0
    while i < order.count {
        var j = i
        while j + 1 < order.count, xs[order[j + 1]] == xs[order[i]] { j += 1 }
        for k in i...j { r[order[k]] = Double(i + j) / 2 + 1 }
        i = j + 1
    }
    return r
}

func pearson(_ a: [Double], _ b: [Double]) -> Double? {
    let n = Double(a.count)
    guard a.count >= 3 else { return nil }
    let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    let va = a.reduce(0) { $0 + ($1 - ma) * ($1 - ma) }, vb = b.reduce(0) { $0 + ($1 - mb) * ($1 - mb) }
    guard va > 0, vb > 0 else { return nil }
    return zip(a, b).reduce(0) { $0 + ($1.0 - ma) * ($1.1 - mb) } / sqrt(va * vb)
}

func spearman(_ a: [Double], _ b: [Double]) -> Double? { pearson(ranks(a), ranks(b)) }

func kappa(_ a: [String], _ b: [String]) -> Double? {
    guard !a.isEmpty else { return nil }
    let n = Double(a.count)
    let po = Double(zip(a, b).filter { $0 == $1 }.count) / n
    var pe = 0.0
    for k in Set(a).union(b) { pe += Double(a.filter { $0 == k }.count) * Double(b.filter { $0 == k }.count) / (n * n) }
    return pe == 1 ? nil : (po - pe) / (1 - pe)
}

func binary(_ name: String, _ truthMap: [String: String], _ pred: [String: String], _ ids: [String]) {
    let pairs = ids.compactMap { id -> (String, String)? in
        guard let t = truthMap[id], t == "good" || t == "bad", let p = pred[id] else { return nil }
        return (t, p)
    }
    let tp = pairs.filter { $0 == ("bad", "bad") }.count
    let fp = pairs.filter { $0 == ("good", "bad") }.count
    let fn = pairs.filter { $0 == ("bad", "good") }.count
    let tn = pairs.filter { $0 == ("good", "good") }.count
    let acc = pairs.isEmpty ? nil : Double(tp + tn) / Double(pairs.count)
    let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : nil
    let recall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : nil
    print("  \(name): accuracy \(fmt(acc)), bad precision \(fmt(precision)), bad recall \(fmt(recall)) on \(pairs.count) good/bad cases")
}

var counts: [String: Int] = [:]
for t in truth.values { counts[t, default: 0] += 1 }
print("Labels: \(labels.count) cases, " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

var reviewers: [(String, [String: Review])] = []
for path in reviewPaths {
    let rows = try JSONDecoder().decode([Review].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var map: [String: Review] = [:]
    for r in rows where labels[r.id] != nil { map[r.id] = r }
    reviewers.append((URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, map))
}

for (name, rows) in reviewers {
    let ids = rows.keys.sorted()
    let missing = labels.count - ids.count
    print("\n== \(name): \(ids.count) reviewed" + (missing > 0 ? ", \(missing) missing" : ""))
    let pred = rows.mapValues { $0.verdict }
    binary("strict (borderline excluded)", truth, pred, ids)
    binary("borderline counted as bad", truth.mapValues { $0 == "borderline" ? "bad" : $0 }, pred, ids)
    print("  confusion (rows truth, columns verdict):")
    print("               good    bad")
    for t in ["good", "borderline", "bad"] {
        let g = ids.filter { truth[$0] == t && pred[$0] == "good" }.count
        let b = ids.filter { truth[$0] == t && pred[$0] == "bad" }.count
        print("    \(pad(t, 10)) \(String(format: "%5d %6d", g, b))")
    }
    var byTruth: [String: [Double]] = [:]
    for id in ids { byTruth[truth[id]!, default: []].append(rows[id]!.score) }
    print("  mean score by truth: " + byTruth.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value.reduce(0, +) / Double($0.value.count)))" }.joined(separator: ", "))
    let decided = ids.filter { truth[$0] == "good" || truth[$0] == "bad" }
    let right = decided.filter { pred[$0] == truth[$0] }.map { rows[$0]!.confidence }
    let wrong = decided.filter { pred[$0] != truth[$0] }.map { rows[$0]!.confidence }
    print("  mean confidence when right \(fmt(right.isEmpty ? nil : right.reduce(0, +) / Double(right.count))), when wrong \(fmt(wrong.isEmpty ? nil : wrong.reduce(0, +) / Double(wrong.count)))")
    print("  fault types flagged bad / total:")
    var groups: [String: (Int, Int)] = [:]
    for id in ids {
        let key = pad(faultKey(id), 36) + " [\(pad(truth[id]!, 10))]"
        var g = groups[key, default: (0, 0)]
        g.1 += 1
        if pred[id] == "bad" { g.0 += 1 }
        groups[key] = g
    }
    for (k, v) in groups.sorted(by: { $0.key < $1.key }) { print("    \(k) \(v.0)/\(v.1)") }
    print("  Spearman of reviewer score vs objective metrics (negative = higher metric, lower score):")
    for m in metricNames {
        var xs: [Double] = [], ys: [Double] = []
        for id in ids { if let v = metric(id, m) { xs.append(v); ys.append(rows[id]!.score) } }
        print("    \(pad(m, 26)) \(fmt(spearman(xs, ys))) (n=\(xs.count))")
    }
}

if reviewers.count >= 2 {
    print("\n== Agreement between reviewers")
    for x in 0..<reviewers.count {
        for y in (x + 1)..<reviewers.count {
            let (an, a) = reviewers[x], (bn, b) = reviewers[y]
            let common = Set(a.keys).intersection(b.keys).sorted()
            let va = common.map { a[$0]!.verdict }, vb = common.map { b[$0]!.verdict }
            let agree = common.isEmpty ? nil : Double(zip(va, vb).filter { $0 == $1 }.count) / Double(common.count)
            print("  \(an) vs \(bn): verdict agreement \(fmt(agree)), Cohen kappa \(fmt(kappa(va, vb))), score Spearman \(fmt(spearman(common.map { a[$0]!.score }, common.map { b[$0]!.score }))) (n=\(common.count))")
        }
    }
    let common = reviewers.map { Set($0.1.keys) }.reduce(Set(labels.keys)) { $0.intersection($1) }.sorted()
    var majority: [String: String] = [:]
    var split: [String] = []
    for id in common {
        let votes = reviewers.map { $0.1[id]!.verdict }
        let bad = votes.filter { $0 == "bad" }.count
        majority[id] = bad * 2 > votes.count ? "bad" : "good"
        if Set(votes).count > 1 { split.append(id) }
    }
    binary("majority vote", truth, majority, common)
    print("  split decisions: \(split.count) " + split.joined(separator: " "))
}

print("\n== Gates alone (any hard gate failing = bad)")
let gatePred = labels.mapValues { ($0["gatesFlagged"] as? Bool) == true ? "bad" : "good" }
binary("gates", truth, gatePred, labels.keys.sorted())
var gateGroups: [String: (Int, Int)] = [:]
var perGate: [String: Int] = [:]
for (id, l) in labels {
    let key = pad(faultKey(id), 36) + " [\(pad(truth[id]!, 10))]"
    var g = gateGroups[key, default: (0, 0)]
    g.1 += 1
    if gatePred[id] == "bad" { g.0 += 1 }
    gateGroups[key] = g
    for f in (l["gatesFailed"] as? [String]) ?? [] { perGate[f, default: 0] += 1 }
}
for (k, v) in gateGroups.sorted(by: { $0.key < $1.key }) { print("    \(k) \(v.0)/\(v.1) flagged by gates") }
print("  gate failures: " + perGate.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
print("  note: truth for un-injected cases is derived from the same gates, so gate accuracy is only meaningful on injected faults")

if !reviewers.isEmpty {
    print("\n== Reviewers vs gates on true-bad cases")
    for (name, rows) in reviewers {
        let bad = rows.keys.filter { truth[$0] == "bad" }.sorted()
        let both = bad.filter { rows[$0]!.verdict == "bad" && gatePred[$0] == "bad" }
        let reviewerOnly = bad.filter { rows[$0]!.verdict == "bad" && gatePred[$0] != "bad" }
        let gateOnly = bad.filter { rows[$0]!.verdict != "bad" && gatePred[$0] == "bad" }
        let neither = bad.filter { rows[$0]!.verdict != "bad" && gatePred[$0] != "bad" }
        print("  \(name): both \(both.count), reviewer only \(reviewerOnly.count) \(reviewerOnly.joined(separator: " ")), gates only \(gateOnly.count), neither \(neither.count) \(neither.joined(separator: " "))")
    }
}
