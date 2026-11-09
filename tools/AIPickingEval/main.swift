import Foundation
import AVFoundation
import CreateMLComponents
import MusicUnderstanding

struct Measured: Codable {
    let name: String
    let duration: Double
    let bpm: Double?
    let wheel: Int?
    let mode: Int?
    let vocals: [[Double]]
    let envelope: [Float]
    let timbre: TimbreEmbedding
    let embedSeconds: Double
    let analyseSeconds: Double
    let loudnessDb: Double
}

func envelope(url: URL, bucketSeconds: Double = 2) throws -> ([Float], Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(format.sampleRate * bucketSeconds)
    var out: [Float] = []
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return ([], 0) }
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: frames)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
        out.append((sum / Float(buffer.frameLength)).squareRoot())
    }
    return (out, Double(file.length) / format.sampleRate)
}

func measure(_ url: URL) async throws -> Measured {
    let started = Date()
    let buffers = try AudioReader.read(contentsOf: url)
    var frames: [[Float]] = []
    for try await frame in try AudioFeaturePrint(windowDuration: 0.975, overlapFactor: 0).applied(to: buffers) {
        frames.append(frame.feature.scalars)
    }
    guard let timbre = TimbreEmbedding(frames: frames) else { throw CocoaError(.fileReadCorruptFile) }
    let embedSeconds = Date().timeIntervalSince(started)
    let (raw, duration) = try envelope(url: url)
    let sortedRaw = raw.sorted()
    let loud = Double(sortedRaw[min(sortedRaw.count - 1, Int(Double(sortedRaw.count) * 0.75))])
    let loudnessDb = 20 * log10(max(1e-6, loud))
    let peak = raw.max() ?? 1
    let env = raw.map { peak > 0 ? $0 / peak : 0 }
    let analyseStart = Date()
    var bpm: Double?
    var wheel: Int?
    var mode: Int?
    var vocals: [[Double]] = []
    do {
        let session = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
        let result = try await session.analyze(for: [.rhythm, .key, .instrumentActivity])
        bpm = result.rhythm?.beatsPerMinute.map(Double.init)
        if let longest = result.key?.ranges.max(by: { $0.range.duration.seconds < $1.range.duration.seconds }) {
            let pcs: [KeyResult.Tonic: Int] = [.c: 0, .cSharp: 1, .dFlat: 1, .d: 2, .dSharp: 3, .eFlat: 3, .e: 4, .f: 5, .fSharp: 6, .gFlat: 6, .g: 7, .gSharp: 8, .aFlat: 8, .a: 9, .aSharp: 10, .bFlat: 10, .b: 11]
            if let pc = pcs[longest.value.tonic] {
                let key = CamelotKey(pitchClass: pc, isMinor: longest.value.mode == .minor)
                wheel = key.wheelPosition
                mode = key.mode.rawValue
            }
        }
        vocals = (result.instrumentActivity?.ranges[.vocal] ?? []).map { [$0.start.seconds, $0.end.seconds] }
    } catch {
        FileHandle.standardError.write("MusicUnderstanding failed for \(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
    }
    return Measured(
        name: url.deletingPathExtension().lastPathComponent, duration: duration, bpm: bpm, wheel: wheel, mode: mode,
        vocals: vocals, envelope: env, timbre: timbre, embedSeconds: embedSeconds,
        analyseSeconds: Date().timeIntervalSince(analyseStart), loudnessDb: loudnessDb
    )
}

func features(_ m: Measured, timbre: Bool = true) -> TrackFeatures {
    var key: CamelotKey?
    if let w = m.wheel, let md = m.mode, let mode = CamelotKey.CamelotMode(rawValue: md) {
        key = CamelotKey(wheelPosition: w, mode: mode)
    }
    let bucketCount = max(8, Int((m.duration / 2).rounded()))
    let env = m.envelope.count == bucketCount ? m.envelope : m.envelope
    var f = TrackFeatures(
        trackId: m.name, title: m.name, artist: m.name, duration: m.duration,
        beatGrid: m.bpm.flatMap { BeatGrid.tempoOnly($0) },
        keyRegions: key.map { [KeyRegion(key: $0, start: 0, end: m.duration)] } ?? [],
        energyLevel: energyLevel(m),
        envelope: env,
        vocalRanges: m.vocals.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
    )
    if timbre { f.timbre = m.timbre }
    return f
}

func energyLevel(_ m: Measured) -> Int {
    let tempo = m.bpm.map { min(1, max(0, ($0 - 95) / 40)) } ?? 0.5
    let loud = min(1, max(0, (m.loudnessDb + 20) / 14))
    return min(10, max(1, Int((1 + 9 * (0.55 * loud + 0.45 * tempo)).rounded())))
}

func short(_ s: String, _ n: Int = 34) -> String {
    s.count <= n ? s.padding(toLength: n, withPad: " ", startingAt: 0) : String(s.prefix(n - 1)) + "…"
}

func describe(_ f: TrackFeatures) -> String {
    let bpm = f.beatGrid.map { String(format: "%5.1f", $0.bpm) } ?? "  –  "
    let key = f.key(at: 0)?.label ?? "– "
    let e = DJFlowSelector.energy(f).map(String.init) ?? "–"
    let v = f.vocalRanges.isEmpty ? "inst" : "vox"
    return "\(bpm) \(key.padding(toLength: 3, withPad: " ", startingAt: 0)) e\(e) \(v)"
}

setvbuf(stdout, nil, _IONBF, 0)
let cacheURL = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/aipick/measured.json")
let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 16 : 16
var measured: [Measured] = (try? JSONDecoder().decode([Measured].self, from: Data(contentsOf: cacheURL))) ?? []
if measured.count < count {
    let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/SoundCloud")
    let files = (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
        .filter { ["m4a", "mp3", "wav", "aiff"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let stride = max(1, files.count / (count * 2))
    var picked: [URL] = []
    var index = 0
    while picked.count < count * 2, index < files.count { picked.append(files[index]); index += stride }
    for url in picked where measured.count < count {
        guard !measured.contains(where: { $0.name == url.deletingPathExtension().lastPathComponent }) else { continue }
        guard let asset = try? AVAudioFile(forReading: url), Double(asset.length) / asset.processingFormat.sampleRate < 600 else { continue }
        do {
            let m = try await measure(url)
            measured.append(m)
            print(String(format: "measured %@  embed %.1fs  analyse %.1fs", short(m.name), m.embedSeconds, m.analyseSeconds))
        } catch {
            print("skip \(url.lastPathComponent): \(error)")
        }
    }
    try JSONEncoder().encode(measured).write(to: cacheURL)
}

let tracks = measured.map { features($0) }
let plain = measured.map { features($0, timbre: false) }
let embedTotal = measured.map(\.embedSeconds).reduce(0, +)
let audioTotal = measured.map(\.duration).reduce(0, +)
print(String(format: "\n%d tracks, %.0f min of audio, embeddings %.1fs total (%.0fx real time), %d bytes per track stored", measured.count, audioTotal / 60, embedTotal, audioTotal / max(0.01, embedTotal), (try? JSONEncoder().encode(measured[0].timbre).count) ?? 0))

print("\n## Sanity: same track opening vs closing, vs nearest other track")
for t in tracks.prefix(6) {
    let selfSeam = TimbreEmbedding.cosine(t.timbre!.opening, t.timbre!.closing) ?? 0
    let others = tracks.filter { $0.trackId != t.trackId }.map { ($0.trackId, t.timbre!.similarity(to: $0.timbre!) ?? 0) }.sorted { $0.1 > $1.1 }
    print(String(format: "%@ self %.3f  nearest %.3f %@  farthest %.3f %@", short(t.trackId, 30), selfSeam, others[0].1, short(others[0].0, 26), others.last!.1, short(others.last!.0, 26)))
}
let allPairs = tracks.indices.flatMap { i in tracks.indices.filter { $0 > i }.map { j in tracks[i].timbre!.similarity(to: tracks[j].timbre!) ?? 0 } }.sorted()
print(String(format: "pairwise cosine: min %.3f  p25 %.3f  median %.3f  p75 %.3f  max %.3f", allPairs.first!, allPairs[allPairs.count / 4], allPairs[allPairs.count / 2], allPairs[allPairs.count * 3 / 4], allPairs.last!))

func ranked(_ seed: TrackFeatures, _ pool: [TrackFeatures], history: SetHistory) -> [(TrackFeatures, DJFlowSelector.StepCost)] {
    pool.filter { $0.trackId != seed.trackId }
        .map { ($0, DJFlowSelector.stepCost(from: seed, to: $0, queueIndex: 0, energyGoal: DJFlowSelector.energy(seed), history: history, recentInPath: [])) }
        .sorted { $0.1.total < $1.1.total }
}

for seedIndex in [0, tracks.count / 2] {
    let seed = tracks[seedIndex]
    print("\n## Next-track ranking after: \(seed.trackId)  [\(describe(seed))]")
    let before = ranked(plain[seedIndex], plain, history: .empty)
    let after = ranked(seed, tracks, history: .empty)
    print("   BEFORE (BPM, key, energy, genre)                         AFTER (+ sound, energy trajectory)")
    for row in 0..<min(8, before.count) {
        let b = before[row]
        let a = after[row]
        let cos = seed.timbre!.similarity(to: a.0.timbre!) ?? 0
        let bText = b.1.vetoReason.map { "veto: \($0)" } ?? String(format: "%.2f", b.1.total)
        let aText = a.1.vetoReason.map { "veto: \($0)" } ?? String(format: "%.2f cos %.2f", a.1.total, cos)
        print("\(row + 1). \(short(b.0.trackId, 28)) \(short(bText, 14))  \(short(a.0.trackId, 28)) \(aText)")
    }
}

func admissible(_ t: TrackFeatures) -> Int {
    tracks.filter { $0.trackId != t.trackId && DJFlowSelector.stepCost(from: t, to: $0, queueIndex: 0, energyGoal: nil, history: .empty, recentInPath: []).vetoReason == nil }.count
}
let connected = tracks.filter { admissible($0) >= 6 }
print("\n\(connected.count) of \(tracks.count) tracks have 6+ admissible next tracks (key within 2 steps, tempo within 6%)")
let seed = (connected.isEmpty ? tracks : connected).min { (DJFlowSelector.energy($0) ?? 10) < (DJFlowSelector.energy($1) ?? 10) }!
let now = Date()
let request = "warm-up set, building to peak in 45 minutes, no vocals for the first 15 minutes"
let intent = SetIntentParser.parse(request, now: now)!
print("\n## Set journey from \(seed.trackId) for: \"\(request)\"")
print("   intent: \(intent.summary)")
var history = SetHistory()
history.intent = intent
let greedy = SetJourney.greedy(from: seed, pool: tracks, history: history, length: 10)
guard let journey = SetJourney.plan(from: seed, pool: tracks, history: history, length: 10) else { print("no journey: every path vetoed"); exit(0) }
let byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackId, $0) })
print("   GREEDY (one pick at a time)                     JOURNEY (beam over the whole arc)")
for (i, step) in journey.steps.enumerated() {
    let g = i < greedy.count ? byId[greedy[i]]! : nil
    let left = g.map { "\(short($0.trackId, 26)) \(describe($0))" } ?? ""
    let right = "\(short(step.trackId, 26)) \(describe(byId[step.trackId]!)) goal e\(step.targetEnergy ?? 0) @\(Int(step.atMinute))m"
    print("\(String(format: "%2d", i + 1)). \(left.padding(toLength: 48, withPad: " ", startingAt: 0))  \(right)")
}
func arcError(_ ids: [String]) -> (Double, Int) {
    var minute = seed.duration / 60 * DJFlowSelector.playedShare
    var error = 0.0
    var vocalBreaks = 0
    for id in ids {
        let t = byId[id]!
        error += Double(abs((DJFlowSelector.energy(t) ?? 5) - intent.targetEnergy(atMinute: minute)))
        if !intent.allowsVocals(atMinute: minute), !t.vocalRanges.isEmpty { vocalBreaks += 1 }
        minute += t.duration / 60 * DJFlowSelector.playedShare
    }
    return (error / Double(max(1, ids.count)), vocalBreaks)
}
let g = arcError(greedy)
let j = arcError(journey.steps.map(\.trackId))
print(String(format: "   mean |energy - arc|: greedy %.2f, journey %.2f.  vocals before allowed: greedy %d, journey %d", g.0, j.0, g.1, j.1))
print("\n## Why lines (deterministic fallback, model off)")
for step in journey.steps.prefix(4) {
    print("   \(step.trackId.prefix(30)): \(PickReason.deterministicLine(step.reasons))")
}
