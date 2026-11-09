import AVFoundation
import Foundation

let args = CommandLine.arguments
let sourceDirectory = URL(fileURLWithPath: args[1])
let aiDirectory = URL(fileURLWithPath: args[2])
let packDirectory = URL(fileURLWithPath: args[3])
let perSetting = args.count > 4 ? Int(args[4]) ?? 3 : 3
try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)

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

let majorPositionByPitchClass = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

func correlation(_ a: [Double], _ b: [Double]) -> Double {
    let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
    var n = 0.0, da = 0.0, db = 0.0
    for k in 0..<12 { n += (a[k] - ma) * (b[k] - mb); da += (a[k] - ma) * (a[k] - ma); db += (b[k] - mb) * (b[k] - mb) }
    return n / max(1e-12, sqrt(da * db))
}

func camelot(_ features: BeatTrackerFeatures) -> String? {
    var chroma = [Double](repeating: 0, count: 12)
    for s in 0..<(features.chroma.count / 12) { for k in 0..<12 { chroma[k] += Double(features.chroma[s * 12 + k]) } }
    guard chroma.reduce(0, +) > 1e-6 else { return nil }
    var best = (score: -Double.infinity, pitch: 0, minor: false)
    for tonic in 0..<12 {
        for minor in [false, true] {
            let profile = minor ? minorProfile : majorProfile
            let r = correlation(chroma, (0..<12).map { profile[($0 - tonic + 12) % 12] })
            if r > best.score { best = (r, tonic, minor) }
        }
    }
    let major = best.minor ? (best.pitch + 3) % 12 : best.pitch
    return "\(majorPositionByPitchClass[major])\(best.minor ? "A" : "B")"
}

func loadTrack(_ id: String) async throws -> (Track, String, String) {
    let url = sourceDirectory.appendingPathComponent("\(id).wav")
    let extracted = try await BeatTracker.extractFeatures(fileURL: url)
    let tracker = BeatTracker.analyze(extracted, tempoPrior: nil)
    var result = tracker
    var gridSource = "BeatTracker"
    if let data = try? Data(contentsOf: aiDirectory.appendingPathComponent("beatthis-\(id).json")),
       let ai = try? JSONDecoder().decode(BeatThisResult.self, from: data) {
        let imposed = BeatTracker.imposing(beats: ai.beats, downbeats: ai.barDownbeats, beatConfidence: ai.confidence, downbeatConfidence: ai.downbeatConfidence, on: extracted, base: tracker)
        let analysis = AIAudioAnalysisResult(version: 1, grid: imposed, gridConfidence: ai.confidence, downbeatConfidence: ai.downbeatConfidence, beatsPerBar: ai.beatsPerBar, stems: nil)
        if let planner = analysis.plannerGrid(phaseFrom: tracker) {
            result = planner
            gridSource = analysis.isGridTrusted ? "AI beats + AI bar phase" : "AI beats + tracker bar phase"
        }
    }
    let key = camelot(extracted) ?? "8A"
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
        keyRegions: [KeyRegion(key: CamelotKey.parse(key)!, start: 0, end: duration)],
        sections: sections, phraseBoundaries: result.phraseStarts,
        energyLevel: 6, envelope: env, vocalRanges: result.vocalSeconds ?? [],
        provenance: provenance, barProfile: bars, barStarts: bars == nil ? [] : result.downbeats
    )
    let mono = zip(audio.left, audio.right).map { ($0 + $1) / 2 }
    return (Track(id: id, url: url, audio: audio, result: result, features: features, mono: mono), key, gridSource)
}

struct Setting {
    let name: String
    let level: Double
    let keyLoosening: Int
}

func apply(_ s: Setting) {
    DJMixRules.maxLevelStepDecibels = s.level
    DJMixRules.keyLoosening = s.keyLoosening
}

struct Pick {
    let setting: String
    let outgoing: String
    let incoming: String
    let plan: Plan
    let changed: String
    let reference: Plan?
    let referenceNote: String
    var severity: Double = 0
}

func describe(_ plan: Plan) -> String {
    let move = plan.move.map { $0.kind.rawValue } ?? plan.templateId?.rawValue ?? "blend"
    return String(format: "%@, out %.1f s, in %.1f s, %.0f s long", move, plan.mixPointSeconds, plan.entrySeconds, plan.transitionSeconds)
}

func same(_ a: Plan?, _ b: Plan?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return abs(a.mixPointSeconds - b.mixPointSeconds) < 0.05 && abs(a.entrySeconds - b.entrySeconds) < 0.05 && a.templateId == b.templateId && a.move?.kind == b.move?.kind
}

let ids = ["darkknight", "jungle", "marionette", "voodoo"]
var tracks: [String: Track] = [:]
var keys: [String: String] = [:]
var notes: [String] = []
for id in ids {
    let (t, key, source) = try await loadTrack(id)
    tracks[id] = t
    keys[id] = key
    let line = String(format: "%@: %.2f bpm, key %@, grid %@, bars %d, phase reliable %@", id, t.result.bpm ?? 0, key, source, t.result.downbeats.count, t.result.isPhaseReliable ? "yes" : "no")
    notes.append(line)
    print(line)
}

let current = Setting(name: "current (6 dB, keys ≤ 1 step)", level: 6, keyLoosening: 0)
let levelBase = Setting(name: "level step 6 dB, key rule off", level: 6, keyLoosening: 12)
let levelSettings = [Setting(name: "level step 8 dB", level: 8, keyLoosening: 12), Setting(name: "level step 10 dB", level: 10, keyLoosening: 12)]
let keySettings = [Setting(name: "keys one step looser", level: 6, keyLoosening: 1), Setting(name: "keys two steps looser", level: 6, keyLoosening: 2)]

func loopPlan(_ o: Track, _ i: Track, _ s: Setting, above minimum: Double = -1) -> (Plan, LoopMixPlanner.Choice, Float?)? {
    apply(s); DJMixRules.minimumLevelStepDecibels = minimum
    defer { apply(current); DJMixRules.minimumLevelStepDecibels = -1 }
    guard let base = plannerTop(o, i, earliestExit: 0),
          let choice = LoopMixPlanner.choose(outgoing: o.features, incoming: i.features),
          let plan = LoopMixPlanner.plan(outgoing: o.features, incoming: i.features, base: base) else { return nil }
    let body = LoopMixPlanner.bodyStep(o.features, before: choice.outgoing.bar, i.features, after: choice.incoming.bar + choice.incoming.bars + choice.fadeOutBars)
    return (plan, choice, body)
}

func topPlan(_ o: Track, _ i: Track, _ s: Setting) -> Plan? {
    apply(s)
    defer { apply(current) }
    return plannerTop(o, i, earliestExit: 0)
}

func keySteps(_ o: Track, _ plan: Plan, _ i: Track) -> Int? {
    DJMoveSupport.keySteps(o.features, at: plan.mixPointSeconds, i.features, at: plan.entrySeconds)
}

var picks: [Pick] = []
var previous = levelBase
for a in ids {
    for b in ids where a != b {
        guard let o = tracks[a], let i = tracks[b] else { continue }
        for s in [levelBase] + levelSettings {
            apply(s)
            var rejections: [String: Int] = [:]
            let choice = LoopMixPlanner.choose(outgoing: o.features, incoming: i.features) { rejections[$0, default: 0] += 1 }
            let line = "loop \(a)>\(b) at \(s.name): " + (choice.map { String(format: "chosen, window step %.1f dB", $0.levelStep) } ?? "none") + " rejections \(rejections.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); \(LoopMixPlanner.diagnose(outgoing: o.features, incoming: i.features))"
            print(line)
        }
        apply(current)
    }
}

for s in levelSettings {
    var found: [Pick] = []
    for a in ids {
        for b in ids where a != b {
            guard let o = tracks[a], let i = tracks[b], let (plan, choice, body) = loopPlan(o, i, s, above: previous.level) else { continue }
            let worst = max(choice.levelStep, body ?? 0)
            guard Double(worst) > previous.level else { continue }
            let before = loopPlan(o, i, previous)
            let reference = before?.0 ?? topPlan(o, i, current)
            let note = before == nil ? "no loop mix passes at \(Int(previous.level)) dB; the current planner plays: \(reference.map(describe) ?? "nothing")" : "at \(Int(previous.level)) dB the loop mix is: \(before.map { describe($0.0) } ?? "")"
            found.append(Pick(
                setting: s.name, outgoing: a, incoming: b, plan: plan,
                changed: String(format: "loop window step %.1f dB, body step (8 bars before vs after) %.1f dB, over the %.0f dB limit", choice.levelStep, body ?? .nan, previous.level),
                reference: reference, referenceNote: note, severity: Double(worst)
            ))
        }
    }
    picks += found.sorted { $0.severity > $1.severity }.prefix(perSetting)
    print("\(s.name): \(found.count) newly allowed")
    notes.append("\(s.name): \(found.count) ordered pairs get a newly allowed loop mix")
    previous = s
}

previous = current
for s in keySettings {
    var found: [Pick] = []
    for a in ids {
        for b in ids where a != b {
            guard let o = tracks[a], let i = tracks[b] else { continue }
            if let loose = topPlan(o, i, s), let was = topPlan(o, i, previous), !same(loose, was),
               let steps = keySteps(o, loose, i), steps > 1 + previous.keyLoosening {
                found.append(Pick(
                    setting: s.name, outgoing: a, incoming: b, plan: loose,
                    changed: "planner's top pick changes; \(keys[a]!) → \(keys[b]!) is \(steps) steps, over a \(String(format: "%.0f", loose.transitionSeconds / max(0.1, o.features.beatGrid?.barDuration ?? 2)))-bar blend",
                    reference: was, referenceNote: "at the stricter setting the planner plays: \(describe(was))"
                ))
            }
            if let (plan, _, _) = loopPlan(o, i, s), let steps = keySteps(o, plan, i), steps > 1 + previous.keyLoosening {
                let before = loopPlan(o, i, previous)
                let reference = before?.0 ?? topPlan(o, i, previous)
                found.append(Pick(
                    setting: s.name, outgoing: a, incoming: b, plan: plan,
                    changed: "loop mix newly allowed; \(keys[a]!) → \(keys[b]!) is \(steps) steps",
                    reference: reference, referenceNote: before == nil ? "no loop mix passes at the stricter setting; the planner plays: \(reference.map(describe) ?? "nothing")" : "at the stricter setting the loop mix is: \(describe(before!.0))"
                ))
            }
        }
    }
    var seen = Set<String>()
    let unique = found.filter { seen.insert("\($0.outgoing)>\($0.incoming)|\(describe($0.plan))").inserted }
    picks += unique.prefix(perSetting)
    print("\(s.name): \(unique.count) newly allowed")
    notes.append("\(s.name): \(unique.count) newly allowed transitions")
    previous = s
}

func render(_ plan: Plan, _ a: String, _ b: String, name: String) throws -> (wav: String, png: String, metrics: Metrics) {
    let c = EvalCase(outgoing: a, incoming: b, plan: plan, source: "pack", intended: "good")
    let analysis = try analyse(c, out: tracks[a]!, in: tracks[b]!)
    let png = packDirectory.appendingPathComponent("\(name).png")
    plotReview(analysis, to: png)
    let wav = packDirectory.appendingPathComponent("\(name).wav")
    try writeWav(analysis.mixL, analysis.mixR, to: wav)
    return (wav.path, png.path, analysis.metrics)
}

var md: [String] = ["# Auto Mix gate listening pack", "", "Rendered through `MixRenderCore` from the real tracks in `\(sourceDirectory.path)`. Shipped thresholds are unchanged: these renders only show what each looser setting would newly let through. Each judged clip has a reference clip for the same pair at the stricter setting. Level-step clips are loop mixes (the level-step gate only applies to `LoopMixPlanner`) with the key rule switched off on both sides, because with these four tracks every loop candidate under 10 dB is otherwise vetoed on key first. Keys are estimated from whole-track chroma (Krumhansl), so treat them as approximate.", "", "Tracks:", ""]
md += notes.prefix(ids.count).map { "- \($0)" }
md += ["", "Newly allowed counts:", ""]
md += notes.dropFirst(ids.count).map { "- \($0)" }
md += [""]
var lastSetting = ""
for (n, p) in picks.enumerated() {
    if p.setting != lastSetting {
        md += ["## \(p.setting)", ""]
        lastSetting = p.setting
    }
    let base = String(format: "%02d-%@-%@-%@", n + 1, p.setting.replacingOccurrences(of: " ", with: "-"), p.outgoing, p.incoming)
    let judged = try render(p.plan, p.outgoing, p.incoming, name: base)
    md += ["### \(n + 1). \(p.outgoing) → \(p.incoming)", ""]
    md += ["- **Judge:** `\(judged.wav)`", "- PNG: `\(judged.png)`", "- Setting: \(p.setting)", "- What changed: \(p.changed)", "- Move: \(describe(p.plan))"]
    md += [String(format: "- Measured on the render: energy step %.1f dB, max level jump %.1f dB, double bass %.1f s, vocals under the blend %.1f s, phase error %@", judged.metrics.energyStepDB, judged.metrics.maxLevelJumpDB, judged.metrics.doubleBassSeconds, judged.metrics.vocalUnderBlendSeconds, judged.metrics.phaseErrorMs.map { String(format: "%.0f ms", $0) } ?? "n/a")]
    if let r = p.reference {
        let ref = try render(r, p.outgoing, p.incoming, name: base + "-reference")
        md += ["- Reference: `\(ref.wav)` (PNG `\(ref.png)`), \(p.referenceNote)"]
    } else {
        md += ["- Reference: none, \(p.referenceNote)"]
    }
    md += [""]
    print("RENDERED \(base)")
}
try md.joined(separator: "\n").write(to: packDirectory.appendingPathComponent("PACK.md"), atomically: true, encoding: .utf8)
print(packDirectory.appendingPathComponent("PACK.md").path)
