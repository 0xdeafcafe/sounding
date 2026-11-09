import Foundation

struct Row {
    let v: [String: String]
    func d(_ k: String) -> Double { Double(v[k] ?? "") ?? .nan }
    func b(_ k: String) -> Bool { v[k] == "1" }
    var id: String { v["id"] ?? "" }
    var hasAI: Bool { !(v["aiConf"] ?? "").isEmpty }
    var aiTrusted: Bool { b("aiTrusted") }
    var offsets: [Double] { ["off0", "off1", "off2", "off3"].map { d($0) } }
    var offsetTotal: Double { offsets.reduce(0, +) }
    var beatsAgree: Bool { hasAI && d("beatF") >= 0.8 }
    var phaseCorrect: Bool { offsetTotal >= 8 && offsets[0] / offsetTotal >= 0.6 }
    var tempo: Double { d("aiBpm") > 0 && aiTrusted ? d("aiBpm") : d("bpm") }
    var band: String {
        let t = tempo
        switch t {
        case ..<1: return "none"
        case ..<100: return "<100 hip-hop/pop"
        case ..<118: return "100-118 disco/pop"
        case ..<130: return "118-130 house"
        case ..<140: return "130-140 techno/trance"
        case ..<156: return "140-156 hard/trance"
        default: return "156+ hardcore/dnb"
        }
    }
    var halfBarVote: Double {
        BeatTracker.smoothstep(1.5, 3.5, d("halfS")) * BeatTracker.smoothstep(0.3, 0.7, d("halfA"))
    }
    var reason: String {
        if d("bpm") <= 0 { return "no tempo" }
        if !b("tempoRel") {
            if d("clarity") < 0.45 { return "beats: weak periodicity" }
            if d("salient") < 0.55 { return "beats: sparse onsets" }
            if d("residualMs") > 12 { return "beats: unsteady timing" }
            return "beats: combined"
        }
        if d("parityConf") < 0.5 { return d("kick") < 1.3 ? "phase: no clear kick/backbeat" : "phase: 2/4 backbeat unclear" }
        if halfBarVote < 0.5 { return "phase: bar 1 vs 3 ambiguous" }
        return "phase: other"
    }
}

func load(_ path: String) -> [Row] {
    let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    guard let header = lines.first else { return [] }
    return lines.dropFirst().map { Row(v: Dictionary(uniqueKeysWithValues: zip(header, $0))) }
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%d/%d (%.0f%%)", a, b, 100 * Double(a) / Double(b)) }

func summarise(_ path: String, baseline: String?) {
    let rows = load(path)
    let n = rows.count
    print("== \(path)")
    print("tracks \(n)")
    print("tempo reliable   \(pct(rows.filter { $0.b("tempoRel") }.count, n))")
    print("beats reliable   \(pct(rows.filter { $0.b("beatRel") }.count, n))")
    print("phase reliable   \(pct(rows.filter { $0.b("phaseRel") }.count, n))  (planner gate isPhaseReliable)")
    print("bar phase reliable \(pct(rows.filter { $0.b("barRel") }.count, n))")
    print("parity reliable  \(pct(rows.filter { $0.b("parityRel") }.count, n))")
    var reasons: [String: Int] = [:]
    for r in rows where !r.b("phaseRel") { reasons[r.reason, default: 0] += 1 }
    print("-- why not phase reliable")
    for (k, c) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(k): \(c)") }
    print("-- by tempo band: tracks / beats reliable / phase reliable")
    var bands: [String: [Row]] = [:]
    for r in rows { bands[r.band, default: []].append(r) }
    for (k, list) in bands.sorted(by: { $0.key < $1.key }) {
        print("  \(k): \(list.count) / \(pct(list.filter { $0.b("beatRel") }.count, list.count)) / \(pct(list.filter { $0.b("phaseRel") }.count, list.count))")
    }
    func halfBeat(_ r: Row) -> Bool { r.d("bpm") > 0 && abs(r.d("lagMs")) / (60_000 / r.d("bpm")) >= 0.4 }
    func lagged(_ r: Row) -> Bool { !halfBeat(r) && abs(r.d("lagMs")) > 25 }
    let withLag = rows.filter { !($0.v["lagMs"] ?? "").isEmpty }
    print("-- beat phase vs reference: half-beat off \(pct(withLag.filter(halfBeat).count, withLag.count)), constant lag >25 ms \(withLag.filter(lagged).count); among beats-reliable: half-beat \(pct(withLag.filter { $0.b("beatRel") && halfBeat($0) }.count, withLag.filter { $0.b("beatRel") }.count)); tempo agrees after lag (F>=0.8) \(pct(withLag.filter { $0.d("beatFLag") >= 0.8 }.count, withLag.count))")
    let gt = rows.filter { $0.aiTrusted }
    let agree = gt.filter { $0.beatsAgree }
    print("-- against Beat This (trusted AI grids: \(gt.count) of \(rows.filter(\.hasAI).count) with AI)")
    print("  beats agree (F>=0.8): \(pct(agree.count, gt.count)); mean beat F \(String(format: "%.3f", gt.map { $0.d("beatF") }.reduce(0, +) / Double(max(1, gt.count))))")
    print("  bar phase correct (of beats-agree): \(pct(agree.filter(\.phaseCorrect).count, agree.count)); mean downbeat F \(String(format: "%.3f", agree.map { $0.d("downF") }.reduce(0, +) / Double(max(1, agree.count))))")
    for (name, gate) in [("phaseRel", "phaseRel"), ("barRel", "barRel"), ("beatRel", "beatRel")] {
        let g = agree.filter { $0.b(gate) }
        let all = gt.filter { $0.b(gate) }
        print("  \(name): beats agree \(pct(all.filter(\.beatsAgree).count, all.count)); bar phase correct \(pct(g.filter(\.phaseCorrect).count, g.count))")
    }
    print("  calibration of phaseConf (beats-agree tracks): bin / correct")
    for lo in stride(from: 0.0, to: 1.0, by: 0.2) {
        let bin = agree.filter { $0.d("phaseConf") >= lo && $0.d("phaseConf") < lo + 0.2 + (lo >= 0.8 ? 0.01 : 0) }
        print(String(format: "    %.1f-%.1f: ", lo, lo + 0.2) + pct(bin.filter(\.phaseCorrect).count, bin.count))
    }
    var offs = [0, 0, 0, 0, 0]
    for r in agree {
        if r.offsetTotal < 8 { offs[4] += 1; continue }
        offs[r.offsets.indices.max { r.offsets[$0] < r.offsets[$1] }!] += 1
    }
    print("  dominant bar offset of tracker downbeats vs AI (0 = right, 2 = half-bar flip, 1/3 = parity): \(offs[0]) / \(offs[1]) / \(offs[2]) / \(offs[3]) / few \(offs[4])")
    let ann = rows.filter { !($0.v["annBound"] ?? "").isEmpty }
    let bound = ann.reduce(0) { $0 + Int($1.d("annBound")) }, hit = ann.reduce(0) { $0 + Int($1.d("annHit")) }
    print("-- annotations: \(ann.count) tracks, annotated section starts on a tracker downbeat \(pct(hit, bound))")
    let ms = rows.reduce(0) { $0 + $1.d("analyseMs") }, sec = rows.reduce(0) { $0 + $1.d("seconds") }
    print(String(format: "-- cost: analyse %.1f ms per track mean, %.0fx realtime (features excluded)", ms / Double(max(1, n)), sec / max(1e-9, ms / 1000)))
    guard let baseline else { return }
    let before = Dictionary(uniqueKeysWithValues: load(baseline).map { ($0.id, $0) })
    var lost: [String] = [], gained = 0, wrongNow: [String] = [], fixed: [String] = []
    for r in rows {
        guard let b = before[r.id] else { continue }
        if b.b("phaseRel"), !r.b("phaseRel") { lost.append(r.id) }
        if !b.b("phaseRel"), r.b("phaseRel") { gained += 1 }
        if b.beatsAgree, r.beatsAgree, b.aiTrusted {
            if b.phaseCorrect, !r.phaseCorrect { wrongNow.append(r.id) }
            if !b.phaseCorrect, r.phaseCorrect { fixed.append(r.id) }
        }
    }
    print("-- vs baseline: phase reliable gained \(gained), lost \(lost.count) \(lost.prefix(12)); phase newly wrong \(wrongNow.count) \(wrongNow.prefix(12)); newly right \(fixed.count)")
    let wasReliable = rows.filter { before[$0.id]?.b("phaseRel") == true && $0.aiTrusted && $0.beatsAgree && before[$0.id]?.beatsAgree == true }
    print("  on baseline-reliable tracks: correct before \(pct(wasReliable.filter { before[$0.id]!.phaseCorrect }.count, wasReliable.count)) after \(pct(wasReliable.filter(\.phaseCorrect).count, wasReliable.count))")
}
