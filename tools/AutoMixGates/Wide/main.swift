import AVFoundation
import Foundation

struct CachedTrack: Codable, Sendable {
    var path: String
    var mtime: Double
    var version: Int
    var key: String
    var duration: Double
    var envelope: [Float]
    var result: BeatTrackerResult
}

struct Entry {
    let id: String
    let path: String
    let title: String
}

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

let args = CommandLine.arguments
let mode = args[1]
let tsvPath = args[2]
let cacheDirectory = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

func readEntries() throws -> [Entry] {
    let text = try String(contentsOfFile: tsvPath, encoding: .utf8)
    var entries: [Entry] = []
    for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let path = String(parts[1])
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        entries.append(Entry(id: "c\(n + 1)", path: path, title: title))
    }
    return entries
}

func fnv1a(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

func modificationTime(_ path: String) -> Double {
    let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    return date?.timeIntervalSince1970 ?? 0
}

func cacheURL(_ e: Entry) -> URL { cacheDirectory.appendingPathComponent("\(fnv1a(e.path)).json") }

func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return e
}

func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return d
}

func loadCached(_ e: Entry) -> CachedTrack? {
    guard let data = try? Data(contentsOf: cacheURL(e)), let c = try? makeDecoder().decode(CachedTrack.self, from: data) else { return nil }
    guard c.version == BeatTracker.version, abs(c.mtime - modificationTime(e.path)) < 1 else { return nil }
    return c
}

func decode(_ source: String, to destination: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "WAVE", "-d", "LEI16@44100", source, destination.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "afconvert", code: Int(p.terminationStatus)) }
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

func analyseOne(_ e: Entry, scratch: URL) async -> Bool {
    if loadCached(e) != nil { return true }
    let wav = scratch.appendingPathComponent("\(e.id).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    do {
        try decode(e.path, to: wav)
        let extracted = try await BeatTracker.extractFeatures(fileURL: wav)
        let result = BeatTracker.analyze(extracted, tempoPrior: nil)
        let key = camelot(extracted) ?? "8A"
        let audio = try readAudio(wav)
        let record = CachedTrack(
            path: e.path, mtime: modificationTime(e.path), version: BeatTracker.version, key: key,
            duration: Double(audio.left.count) / sr, envelope: envelope(audio.left), result: result
        )
        try makeEncoder().encode(record).write(to: cacheURL(e), options: .atomic)
        return true
    } catch {
        print("FAILED \(e.id) \(e.title): \(error)")
        return false
    }
}

func makeTrack(_ e: Entry, _ c: CachedTrack, audio: (left: [Float], right: [Float])? = nil) -> Track {
    let result = c.result
    var provenance: FeatureProvenance = [.envelopeOnly, .measuredTempo, .measuredKey]
    if result.isPhaseReliable { provenance.insert([.measuredBeatGrid, .measuredDownbeats]) }
    if result.isParityReliable || result.isPhaseReliable { provenance.insert(.measuredBeatParity) }
    if result.vocalCurve != nil { provenance.insert(.measuredVocals) }
    let bars = result.bars.flatMap { $0.level.count == result.downbeats.count ? $0 : nil }
    var sections: [TrackSection] = []
    if result.isPhaseReliable, result.phraseStarts.count >= 2 {
        let starts = result.phraseStarts + [c.duration]
        let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
        sections = DJSessionDirector.classifyStructure(ranges, duration: c.duration, envelope: c.envelope)
        provenance.insert(.measuredStructure)
    }
    let features = TrackFeatures(
        trackId: e.id, title: e.title, artist: e.title, duration: c.duration, beatGrid: result.beatGrid(),
        keyRegions: [KeyRegion(key: CamelotKey.parse(c.key)!, start: 0, end: c.duration)],
        sections: sections, phraseBoundaries: result.phraseStarts,
        energyLevel: 6, envelope: c.envelope, vocalRanges: result.vocalSeconds ?? [],
        provenance: provenance, barProfile: bars, barStarts: bars == nil ? [] : result.downbeats
    )
    let a = audio ?? ([], [])
    return Track(id: e.id, url: URL(fileURLWithPath: e.path), audio: a, result: result, features: features, mono: zip(a.left, a.right).map { ($0 + $1) / 2 })
}

let entries = try readEntries()

if mode == "analyse" {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wide-analyse-\(getpid())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let width = Int(ProcessInfo.processInfo.environment["WIDE_JOBS"] ?? "") ?? 4
    var ok = 0, done = 0
    await withTaskGroup(of: Bool.self) { group in
        var next = 0
        func launch() {
            guard next < entries.count else { return }
            let e = entries[next]
            next += 1
            group.addTask { await analyseOne(e, scratch: scratch) }
        }
        for _ in 0..<width { launch() }
        for await success in group {
            done += 1
            if success { ok += 1 }
            if done % 10 == 0 { print("analysed \(done)/\(entries.count)") }
            launch()
        }
    }
    print("analysed \(ok) of \(entries.count)")
    exit(0)
}

let outDirectory = URL(fileURLWithPath: args[4])
let pairCount = args.count > 5 ? Int(args[5]) ?? 400 : 400
let seed = args.count > 6 ? UInt64(args[6]) ?? 2026 : 2026
let perSetting = args.count > 7 ? Int(args[7]) ?? 5 : 5
try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

var corpus: [String: (Entry, CachedTrack)] = [:]
var usable: [Entry] = []
for e in entries {
    guard let c = loadCached(e), c.result.bpm != nil, c.duration > 90 else { continue }
    corpus[e.id] = (e, c)
    usable.append(e)
}
print("usable tracks \(usable.count) of \(entries.count)")

var tracks: [String: Track] = [:]
for e in usable { tracks[e.id] = makeTrack(e, corpus[e.id]!.1) }

struct Setting {
    let name: String
    let short: String
    let level: Double
    let keyLoosening: Int
}

let current = Setting(name: "current", short: "shipped", level: 6, keyLoosening: 0)
let levelBase = Setting(name: "level step 6 dB, key rule off", short: "L6", level: 6, keyLoosening: 12)
let l8 = Setting(name: "level step 8 dB (key rule off)", short: "L8", level: 8, keyLoosening: 12)
let l10 = Setting(name: "level step 10 dB (key rule off)", short: "L10", level: 10, keyLoosening: 12)
let l8keys = Setting(name: "level step 8 dB, key rule on", short: "L8k", level: 8, keyLoosening: 0)
let l10keys = Setting(name: "level step 10 dB, key rule on", short: "L10k", level: 10, keyLoosening: 0)
let k1 = Setting(name: "keys one step looser", short: "K1", level: 6, keyLoosening: 1)
let k2 = Setting(name: "keys two steps looser", short: "K2", level: 6, keyLoosening: 2)
let settings = [l8, l10, k1, k2]
let previousOf: [String: Setting] = [l8.short: levelBase, l10.short: l8, k1.short: current, k2.short: k1]
let baseOf: [String: Setting] = [l8.short: levelBase, l10.short: levelBase, k1.short: current, k2.short: current]

func apply(_ s: Setting) {
    DJMixRules.maxLevelStepDecibels = s.level
    DJMixRules.keyLoosening = s.keyLoosening
}

func topPlan(_ o: Track, _ i: Track, _ s: Setting) -> Plan? {
    apply(s)
    defer { apply(current) }
    return plannerTop(o, i, earliestExit: 0)
}

func kind(_ plan: Plan?) -> String {
    guard let plan else { return "no plan" }
    return plan.move.map { $0.kind.rawValue } ?? plan.templateId?.rawValue ?? "blend"
}

func describe(_ plan: Plan) -> String {
    String(format: "%@, out %.1f s, in %.1f s, %.0f s long", kind(plan), plan.mixPointSeconds, plan.entrySeconds, plan.transitionSeconds)
}

func same(_ a: Plan?, _ b: Plan?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return abs(a.mixPointSeconds - b.mixPointSeconds) < 0.05 && abs(a.entrySeconds - b.entrySeconds) < 0.05 && a.templateId == b.templateId && a.move?.kind == b.move?.kind
}

func keySteps(_ o: Track, _ plan: Plan, _ i: Track) -> Int? {
    DJMoveSupport.keySteps(o.features, at: plan.mixPointSeconds, i.features, at: plan.entrySeconds)
}

func bpm(_ id: String) -> Double { corpus[id]?.1.result.bpm ?? 0 }

func tempoCompatible(_ a: String, _ b: String) -> Bool {
    let x = bpm(a), y = bpm(b)
    guard x > 0, y > 0 else { return false }
    return abs(x / y - 1) <= 0.08
}

struct PairResult {
    let outgoing: String
    let incoming: String
    var plans: [String: Plan?]
    var changedVsShipped: [String: Bool] = [:]
    var changedVsPrevious: [String: Bool] = [:]
}

var rng = SplitMix(state: seed)
var drawn = Set<String>()
var pairs: [(String, String)] = []
while pairs.count < pairCount {
    let a = usable[rng.below(usable.count)].id
    let b = usable[rng.below(usable.count)].id
    guard a != b, drawn.insert("\(a)>\(b)").inserted else { continue }
    pairs.append((a, b))
}

var results: [PairResult] = []
for (n, (a, b)) in pairs.enumerated() {
    guard let o = tracks[a], let i = tracks[b] else { continue }
    var r = PairResult(outgoing: a, incoming: b, plans: [:])
    r.plans[current.short] = topPlan(o, i, current)
    r.plans[levelBase.short] = topPlan(o, i, levelBase)
    for s in [l8keys, l10keys] { r.plans[s.short] = topPlan(o, i, s) }
    for s in settings { r.plans[s.short] = topPlan(o, i, s) }
    for s in settings {
        r.changedVsShipped[s.short] = !same(r.plans[s.short]!, r.plans[baseOf[s.short]!.short]!)
        r.changedVsPrevious[s.short] = !same(r.plans[s.short]!, r.plans[previousOf[s.short]!.short]!)
    }
    results.append(r)
    if (n + 1) % 100 == 0 { print("scanned \(n + 1)/\(pairs.count)") }
}

func percent(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%%", Double(n) * 100 / Double(d)) }

var stats: [String] = []
let compatible = results.filter { tempoCompatible($0.outgoing, $0.incoming) }
let noPlan = results.filter { $0.plans[current.short]! == nil }.count
stats += ["Drawn: \(results.count) ordered pairs from \(usable.count) tracks, seed \(seed). \(compatible.count) pairs are tempo-compatible (within 8%). \(noPlan) pairs have no plan at the shipped settings.", ""]
stats += ["| Setting | Changes the plan (all pairs) | Changes the plan (tempo-compatible) | Beyond the previous step |", "| --- | --- | --- | --- |"]
for s in settings {
    let all = results.filter { $0.changedVsShipped[s.short]! }.count
    let comp = compatible.filter { $0.changedVsShipped[s.short]! }.count
    let marginal = results.filter { $0.changedVsPrevious[s.short]! }.count
    stats += ["| \(s.name) | \(all) of \(results.count) (\(percent(all, results.count))) | \(comp) of \(compatible.count) (\(percent(comp, compatible.count))) | \(marginal) (vs \(previousOf[s.short]!.short)) |"]
}
for s in [l8keys, l10keys] {
    let n = results.filter { !same($0.plans[s.short]!, $0.plans[current.short]!) }.count
    stats += ["", "Keeping the key rule on, \(s.name) changes \(n) of \(results.count) plans (\(percent(n, results.count)))."]
}
stats += ["", "Level rows compare against 6 dB with the key rule off on both sides, because with the key rule on the level gate is rarely the deciding veto.", ""]
for s in settings {
    var transitions: [String: Int] = [:]
    var targets: [String: Int] = [:]
    for r in results where r.changedVsShipped[s.short]! {
        let from = kind(r.plans[baseOf[s.short]!.short]!), to = kind(r.plans[s.short]!)
        let label = from == to ? "\(from), retimed" : "\(from) to \(to)"
        transitions[label, default: 0] += 1
        targets[to, default: 0] += 1
    }
    let total = transitions.values.reduce(0, +)
    stats += ["### \(s.name): \(total) changed", ""]
    if total == 0 {
        stats += ["Nothing changes.", ""]
        continue
    }
    stats += ["What it changes to:", ""]
    stats += targets.sorted { $0.value > $1.value }.map { "- \($0.key): \($0.value)" }
    stats += ["", "Changes, strict to loose:", ""]
    stats += transitions.sorted { $0.value > $1.value }.map { "- \($0.key): \($0.value)" }
    stats += [""]
}
try stats.joined(separator: "\n").write(to: outDirectory.appendingPathComponent("stats.md"), atomically: true, encoding: .utf8)
print(stats.joined(separator: "\n"))

if mode == "scan" { exit(0) }

struct Pick {
    let setting: Setting
    let outgoing: String
    let incoming: String
    let plan: Plan
    let reference: Plan
    let referenceSetting: Setting
}

var picks: [Pick] = []
var usedTracks = Set<String>()
for s in settings {
    let prev = s.short == l10.short ? baseOf[s.short]! : previousOf[s.short]!
    var candidates = results.filter { r in
        (s.short == l10.short ? r.changedVsShipped[s.short]! : r.changedVsPrevious[s.short]!) && r.plans[s.short]! != nil && r.plans[prev.short]! != nil
    }
    var shuffle = SplitMix(state: seed &+ UInt64(s.keyLoosening * 100) &+ UInt64(s.level))
    for k in stride(from: candidates.count - 1, to: 0, by: -1) { candidates.swapAt(k, shuffle.below(k + 1)) }
    var chosenKinds = Set<String>()
    var chosenBuckets = Set<Int>()
    var chosen: [Pick] = []
    while chosen.count < perSetting, !candidates.isEmpty {
        func score(_ r: PairResult) -> Int {
            var v = 0
            let to = kind(r.plans[s.short]!)
            if !chosenKinds.contains(to) { v += 3 }
            if !chosenBuckets.contains(Int(bpm(r.outgoing) / 12)) { v += 2 }
            if tempoCompatible(r.outgoing, r.incoming) { v += 2 }
            if usedTracks.contains(r.outgoing) || usedTracks.contains(r.incoming) { v -= 10 }
            return v
        }
        let best = candidates.indices.max { score(candidates[$0]) < score(candidates[$1]) }!
        let r = candidates.remove(at: best)
        chosenKinds.insert(kind(r.plans[s.short]!))
        chosenBuckets.insert(Int(bpm(r.outgoing) / 12))
        usedTracks.insert(r.outgoing)
        usedTracks.insert(r.incoming)
        chosen.append(Pick(setting: s, outgoing: r.outgoing, incoming: r.incoming, plan: r.plans[s.short]!!, reference: r.plans[prev.short]!!, referenceSetting: prev))
    }
    picks += chosen
    print("\(s.name): picked \(chosen.count)")
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wide-render-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let renderIds = Array(Set(picks.flatMap { [$0.outgoing, $0.incoming] })).sorted()
var renderTracks: [String: Track] = [:]
for id in renderIds {
    let (e, c) = corpus[id]!
    let wav = scratch.appendingPathComponent("\(id).wav")
    try decode(e.path, to: wav)
    renderTracks[id] = makeTrack(e, c, audio: try readAudio(wav))
    try? FileManager.default.removeItem(at: wav)
}

func slug(_ s: String) -> String {
    let ascii = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
    var out = String(ascii).lowercased()
    while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
    return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(18))
}

func render(_ plan: Plan, _ a: String, _ b: String, name: String) throws -> (wav: String, png: String, metrics: Metrics) {
    let c = EvalCase(outgoing: a, incoming: b, plan: plan, source: "pack", intended: "good")
    let analysis = try analyse(c, out: renderTracks[a]!, in: renderTracks[b]!)
    let png = outDirectory.appendingPathComponent("\(name).png")
    plotReview(analysis, to: png)
    let wav = outDirectory.appendingPathComponent("\(name).wav")
    try writeWav(analysis.mixL, analysis.mixR, to: wav)
    return (wav.path, png.path, analysis.metrics)
}

func metricsLine(_ m: Metrics) -> String {
    String(format: "energy step %.1f dB, max level jump %.1f dB, double bass %.1f s, vocals under the blend %.1f s, phase error %@", m.energyStepDB, m.maxLevelJumpDB, m.doubleBassSeconds, m.vocalUnderBlendSeconds, m.phaseErrorMs.map { String(format: "%.0f ms", $0) } ?? "n/a")
}

func trackLine(_ id: String) -> String {
    let (e, c) = corpus[id]!
    return String(format: "%@ (%.1f bpm, key %@, %.0f s)", e.title, c.result.bpm ?? 0, c.key, c.duration)
}

var md: [String] = ["# Auto Mix gate listening pack, wide corpus", "", "Rendered through `MixRenderCore` from \(usable.count) real tracks. Shipped thresholds are unchanged: these renders show what each looser setting changes in the plan. Each setting is compared with the next stricter one (level 10 dB against 8 dB, keys two steps against one step; the others against the shipped settings). Keys are estimated from whole-track chroma, so treat them as approximate.", "", "## Statistics", ""] + stats + [""]
var lastSetting = ""
for (n, p) in picks.enumerated() {
    if p.setting.short != lastSetting {
        md += ["## \(p.setting.name)", ""]
        lastSetting = p.setting.short
    }
    let base = String(format: "%02d-%@-%@-%@", n + 1, p.setting.short, slug(corpus[p.outgoing]!.0.title), slug(corpus[p.incoming]!.0.title))
    let ref = try render(p.reference, p.outgoing, p.incoming, name: base + "-a-strict")
    let judged = try render(p.plan, p.outgoing, p.incoming, name: base + "-b-loose")
    let steps = keySteps(renderTracks[p.outgoing]!, p.plan, renderTracks[p.incoming]!).map { "\($0) key steps" } ?? "key steps unknown"
    md += ["### \(n + 1). \(p.setting.name)", "", "- Out: \(trackLine(p.outgoing))", "- In: \(trackLine(p.incoming))"]
    md += ["- Strict (\(p.referenceSetting.short == "shipped" ? "shipped settings" : p.referenceSetting.name)): `\(ref.wav)`", "  - \(describe(p.reference)); \(metricsLine(ref.metrics))", "  - PNG `\(ref.png)`"]
    md += ["- Loose (\(p.setting.name)): `\(judged.wav)`", "  - \(describe(p.plan)), \(steps); \(metricsLine(judged.metrics))", "  - PNG `\(judged.png)`", ""]
    print("RENDERED \(base)")
}
try md.joined(separator: "\n").write(to: outDirectory.appendingPathComponent("PACK.md"), atomically: true, encoding: .utf8)
print(outDirectory.appendingPathComponent("PACK.md").path)
