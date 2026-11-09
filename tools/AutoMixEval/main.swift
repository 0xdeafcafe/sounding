import AVFoundation
import Foundation

let args = CommandLine.arguments
let sourceDirectory = URL(fileURLWithPath: args[1])
let analysisDirectory = URL(fileURLWithPath: args[2])
let truthDirectory = URL(fileURLWithPath: args[3])
let reviewDirectory = URL(fileURLWithPath: args[4])
let scratchDirectory = URL(fileURLWithPath: args[5])
let mode = args.count > 6 ? args[6] : "render"
let total = args.count > 7 ? Int(args[7]) ?? 100 : 100
for d in [truthDirectory, reviewDirectory, scratchDirectory, analysisDirectory] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func shuffle<T>(_ xs: inout [T]) {
        guard xs.count > 1 else { return }
        for i in stride(from: xs.count - 1, to: 0, by: -1) { xs.swapAt(i, Int(next() % UInt64(i + 1))) }
    }
}

func envelope(_ x: [Float]) -> [Float] {
    let window = Int(sr * 0.05)
    var peaks: [Float] = []
    var i = 0
    while i < x.count {
        var peak: Float = 0
        for j in i..<min(x.count, i + window) { peak = max(peak, abs(x[j])) }
        peaks.append(peak)
        i += window
    }
    let top = max(1e-6, peaks.max() ?? 1)
    let normalised = peaks.map { $0 / top }
    let count = max(8, Int((Double(x.count) / sr).rounded()))
    let m = normalised.count
    return (0..<count).map { k in
        let s = k * m / count
        let e = min(max(s + 1, (k + 1) * m / count), m)
        let slice = normalised[s..<e]
        return (slice.max() ?? 0) * 0.7 + slice.reduce(0, +) / Float(slice.count) * 0.3
    }
}

func loadTrack(_ id: String) async throws -> Track {
    let url = sourceDirectory.appendingPathComponent("\(id).wav")
    let cache = analysisDirectory.appendingPathComponent("analysis-\(id)-bands.json")
    let result: BeatTrackerResult
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(BeatTrackerResult.self, from: data), cached.bars?.bands != nil {
        result = cached
    } else {
        result = try await BeatTracker.analyze(fileURL: url)
        try JSONEncoder().encode(result).write(to: cache)
    }
    let audio = try readAudio(url)
    let duration = Double(audio.left.count) / sr
    var provenance: FeatureProvenance = [.envelopeOnly, .measuredTempo, .measuredKey]
    if result.isPhaseReliable { provenance.insert([.measuredBeatGrid, .measuredDownbeats]) }
    if result.isParityReliable || result.isPhaseReliable { provenance.insert(.measuredBeatParity) }
    if result.vocalCurve != nil { provenance.insert(.measuredVocals) }
    let bars = result.bars.flatMap { $0.level.count == result.downbeats.count ? $0 : nil }
    let env = envelope(audio.left)
    var sections: [TrackSection] = []
    if result.isPhaseReliable, result.phraseStarts.count >= 2 {
        let starts = result.phraseStarts + [duration]
        let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
        sections = DJSessionDirector.classifyStructure(ranges, duration: duration, envelope: env)
        provenance.insert(.measuredStructure)
    }
    let features = TrackFeatures(
        trackId: id, title: id, artist: id, duration: duration, beatGrid: result.beatGrid(),
        keyRegions: [KeyRegion(key: CamelotKey.parse("8A")!, start: 0, end: duration)],
        sections: sections, phraseBoundaries: result.phraseStarts,
        energyLevel: 6, envelope: env, vocalRanges: result.vocalSeconds ?? [],
        provenance: provenance, barProfile: bars, barStarts: bars == nil ? [] : result.downbeats
    )
    let mono = zip(audio.left, audio.right).map { ($0 + $1) / 2 }
    return Track(id: id, url: url, audio: audio, result: result, features: features, mono: mono)
}

let ids = ["darkknight", "jungle", "marionette", "voodoo"]
var tracks: [String: Track] = [:]
for id in ids {
    let t = try await loadTrack(id)
    tracks[id] = t
    print(String(format: "TRACK %@ bpm %.1f bars %d phrases %d vocals %d payoff %d", id, t.result.bpm ?? 0, t.result.downbeats.count, t.result.phraseStarts.count, t.features.vocalRanges.count, DJMoveRails.payoffRuns(t.features).count))
}

var pool = buildPool(tracks, ids: ids)
var tally: [String: Int] = [:]
for c in pool { tally["\(c.intended)/\(c.fault ?? c.source)/\(c.fault == nil ? c.move : "")", default: 0] += 1 }
print("POOL \(pool.count)")
for (k, v) in tally.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
if mode == "pool" { exit(0) }

func manifested(_ c: EvalCase, _ m: Metrics) -> Bool {
    switch c.fault {
    case "mix_across_drop": return m.payoffOverlapSeconds > 4
    case "blend_over_vocals": return m.vocalUnderBlendSeconds >= 6
    case "enter_silence_or_beatless_intro": return m.incomingEntryRMSDB < -30 || m.incomingEntryBeatLed == false
    case "double_bass_no_swap": return m.doubleBassSeconds >= 6
    case "phase_misalignment": return m.phaseErrorMs.map { abs($0) >= 20 } ?? true
    case "energy_cliff": return m.energyStepDB <= -6
    case "level_jump": return abs(m.energyStepDB) >= 6 || m.maxLevelJumpDB >= 6
    default: return true
    }
}

let hardGates: Set<String> = ["vocal_overlap", "level_step", "double_bass", "phase", "clicks", "payoff", "entry_energy"]

func truth(_ c: EvalCase, _ g: [Gate], _ m: Metrics) -> (String, String) {
    let failed = g.filter { !$0.pass }.map(\.name)
    let hard = failed.filter(hardGates.contains)
    switch c.intended {
    case "bad": return manifested(c, m) ? ("bad", "injected fault, measurably present") : ("borderline", "injected fault did not measurably manifest")
    case "good":
        if hard.count >= 2 { return ("bad", "planner or forced move failing \(hard.joined(separator: ", "))") }
        if !hard.isEmpty { return ("borderline", "planner or forced move failing \(hard.joined(separator: ", "))") }
        return ("good", "planner or forced move passing every hard gate")
    default:
        return ("borderline", c.fault.map { "mild injected fault: \($0)" } ?? "planner alternative below the firing score")
    }
}

var rng = SplitMix(state: 0x50D1_2026)
rng.shuffle(&pool)
var goods = pool.filter { $0.intended != "bad" }
var bads = pool.filter { $0.intended == "bad" }
rng.shuffle(&goods)
rng.shuffle(&bads)
var ordered: [EvalCase] = []
while !goods.isEmpty || !bads.isEmpty {
    if !goods.isEmpty { ordered.append(goods.removeFirst()) }
    if !bads.isEmpty { ordered.append(bads.removeFirst()) }
}

let quota = ["good": total * 46 / 100, "bad": total * 42 / 100, "borderline": total - total * 46 / 100 - total * 42 / 100]
let perFaultCap = max(3, total * 6 / 100)
var counts: [String: Int] = [:]
var faultCounts: [String: Int] = [:]
var sourceCounts: [String: Int] = [:]

struct LabelGate: Codable { var name: String; var pass: Bool; var value: Double?; var limit: String }
struct EvalLabel: Codable {
    var id: String
    var truth: String
    var truthReason: String
    var intended: String
    var source: String
    var fault: String?
    var faultDetail: String?
    var move: String
    var outgoing: String
    var incoming: String
    var mixPointSeconds: Double
    var entrySeconds: Double
    var plannerScore: Double?
    var plannerFires: Bool?
    var metrics: Metrics
    var gates: [LabelGate]
    var gatesFailed: [String]
    var gatesFlagged: Bool
    var wav: String?
    var png: String
}
var labels: [EvalLabel] = []
var started = Date()
for c in ordered {
    if labels.count >= total { break }
    if c.intended == "bad", let f = c.fault, faultCounts[f, default: 0] >= perFaultCap { continue }
    if c.intended != "bad", sourceCounts[c.fault ?? c.source + c.move, default: 0] >= perFaultCap + 2 { continue }
    guard let o = tracks[c.outgoing], let i = tracks[c.incoming] else { continue }
    let a: Analysis
    do { a = try analyse(c, out: o, in: i) } catch { print("FAIL \(c.key): \(error)"); continue }
    let g = gates(a.metrics)
    let (t, why) = truth(c, g, a.metrics)
    guard counts[t, default: 0] < quota[t, default: 0] else { print("SKIP full \(t) \(c.key)"); continue }
    counts[t, default: 0] += 1
    if let f = c.fault, c.intended == "bad" { faultCounts[f, default: 0] += 1 } else { sourceCounts[c.fault ?? c.source + c.move, default: 0] += 1 }
    let k = labels.count
    let png = scratchDirectory.appendingPathComponent("tmp-\(k).png")
    plotReview(a, to: png)
    let wav = try writeAudio(a.mixL, a.mixR, base: truthDirectory.appendingPathComponent("tmp-\(k)"))
    let failed = g.filter { !$0.pass }.map(\.name)
    labels.append(EvalLabel(
        id: "tmp-\(k)", truth: t, truthReason: why, intended: c.intended, source: c.source, fault: c.fault, faultDetail: c.faultDetail,
        move: c.move, outgoing: c.outgoing, incoming: c.incoming, mixPointSeconds: c.plan.mixPointSeconds, entrySeconds: c.plan.entrySeconds,
        plannerScore: c.plannerScore, plannerFires: c.plannerFires, metrics: a.metrics,
        gates: g.map { LabelGate(name: $0.name, pass: $0.pass, value: $0.value.flatMap { $0.isFinite ? $0 : nil }, limit: $0.limit) },
        gatesFailed: failed, gatesFlagged: failed.contains(where: hardGates.contains), wav: wav?.path, png: png.path
    ))
    print(String(format: "CASE %3d %@ %@ %@>%@ %@ fault=%@ failed=%@ (%.0f s)", k, t, c.source, c.outgoing, c.incoming, c.move, c.fault ?? "-", failed.joined(separator: ","), Date().timeIntervalSince(started)))
}

var order = Array(labels.indices)
rng.shuffle(&order)
var final: [EvalLabel] = []
for (n, k) in order.enumerated() {
    var l = labels[k]
    let id = String(format: "t%03d", n + 1)
    let png = reviewDirectory.appendingPathComponent("\(id).png")
    try? FileManager.default.removeItem(at: png)
    if let old = l.wav {
        let wav = truthDirectory.appendingPathComponent("\(id).\(URL(fileURLWithPath: old).pathExtension)")
        try? FileManager.default.removeItem(at: wav)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: old), to: wav)
        l.wav = wav.path
    }
    try FileManager.default.moveItem(at: URL(fileURLWithPath: l.png), to: png)
    l.id = id
    l.png = png.path
    final.append(l)
}
final.sort { $0.id < $1.id }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(final).write(to: truthDirectory.appendingPathComponent("labels.json"))
print("DONE \(final.count) cases: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + " | faults " + faultCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
