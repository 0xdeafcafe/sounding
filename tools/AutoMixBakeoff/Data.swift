import Foundation

struct Row {
    var id: String
    var group: String
    var pair: String
    var tracks: [String]
    var fault: String?
    var good: Bool
    var borderline = false
    var f: [String: Double]
    var objective: [String: Double]
    var gates: [String]
    var plannerPick = false
    var reviewers: [String: Double] = [:]
}

struct BakeoffDataset {
    var name: String
    var rows: [Row]
    var features: [String]
    var aiFeatures: [String]
    var faultFeatures: [String: [String]]
    var objectiveNames: [String]
}

struct Paths {
    var eval: URL
    var synthetic: URL
    var analysis: URL
    var aiOutput: URL
    var setReports: URL
    var priors: URL
    var ratings: [URL]
}

struct StemRanges: Decodable {
    struct Range: Decodable { var start: Double; var end: Double }
    var vocalRanges: [Range]
    var bassRanges: [Range]
}

struct BeatThisOutput: Decodable {
    var confidence: Double
    var downbeatConfidence: Double?
}

struct AIFeatures {
    var stems: [String: StemRanges] = [:]
    var beats: [String: BeatThisOutput] = [:]

    init(directory: URL, ids: [String]) {
        for id in ids {
            if let d = try? Data(contentsOf: directory.appendingPathComponent("stems-\(id).json")), let s = try? JSONDecoder().decode(StemRanges.self, from: d) { stems[id] = s }
            if let d = try? Data(contentsOf: directory.appendingPathComponent("beatthis-\(id).json")), let b = try? JSONDecoder().decode(BeatThisOutput.self, from: d) { beats[id] = b }
        }
    }

    var available: Bool { !stems.isEmpty && !beats.isEmpty }

    static func inside(_ ranges: [StemRanges.Range], _ t: Double) -> Bool { ranges.contains { $0.start <= t && t < $0.end } }

    func values(outgoing a: String, incoming b: String, exit: Double, window: Double, entry: Double, rate: Double) -> [String: Double] {
        guard let sa = stems[a], let sb = stems[b], let ba = beats[a], let bb = beats[b] else { return [:] }
        var vocal = 0.0, bass = 0.0
        let step = 0.1
        var u = 0.0
        while u < max(window, step) {
            let ta = exit + u, tb = entry + u * rate
            if Self.inside(sa.vocalRanges, ta) && Self.inside(sb.vocalRanges, tb) { vocal += step }
            if Self.inside(sa.bassRanges, ta) && Self.inside(sb.bassRanges, tb) { bass += step }
            u += step
        }
        return ["ai.vocalOverlap": vocal, "ai.bassOverlap": bass / max(window, step), "ai.beatConfidence": min(ba.confidence, bb.confidence)]
    }
}

func pairKey(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "+") }

func loadAnalysis(_ directory: URL, _ id: String) -> BeatTrackerResult? {
    guard let d = try? Data(contentsOf: directory.appendingPathComponent("analysis-\(id)-bands.json")) else { return nil }
    return try? JSONDecoder().decode(BeatTrackerResult.self, from: d)
}

let trackIds = ["darkknight", "jungle", "marionette", "voodoo"]

func vectorDictionary(_ o: AutoMixNetObservation) -> [String: Double] {
    let v = AutoMixNetFeatures.vector(o)
    var out: [String: Double] = [:]
    for (k, name) in AutoMixNetFeatures.names.enumerated() { out[name] = Double(v[k]) }
    return out
}

func syntheticDataset(_ paths: Paths, ai: AIFeatures) -> BakeoffDataset? {
    struct File: Decodable { var samples: [SyntheticPair] }
    guard let d = try? Data(contentsOf: paths.synthetic), let file = try? JSONDecoder().decode(File.self, from: d) else { return nil }
    var analyses: [String: BeatTrackerResult] = [:]
    for id in trackIds { analyses[id] = loadAnalysis(paths.analysis, id) }
    var rows: [Row] = []
    for s in file.samples {
        let parts = s.id.split(separator: "-").map(String.init)
        guard parts.count >= 7 else { continue }
        let a = parts[0], b = parts[3]
        let exitBar = Int(parts[1]) ?? 0, entryBar = Int(parts[4]) ?? 0, blend = Double(parts[5]) ?? 0
        var f = vectorDictionary(s.estimated)
        let measured = vectorDictionary(s.measured)
        if let ra = analyses[a], let rb = analyses[b], let ga = ra.beatGrid(), let gb = rb.beatGrid(), exitBar < ra.downbeats.count, entryBar < rb.downbeats.count {
            let window = blend == 0 ? 0.15 : blend * ga.barDuration
            for (k, v) in ai.values(outgoing: a, incoming: b, exit: ra.downbeats[exitBar], window: window, entry: rb.downbeats[entryBar], rate: ga.bpm / max(1, gb.bpm)) { f[k] = v }
        }
        let objective: [String: Double] = [
            "energyStep": abs(measured["energyStep"] ?? .nan),
            "vocalOverlap": measured["vocalOverlap"] ?? .nan,
            "phaseError": measured["phaseError"] ?? .nan,
            "doubleBass": measured["lowOverlap"] ?? .nan,
            "levelJump": measured["maxLevelJump"] ?? .nan,
            "tempoError": measured["bpmDelta"] ?? .nan
        ]
        let gates = Gates.fired(AutoMixNetFeatures.vector(s.estimated))
        rows.append(Row(id: s.id, group: pairKey(a, b), pair: "\(a)>\(b)", tracks: [a, b], fault: s.fault, good: s.good, f: f, objective: objective, gates: gates))
    }
    let base = AutoMixNetFeatures.names.filter { $0 != "spectralFlux" && $0 != "keyDistance" }
    return BakeoffDataset(
        name: "synthetic", rows: rows, features: base,
        aiFeatures: ai.available ? ["ai.vocalOverlap", "ai.bassOverlap", "ai.beatConfidence"] : [],
        faultFeatures: [
            "phase": ["phaseError"],
            "tempo": ["bpmDelta"],
            "doubleBass": ["lowOverlap", "lowDuring"],
            "slam": ["blendLength", "maxLevelJump", "peakProximity", "energyStep"],
            "cut": ["blendLength", "move.cut", "move.blend", "maxLevelJump"],
            "vocal": ["vocalOverlap"]
        ],
        objectiveNames: ["energyStep", "vocalOverlap", "phaseError", "doubleBass", "levelJump", "tempoError"]
    )
}

struct EvalLabel: Decodable {
    struct Gate: Decodable { var name: String; var pass: Bool }
    var id: String
    var truth: String
    var source: String
    var fault: String?
    var move: String
    var outgoing: String
    var incoming: String
    var mixPointSeconds: Double
    var entrySeconds: Double
    var gates: [Gate]
    var metrics: [String: JSONScalar]
}

enum JSONScalar: Decodable {
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .null }
    }

    var value: Double {
        switch self {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .null: return .nan
        }
    }
}

struct ReviewerVerdict: Decodable {
    var id: String
    var verdict: String?
    var score: Double?
    var confidence: Double?

    var goodProbability: Double {
        if let score { return (score - 1) / 4 }
        let c = confidence ?? 1
        return verdict == "good" ? 0.5 + 0.5 * c : 0.5 - 0.5 * c
    }
}

let hardGates: Set<String> = ["vocal_overlap", "level_step", "double_bass", "phase", "clicks", "payoff", "entry_energy"]

func labelledDataset(_ paths: Paths, ai: AIFeatures, reviewers: [String: [ReviewerVerdict]]) -> BakeoffDataset? {
    guard let d = try? Data(contentsOf: paths.eval.appendingPathComponent("truth/labels.json")), let labels = try? JSONDecoder().decode([EvalLabel].self, from: d) else { return nil }
    var bars: [String: Double] = [:], bpm: [String: Double] = [:], confidence: [String: Double] = [:]
    for id in trackIds {
        if let r = loadAnalysis(paths.analysis, id), let g = r.beatGrid() { bars[id] = g.barDuration; bpm[id] = g.bpm; confidence[id] = r.beatConfidence }
    }
    var rows: [Row] = []
    for l in labels {
        func m(_ k: String) -> Double { l.metrics[k]?.value ?? .nan }
        let window = m("transitionSeconds")
        let bar = bars[l.outgoing] ?? 2
        let move = AutoMixNetFeatures.moveGroup(l.move)
        var f: [String: Double] = [
            "energyStep": m("energyStepDB"),
            "maxLevelJump": m("maxLevelJumpDB"),
            "vocalOverlap": m("vocalUnderBlendSeconds"),
            "vocalBoth": m("vocalOverlapSeconds"),
            "plannedVocal": m("plannedVocalOverlapSeconds"),
            "phaseErrorMs": abs(m("phaseErrorMs")),
            "phaseCorrelation": m("phaseCorrelation"),
            "doubleBass": m("doubleBassSeconds"),
            "lowOverlap": m("doubleBassSeconds") / max(1, window),
            "payoff": m("payoffOverlapSeconds"),
            "entryRMS": m("incomingEntryRMSDB"),
            "entryBeatLed": m("incomingEntryBeatLed"),
            "exitOnPhrase": m("exitOnPhrase"),
            "entryOnDownbeat": m("entryOnDownbeat"),
            "phaseLock": m("phaseLock"),
            "bpmDelta": AutoMixNetFeatures.residualTempoPercent(outgoingBPM: bpm[l.outgoing] ?? 120, incomingBPM: bpm[l.incoming] ?? 120, rate: m("rate")) ?? .nan,
            "blendLength": log2(1 + max(0, window / bar)),
            "gridConfidence": min(confidence[l.outgoing] ?? .nan, confidence[l.incoming] ?? .nan)
        ]
        for g in ["blend", "cut", "loop", "echo", "filter"] { f["move.\(g)"] = (g == "filter" ? l.move.lowercased().contains("filter") : move == g && !l.move.lowercased().contains("filter")) ? 1 : 0 }
        for (k, v) in ai.values(outgoing: l.outgoing, incoming: l.incoming, exit: l.mixPointSeconds, window: window, entry: l.entrySeconds, rate: m("rate")) { f[k] = v }
        let fired = l.gates.filter { !$0.pass && hardGates.contains($0.name) }.map(\.name)
        let objective: [String: Double] = [
            "energyStep": abs(m("energyStepDB")),
            "vocalOverlap": m("vocalUnderBlendSeconds"),
            "phaseError": abs(m("phaseErrorMs")),
            "doubleBass": m("doubleBassSeconds"),
            "levelJump": m("maxLevelJumpDB")
        ]
        var row = Row(
            id: l.id, group: pairKey(l.outgoing, l.incoming), pair: "\(l.outgoing)>\(l.incoming)", tracks: [l.outgoing, l.incoming],
            fault: l.fault ?? (l.truth == "bad" ? "gate_fail_untouched" : nil), good: l.truth == "good", f: f, objective: objective, gates: fired
        )
        row.borderline = l.truth == "borderline"
        row.plannerPick = l.source == "planner-top"
        for (name, verdicts) in reviewers { if let v = verdicts.first(where: { $0.id == l.id }) { row.reviewers[name] = v.goodProbability } }
        rows.append(row)
    }
    let base = ["energyStep", "maxLevelJump", "vocalOverlap", "vocalBoth", "plannedVocal", "phaseErrorMs", "phaseCorrelation", "doubleBass", "lowOverlap", "payoff", "entryRMS", "entryBeatLed", "exitOnPhrase", "entryOnDownbeat", "phaseLock", "bpmDelta", "blendLength", "gridConfidence", "move.blend", "move.cut", "move.loop", "move.echo", "move.filter"]
    return BakeoffDataset(
        name: "labelled", rows: rows, features: base,
        aiFeatures: ai.available ? ["ai.vocalOverlap", "ai.bassOverlap", "ai.beatConfidence"] : [],
        faultFeatures: [
            "double_bass_no_swap": ["doubleBass", "lowOverlap"],
            "phase_misalignment": ["phaseErrorMs", "phaseCorrelation", "phaseLock"],
            "level_jump": ["energyStep", "maxLevelJump"],
            "energy_cliff": ["energyStep", "maxLevelJump"],
            "mix_across_drop": ["payoff"],
            "blend_over_vocals": ["vocalOverlap", "vocalBoth", "plannedVocal"],
            "hard_cut_mid_phrase": ["exitOnPhrase", "entryOnDownbeat"],
            "enter_silence_or_beatless_intro": ["entryRMS", "entryBeatLed"],
            "gate_fail_untouched": ["vocalOverlap", "vocalBoth", "payoff", "entryRMS", "entryBeatLed", "phaseErrorMs", "phaseCorrelation"]
        ],
        objectiveNames: ["energyStep", "vocalOverlap", "phaseError", "doubleBass", "levelJump"]
    )
}

struct SetReport: Decodable {
    struct Transition: Decodable {
        var blendBars: Double?
        var energyStepDecibels: Double?
        var vocalDuringBlendSeconds: Double?
        var bpmDeltaPercent: Double?
        var keyDistance: Int?
        var maxLevelJumpDecibels: Double?
        var doubleBassBars: Double?
        var cut: Bool?
        var exitSection: String?
        var entrySection: String?
        var confidence: Double?
        var move: String?
    }
    var transitions: [Transition]
    var gridConfidence: Double?
}

func realDJRows(_ paths: Paths) -> [Row] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: paths.setReports, includingPropertiesForKeys: nil) else { return [] }
    var rows: [Row] = []
    for url in files.sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(SetReport.self, from: d) else { continue }
        for (k, t) in r.transitions.enumerated() {
            let blend = t.blendBars ?? 0
            let o = AutoMixNetObservation(
                moveType: (t.cut ?? false) ? "cut" : (t.move ?? "blend"), blendBars: blend,
                energyStep: t.energyStepDecibels, vocalOverlapSeconds: t.vocalDuringBlendSeconds,
                gridConfidence: r.gridConfidence, keyDistance: t.keyDistance, bpmDeltaPercent: t.bpmDeltaPercent,
                exitSection: t.exitSection ?? "unknown", entrySection: t.entrySection ?? "unknown"
            )
            var f = vectorDictionary(o)
            f["maxLevelJump"] = t.energyStepDecibels.map(abs) ?? .nan
            f["lowOverlap"] = blend > 0 ? (t.doubleBassBars ?? 0) / blend : .nan
            f["confidence"] = t.confidence ?? 0
            var vector = AutoMixNetFeatures.vector(o)
            if let i = AutoMixNetFeatures.names.firstIndex(of: "maxLevelJump") { vector[i] = Float(f["maxLevelJump"]!) }
            if let i = AutoMixNetFeatures.names.firstIndex(of: "lowOverlap") { vector[i] = Float(f["lowOverlap"]!) }
            let name = url.deletingPathExtension().lastPathComponent
            rows.append(Row(id: "\(name)#\(k)", group: name, pair: name, tracks: [], fault: nil, good: true, f: f, objective: [:], gates: Gates.fired(vector)))
        }
    }
    return rows
}

func loadReviewers(_ paths: Paths) -> [String: [ReviewerVerdict]] {
    var out: [String: [ReviewerVerdict]] = [:]
    for name in ["opus", "sonnet"] {
        let url = paths.eval.appendingPathComponent("reviewer-\(name).json")
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([ReviewerVerdict].self, from: d) { out[name] = v }
    }
    return out
}

func ownerRatingRows(_ paths: Paths) -> [Row] {
    var rows: [Row] = []
    for url in paths.ratings {
        guard let samples = try? AutoMixNetRatings.load(from: url) else { continue }
        for (k, s) in samples.enumerated() {
            rows.append(Row(id: "rating#\(k)", group: "rating\(k)", pair: "rating", tracks: [], fault: s.good ? nil : "owner_not_great", good: s.good, f: vectorDictionary(s.observation), objective: [:], gates: Gates.fired(AutoMixNetFeatures.vector(s.observation))))
        }
    }
    return rows
}
