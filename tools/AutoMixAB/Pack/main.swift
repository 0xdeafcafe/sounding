import AVFoundation
import Foundation

let packArgs = CommandLine.arguments
guard packArgs.count >= 5 else {
    print("usage: automix-ab-pack <corpus tracks.tsv> <pack dir> <cache dir> <engine commit> [pairs 12] [longs 4] [seed 2026]")
    exit(1)
}
let corpusURL = URL(fileURLWithPath: packArgs[1])
let packURL = URL(fileURLWithPath: packArgs[2])
let cacheURL = URL(fileURLWithPath: packArgs[3])
let commit = packArgs[4]
let wantedPairs = packArgs.count > 5 ? Int(packArgs[5]) ?? 12 : 12
let wantedLongs = packArgs.count > 6 ? Int(packArgs[6]) ?? 4 : 4
let seed = packArgs.count > 7 ? UInt64(packArgs[7]) ?? 2026 : 2026
let sourcesURL = packURL.appendingPathComponent("sources")
let rendersURL = packURL.appendingPathComponent("renders")
let analysisURL = cacheURL.appendingPathComponent("beattracker-v\(BeatTracker.version)")
for d in [sourcesURL, rendersURL, analysisURL] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

struct SourceEntry { var id: String; var url: URL; var original: String; var title: String; var artist: String; var cacheKey: String }

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

func titleAndArtist(_ url: URL) async -> (String, String) {
    let asset = AVURLAsset(url: url)
    var title: String?, artist: String?
    if let items = try? await asset.load(.commonMetadata) {
        for item in items {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
        }
    }
    let name = url.deletingPathExtension().lastPathComponent
    let parts = name.components(separatedBy: " - ")
    if artist == nil || artist?.isEmpty == true { artist = parts.count > 1 ? parts[0] : "Unknown" }
    if title == nil || title?.isEmpty == true { title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : name }
    return (title!, artist!)
}

func convert(_ source: URL, to wav: URL) -> Bool {
    if FileManager.default.fileExists(atPath: wav.path) { return true }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2", source.path, wav.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

var corpus: [(Double, String)] = try String(contentsOf: corpusURL, encoding: .utf8).split(separator: "\n").compactMap { line in
    let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard f.count == 2, let s = Double(f[0]), (150...600).contains(s) else { return nil }
    return (s, f[1])
}
corpus.sort { $0.1 < $1.1 }
var shuffler = ABRandom(state: seed)
shuffler.shuffle(&corpus)
print("CORPUS \(corpus.count) tracks of 2.5-10 min, seed \(seed)")

func prepare(_ path: String, index: Int) async -> SourceEntry? {
    let original = URL(fileURLWithPath: path)
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
    let key = "\(fnv(path))-\(mtime)"
    let wav = sourcesURL.appendingPathComponent("\(key).wav")
    guard convert(original, to: wav) else { print("SKIP unreadable \(path)"); return nil }
    let (title, artist) = await titleAndArtist(original)
    return SourceEntry(id: String(format: "c%03d", index), url: wav, original: path, title: title, artist: artist, cacheKey: key)
}

func barEnvelope(_ x: [Float]) -> [Float] {
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

func loadPackTrack(_ e: SourceEntry) async throws -> Track {
    let cache = analysisURL.appendingPathComponent("\(e.cacheKey).json")
    let result: BeatTrackerResult
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(BeatTrackerResult.self, from: data), cached.bars?.bands != nil {
        result = cached
    } else {
        result = try await BeatTracker.analyze(fileURL: e.url)
        try JSONEncoder().encode(result).write(to: cache)
    }
    let audio = try readAudio(e.url)
    let duration = Double(audio.left.count) / sr
    var provenance: FeatureProvenance = [.envelopeOnly, .measuredTempo, .measuredKey]
    if result.isPhaseReliable { provenance.insert([.measuredBeatGrid, .measuredDownbeats]) }
    if result.isParityReliable || result.isPhaseReliable { provenance.insert(.measuredBeatParity) }
    if result.vocalCurve != nil { provenance.insert(.measuredVocals) }
    let bars = result.bars.flatMap { $0.level.count == result.downbeats.count ? $0 : nil }
    let env = barEnvelope(audio.left)
    var sections: [TrackSection] = []
    if result.isPhaseReliable, result.phraseStarts.count >= 2 {
        let starts = result.phraseStarts + [duration]
        let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
        sections = DJSessionDirector.classifyStructure(ranges, duration: duration, envelope: env)
        provenance.insert(.measuredStructure)
    }
    let features = TrackFeatures(
        trackId: e.id, title: e.title, artist: e.artist, duration: duration, beatGrid: result.beatGrid(),
        keyRegions: [KeyRegion(key: CamelotKey.parse("8A")!, start: 0, end: duration)],
        sections: sections, phraseBoundaries: result.phraseStarts,
        energyLevel: 6, envelope: env, vocalRanges: result.vocalSeconds ?? [],
        provenance: provenance, barProfile: bars, barStarts: bars == nil ? [] : result.downbeats
    )
    let mono = zip(audio.left, audio.right).map { ($0 + $1) / 2 }
    return Track(id: e.id, url: e.url, audio: audio, result: result, features: features, mono: mono)
}

// MARK: - Baseline

func foldedRatio(_ o: Track, _ i: Track) -> Double {
    guard let a = o.result.bpm, let b = i.result.bpm, a > 0, b > 0 else { return 1 }
    return [a / b, a / (b * 2), a * 2 / b].min { abs($0 - 1) < abs($1 - 1) } ?? 1
}

func nearestPhrase(_ t: Track, to seconds: Double, after floor: Double) -> Double {
    let phrases = t.result.phraseStarts.filter { $0 >= floor }
    if let p = phrases.min(by: { abs($0 - seconds) < abs($1 - seconds) }) { return p }
    let downbeats = t.result.downbeats.filter { $0 >= floor }
    return downbeats.min { abs($0 - seconds) < abs($1 - seconds) } ?? max(floor, seconds)
}

func baselinePlan(_ o: Track, _ i: Track, like main: Plan, floor: Double) -> Plan {
    let bar = o.features.beatGrid?.barDuration ?? 2
    let window = 16 * bar
    let centre = main.mixPointSeconds + main.transitionSeconds / 2
    var mix = nearestPhrase(o, to: centre - window / 2, after: max(floor, 22))
    if mix + window > o.features.duration - 2 { mix = nearestPhrase(o, to: o.features.duration - window - 8 * bar, after: max(floor, 22)) }
    let entry = nearestPhrase(i, to: i.features.contentStart, after: max(0, i.features.contentStart - 0.05))
    return blend(o, i, mix: mix, entry: entry, bars: 16, rate: foldedRatio(o, i), swapAt: 0.5)
}

// MARK: - Render

struct Leg { var incoming: Track; var plan: Plan; var baseline: Bool }

struct ChainResult {
    var left: [Float]
    var right: [Float]
    var regions: [ABRegion]
    var executions: [MixExecutionRecord]
}

let appliesLevel = ProcessInfo.processInfo.environment["AUTOMIX_AB_LEVEL"] == "1"
let mainVariant = ProcessInfo.processInfo.environment["AUTOMIX_AB_VARIANT"] ?? "main"
let rendersBaseline = ProcessInfo.processInfo.environment["AUTOMIX_AB_SKIP_BASELINE"] != "1"

func normalisationGain(_ t: Track, _ source: MixSource) -> Double {
    let downbeats = t.result.downbeats.sorted()
    guard downbeats.count > 8 else { return 1 }
    let bars = LocalLoudness.measure(source: source, barStarts: downbeats, bars: 0..<downbeats.count)
    let powers = bars.bars.values.map(\.power).filter { $0 > 1e-7 }
    let gate = powers.reduce(0, +) / Double(max(1, powers.count)) * 0.1
    let gated = powers.filter { $0 >= gate }
    let integrated = Float(LocalLoudness.lufs(gated.reduce(0, +) / Double(max(1, gated.count))))
    #if LEVEL_BEFORE
    return LoudnessNormalization.attenuation(measuredLUFS: integrated)
    #else
    let peak = Float(20 * log10(max(1e-9, bars.bars.values.map(\.peak).max() ?? 1)))
    return LoudnessNormalization.gain(measuredLUFS: integrated, peakDecibels: peak)
    #endif
}

func levelBody(_ t: Track, _ source: MixSource, around seconds: Double, before: Int, after: Int) -> LocalLoudness.Body? {
    let downbeats = t.result.downbeats.sorted()
    guard downbeats.count >= 4 else { return nil }
    let index = downbeats.lastIndex { $0 <= seconds + 0.01 } ?? 0
    let range = max(0, index - before)..<min(downbeats.count, index + after)
    return LocalLoudness.measure(source: source, barStarts: downbeats, bars: range).body(bars: range)
}

func renderChain(first: Track, legs: [Leg], lead: Double, tail: Double) throws -> ChainResult {
    let core = MixRenderCore(sampleRate: sr)
    var sources = [try MixSource(url: first.url, synchronous: true)]
    var gains = [1.0, 1.0]
    var previous = first
    var tables: [MixBeatTable] = []
    var seq: Int64 = 0
    func push(_ make: (Int64) -> MixCommand) {
        seq += 1
        _ = core.ring.push(make(seq))
    }
    func now(_ action: MixTimelineAction) { push { .event(seq: $0, time: 0, immediate: true, group: 0, action: action) } }
    func loadBeats(_ deck: Int, _ grid: BeatGrid?) {
        if let grid, let table = MixBeatTable(grid: grid, sampleRate: sr) {
            tables.append(table)
            push { .beats(seq: $0, deck: deck, table: Unmanaged.passUnretained(table)) }
        }
    }
    push { [s = sources[0]] in .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(s)) }
    loadBeats(0, legs.first?.plan.outgoingBeatGrid ?? first.features.beatGrid)
    now(.ramp(.crossfade, to: 0, frames: 0, curve: .linear))
    if appliesLevel {
        gains[0] = normalisationGain(first, sources[0])
        now(.ramp(.gain(0), to: gains[0], frames: 0, curve: .linear))
    }
    now(.start(deck: 0, fromFrame: max(0, (legs.first?.plan.mixPointSeconds ?? 0) - lead) * sr))
    var rates = [1.0, 1.0]
    var regions: [ABRegion] = []
    var executions: [MixExecutionRecord] = []
    var output: ([Float], [Float]) = ([], [])
    let block = 512
    let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { l.deallocate(); r.deallocate() }
    func render(seconds: Double) {
        var remaining = Int(seconds * sr)
        while remaining > 0 {
            let n = min(block, remaining)
            core.render(frames: n, left: l, right: r)
            output.0.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
            output.1.append(contentsOf: UnsafeBufferPointer(start: r, count: n))
            remaining -= n
        }
    }
    for (k, leg) in legs.enumerated() {
        let out = k % 2, inc = (k + 1) % 2
        let plan = leg.plan
        let source = try MixSource(url: leg.incoming.url, synchronous: true)
        sources.append(source)
        push { .load(seq: $0, deck: inc, source: Unmanaged.passUnretained(source)) }
        loadBeats(inc, plan.incomingBeatGrid)
        now(.ramp(.eqLow(inc), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
        now(.ramp(.eqMid(inc), to: 0, frames: 0, curve: .linear))
        now(.ramp(.eqHigh(inc), to: 0, frames: 0, curve: .linear))
        now(.ramp(.lowPass(inc), to: plan.accent == .incomingFilterOpen ? DJEngineConstants.accentClosedFilterHz : MixEngine.filterOpenHertz, frames: 0, curve: .linear))
        rates[inc] = plan.incomingRateRatio * rates[out]
        now(.ramp(.rate(inc), to: rates[inc], frames: 0, curve: .linear))
        let phaseLock = (plan.outgoingBeatGrid?.isPhaseVerified ?? false) && (plan.incomingBeatGrid?.isPhaseVerified ?? false) && plan.templateId != DJTemplates.cutOnTheOne
        var input = MixTransitionTimelineInput(
            outgoing: out, incoming: inc, sampleRate: sr, anchorSourceSeconds: plan.mixPointSeconds,
            window: max(0.15, plan.transitionSeconds), entrySeconds: plan.entrySeconds,
            outgoingRate: rates[out], incomingRate: rates[inc],
            outgoingGrid: plan.outgoingBeatGrid, incomingGrid: plan.incomingBeatGrid,
            stages: plan.stages, bassSwapAtSeconds: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds,
            filterAccent: plan.accent, defersIncomingStart: false, phaseLock: phaseLock, move: plan.move,
            riserGain: 0, incomingMidCutDecibels: plan.incomingMidCutDecibels
        )
        if appliesLevel {
            gains[inc] = normalisationGain(leg.incoming, source)
            now(.ramp(.gain(inc), to: gains[inc], frames: 0, curve: .linear))
            #if !LEVEL_BEFORE
            let level = TransitionLevel.plan(
                outgoing: levelBody(previous, sources[sources.count - 2], around: plan.mixPointSeconds, before: 8, after: 8),
                incoming: levelBody(leg.incoming, source, around: plan.entrySeconds, before: 0, after: 16),
                outgoingGain: gains[out],
                incomingGain: gains[inc]
            )
            input.level = level
            if let g = level.incomingGain { gains[inc] = g }
            #endif
        }
        previous = leg.incoming
        _ = input
        let timeline = MixTimeline.transition(input)
        let group = Int32(7 + k)
        for event in timeline.events {
            if leg.baseline, case .ramp(let p, _, _, _) = event.action, p == .crossfadeCurve { continue }
            push { .event(seq: $0, time: event.offset, immediate: false, group: group, action: event.action) }
        }
        push { .anchor(seq: $0, group: group, anchor: timeline.anchor) }
        let length = Double(timeline.lengthFrames) / sr
        var guardSeconds = 0.0
        while core.snapshot().anchorClock(for: group) == nil, guardSeconds < 900 {
            render(seconds: 0.5)
            guardSeconds += 0.5
        }
        guard let clock = core.snapshot().anchorClock(for: group) else { throw ABError("leg \(k) never anchored") }
        let start = Double(clock) / sr
        regions.append(ABRegion(start: start, end: start + length))
        executions.append(MixExecutionRecord(startSourceSeconds: plan.mixPointSeconds, windowSeconds: length, entrySeconds: plan.entrySeconds, outgoingRate: rates[out], incomingRate: rates[inc], startedAtPlannedBoundary: true, riserLevel: 0, sampleRate: sr))
        let doneAt = start + length + 0.5
        let have = Double(output.0.count) / sr
        if doneAt > have { render(seconds: doneAt - have) }
    }
    if let last = regions.last {
        let have = Double(output.0.count) / sr
        render(seconds: max(0, last.end + tail - have))
    }
    withExtendedLifetime((sources, tables)) {}
    return ChainResult(left: output.0, right: output.1, regions: regions, executions: executions)
}

func deckPosition(after leg: Plan, in incoming: Track, regionLength: Double, rate: Double) -> Double {
    leg.entrySeconds + regionLength * rate
}

func record(_ plan: Plan) -> MixPlanRecord {
    MixPlanRecord(
        mixPointSeconds: plan.mixPointSeconds, transitionSeconds: plan.transitionSeconds, outroShape: "\(plan.outroShape)",
        accent: plan.accent, reasoning: plan.reasoning, entrySeconds: plan.entrySeconds,
        bassSwapAtSeconds: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds,
        incomingRateRatio: plan.incomingRateRatio, incomingTrackId: plan.incomingTrackId, profileId: plan.profileId,
        templateId: plan.templateId, stages: plan.stages, outgoingBeatGrid: plan.outgoingBeatGrid, incomingBeatGrid: plan.incomingBeatGrid,
        move: plan.move, incomingTitle: plan.incomingTitle, incomingMidCutDecibels: plan.incomingMidCutDecibels
    )
}

func moveName(_ plan: Plan) -> String { plan.move?.kind.rawValue ?? plan.templateId?.rawValue ?? "blend" }

// MARK: - Pack

func tempoKey(_ t: Track) -> Double {
    var b = t.result.bpm ?? 120
    while b < 90 { b *= 2 }
    while b >= 180 { b /= 2 }
    return b
}

var meta: [String: SourceEntry] = [:]
var pool: [Track] = []
var pairs: [(Track, Track)] = []
var bins: [Int: Int] = [:]
let binCap = max(2, (wantedPairs + 3) / 4)
var cursor = 0
let analysisLimit = max(60, wantedPairs * 8)

func artist(_ t: Track) -> String { meta[t.id]?.artist.lowercased() ?? t.id }
func compatible(_ a: Track, _ b: Track) -> Bool { abs(tempoKey(a) / tempoKey(b) - 1) <= 0.06 && artist(a) != artist(b) }

func nextTrack() async -> Track? {
    while cursor < corpus.count, cursor < analysisLimit {
        let (_, path) = corpus[cursor]
        cursor += 1
        guard let e = await prepare(path, index: cursor) else { continue }
        do {
            let t = try await loadPackTrack(e)
            guard let bpm = t.result.bpm, bpm > 0, t.result.isPhaseReliable, t.result.phraseStarts.count >= 4 else {
                print("SKIP \(e.artist) – \(e.title): unreliable grid")
                continue
            }
            meta[e.id] = e
            print(String(format: "TRACK %@ %.1f bpm %@ – %@", e.id, bpm, e.artist, e.title))
            return t
        } catch {
            print("FAIL \(e.original): \(error)")
        }
    }
    return nil
}

while pairs.count < wantedPairs, let t = await nextTrack() {
    let bin = Int(tempoKey(t) / 10)
    if bins[bin, default: 0] < binCap, let partner = pool.firstIndex(where: { compatible($0, t) }) {
        let o = pool.remove(at: partner)
        pairs.append((o, t))
        bins[bin, default: 0] += 1
    } else {
        pool.append(t)
    }
}
print("PAIRS \(pairs.count) from \(cursor) corpus tracks, tempos " + pairs.map { String(format: "%.0f", tempoKey($0.1)) }.joined(separator: " "))

var triples: [(Track, Track, Track)] = []
for (o, i) in pairs where triples.count < wantedLongs {
    var third = pool.firstIndex { compatible(i, $0) && artist($0) != artist(o) }
    while third == nil, let t = await nextTrack() {
        pool.append(t)
        if compatible(i, t), artist(t) != artist(o) { third = pool.count - 1 }
    }
    guard let third else { continue }
    triples.append((o, i, pool.remove(at: third)))
}

func abTrack(_ t: Track) -> ABTrack {
    let e = meta[t.id]!
    return ABTrack(id: t.id, title: e.title, artist: e.artist, source: e.original, bpm: t.result.bpm)
}

let manifestURL = packURL.appendingPathComponent("manifest.json")
var manifest = (try? ABManifest.load(manifestURL)) ?? ABManifest(name: packURL.lastPathComponent, created: Date(), renders: [])
let analysisVersion = "BeatTracker v\(BeatTracker.version); AutoMixAB pack loader (fixed key 8A, energy 6, measured grid/phrases/vocals/bars)"

func emit(id: String, pair: String, kind: ABRender.Kind, variant: String, tracks ts: [Track], plans: [Plan], result: ChainResult, notes: String) throws {
    let file = rendersURL.appendingPathComponent("\(id).wav")
    try writeWav(result.left, result.right, to: file)
    manifest.upsert(ABRender(
        id: id, pair: pair, kind: kind, variant: variant, audio: "renders/\(id).wav", transitions: result.regions,
        tracks: ts.map(abTrack), plans: plans.compactMap { ABJSON.from(record($0)) }, executions: result.executions.compactMap { ABJSON.from($0) },
        provenance: ABProvenance(analysisVersion: analysisVersion, engineCommit: commit, lane: variant, renderer: "tools/AutoMixAB/Pack via MixRenderCore", notes: notes)
    ))
    try manifest.save(manifestURL)
    let peak = max(result.left.map(abs).max() ?? 0, result.right.map(abs).max() ?? 0)
    print(String(format: "RENDER %@ %.0f s peak %.2f regions %@ — %@", id, Double(result.left.count) / sr, peak, result.regions.map { String(format: "%.1f-%.1f", $0.start, $0.end) }.joined(separator: ","), notes))
}

for (k, (o, i)) in pairs.enumerated() {
    let pair = String(format: "p%02d", k + 1)
    guard let main = plannerTop(o, i, earliestExit: 0) else { print("NOPLAN \(pair)"); continue }
    let base = baselinePlan(o, i, like: main, floor: 0)
    do {
        let a = try renderChain(first: o, legs: [Leg(incoming: i, plan: main, baseline: false)], lead: 32, tail: 32)
        try emit(id: "\(pair)-\(mainVariant)", pair: pair, kind: .transition, variant: mainVariant, tracks: [o, i], plans: [main], result: a, notes: "\(moveName(main)) \(String(format: "%.0f", main.transitionSeconds)) s; \(main.reasoning)")
        if rendersBaseline {
            let b = try renderChain(first: o, legs: [Leg(incoming: i, plan: base, baseline: true)], lead: 32, tail: 32)
            try emit(id: "\(pair)-baseline", pair: pair, kind: .transition, variant: "baseline", tracks: [o, i], plans: [base], result: b, notes: "16-bar equal-power blend on the phrase, bass swap at half")
        }
    } catch {
        print("FAIL \(pair): \(error)")
    }
}

for (n, (a, b, c)) in triples.enumerated() {
    let pair = String(format: "l%02d", n + 1)
    guard let first = plannerTop(a, b, earliestExit: 0) else { print("NOPLAN \(pair)"); continue }
    let bBar = b.features.beatGrid?.barDuration ?? 2
    let afterFirst = first.entrySeconds + first.transitionSeconds * first.incomingRateRatio
    guard let second = plannerTop(b, c, earliestExit: afterFirst + 45) else { print("NOPLAN \(pair)"); continue }
    let body = (second.mixPointSeconds - afterFirst) / first.incomingRateRatio
    let total = 40 + first.transitionSeconds + body + second.transitionSeconds
    guard total <= 6 * 60 else { print(String(format: "SKIP %@: %.0f s long", pair, total)); continue }
    let baseFirst = baselinePlan(a, b, like: first, floor: 0)
    let baseAfter = baseFirst.entrySeconds + 16 * (a.features.beatGrid?.barDuration ?? 2) * baseFirst.incomingRateRatio
    let baseSecond = baselinePlan(b, c, like: second, floor: baseAfter + 8 * bBar)
    do {
        let m = try renderChain(first: a, legs: [Leg(incoming: b, plan: first, baseline: false), Leg(incoming: c, plan: second, baseline: false)], lead: 20, tail: 20)
        try emit(id: "\(pair)-\(mainVariant)", pair: pair, kind: .long, variant: mainVariant, tracks: [a, b, c], plans: [first, second], result: m, notes: "\(moveName(first)) then \(moveName(second))")
        if rendersBaseline {
            let s = try renderChain(first: a, legs: [Leg(incoming: b, plan: baseFirst, baseline: true), Leg(incoming: c, plan: baseSecond, baseline: true)], lead: 20, tail: 20)
            try emit(id: "\(pair)-baseline", pair: pair, kind: .long, variant: "baseline", tracks: [a, b, c], plans: [baseFirst, baseSecond], result: s, notes: "two 16-bar equal-power phrase blends")
        }
    } catch {
        print("FAIL \(pair): \(error)")
    }
}
print("DONE \(manifest.renders.count) renders in \(manifestURL.path)")

