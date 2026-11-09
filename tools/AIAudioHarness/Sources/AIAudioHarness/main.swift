import Foundation
import MLX

struct CurrentAnalysis: Decodable {
    let bpm: Double?
    let beats: [Double]
    let downbeats: [Double]
    let phraseOffsetBars: Int
    let phraseStarts: [Double]
    let confidence: Double
    let downbeatConfidence: Double
}

func fMeasure(_ reference: [Double], _ estimate: [Double], tolerance: Double = 0.07) -> Double {
    guard !reference.isEmpty, !estimate.isEmpty else { return 0 }
    var used = Set<Int>()
    var hits = 0
    for r in reference {
        var lo = 0, hi = estimate.count
        while lo < hi { let mid = (lo + hi) / 2; if estimate[mid] < r { lo = mid + 1 } else { hi = mid } }
        for j in [lo - 1, lo] where j >= 0 && j < estimate.count && !used.contains(j) && abs(estimate[j] - r) <= tolerance {
            used.insert(j); hits += 1; break
        }
    }
    let p = Double(hits) / Double(estimate.count), r = Double(hits) / Double(reference.count)
    return p + r == 0 ? 0 : 2 * p * r / (p + r)
}

func nearestIndex(_ values: [Double], _ t: Double) -> Int {
    var best = 0
    for (i, v) in values.enumerated() where abs(v - t) < abs(values[best] - t) { best = i }
    return best
}

func memoryMB() -> Double { Double(Memory.peakMemory) / 1_048_576 }

func rss() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Double(info.resident_size_max) / 1_048_576 : 0
}

func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "beats"
let weights = URL(fileURLWithPath: args.count > 2 ? args[2] : "/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/ai-weights")
let source = URL(fileURLWithPath: args.count > 3 ? args[3] : "/tmp/automix-moves-src")
let outDir = URL(fileURLWithPath: args.count > 4 ? args[4] : "/tmp/ai-audio-out")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let ids = args.count > 5 ? args[5].split(separator: ",").map(String.init) : ["darkknight", "jungle", "marionette", "voodoo"]

if mode == "logits" {
    let model = try BeatThisModel(weights: weights.appendingPathComponent("beat-this-final0/model.safetensors"))
    let url = source.appendingPathComponent("\(ids[0]).wav")
    let spectrogram = BeatThisSpectrogram()
    try AIAudioStream(url: url, sampleRate: 22_050, channels: 1).read { spectrogram.push($0[0]); return true }
    spectrogram.finish()
    let mel = spectrogram.output
    print("frames \(spectrogram.frames) mel mean \(mel.reduce(0, +) / Float(mel.count)) max \(mel.max() ?? 0)")
    let logits = model.frameLogits(spect: mel, frames: spectrogram.frames)!
    let from = Int(args.count > 6 ? args[6] : "0")!
    for i in stride(from: from, to: from + 300, by: 1) where logits.beat[i] > -2 || logits.downbeat[i] > -2 {
        print(i, String(format: "%.2fs beat %.2f down %.2f", Double(i) / 50, logits.beat[i], logits.downbeat[i]))
    }
}

struct CurrentVocals: Decodable {
    struct R: Decodable { let start: Double; let end: Double }
    let vocalRanges: [R]?
}

func covered(_ spans: [(Double, Double)], duration: Double) -> [Bool] {
    var out = [Bool](repeating: false, count: Int(duration * 10) + 1)
    for (a, b) in spans { for i in max(0, Int(a * 10))..<min(out.count, Int(b * 10)) { out[i] = true } }
    return out
}

if mode == "stems" {
    let loadStart = Date()
    let model = try OpenUnmixModel(directory: weights.appendingPathComponent("openunmix-hq"))
    print("open-unmix load \(f(Date().timeIntervalSince(loadStart)))s")
    var totalAudio = 0.0, totalTime = 0.0
    for id in ids {
        let url = source.appendingPathComponent("\(id).wav")
        let duration = AIAudioStream(url: url, sampleRate: 44_100, channels: 2).duration ?? 0
        Memory.peakMemory = 0
        let start = Date()
        guard let curve = try OpenUnmixAnalyzer.analyze(fileURL: url, model: model) else { continue }
        let elapsed = Date().timeIntervalSince(start)
        totalAudio += duration; totalTime += elapsed
        let timeline = StemTimeline(curve)
        try JSONEncoder().encode(timeline).write(to: outDir.appendingPathComponent("stems-\(id).json"))
        let beatsFile = outDir.appendingPathComponent("beatthis-\(id).json")
        let downbeats = (try? JSONDecoder().decode(BeatThisResult.self, from: Data(contentsOf: beatsFile)))?.barDownbeats ?? []
        let loops = timeline.snapped(timeline.drumsOnlyRanges, to: downbeats)
        let current = try? JSONDecoder().decode(CurrentVocals.self, from: Data(contentsOf: source.appendingPathComponent("analysis-\(id)-v2.json")))
        let a = covered(timeline.vocalRanges.map { ($0.start, $0.end) }, duration: duration)
        let b = covered((current?.vocalRanges ?? []).map { ($0.start, $0.end) }, duration: duration)
        let inter = zip(a, b).filter { $0 && $1 }.count, union = zip(a, b).filter { $0 || $1 }.count
        func list(_ s: [StemTimeline.Span]) -> String { s.prefix(12).map { "\(f($0.start, 1))-\(f($0.end, 1))" }.joined(separator: " ") }
        print("""
        \(id): \(f(duration, 1))s separated in \(f(elapsed, 2))s (\(f(duration / elapsed, 1))x realtime), MLX peak \(f(memoryMB(), 0)) MB, frames \(curve.count)
          vocals AI \(f(Double(a.filter { $0 }.count) / 10, 0))s current \(f(Double(b.filter { $0 }.count) / 10, 0))s IoU \(f(union == 0 ? 0 : Double(inter) / Double(union), 2)): \(list(timeline.vocalRanges))
          drums-only (bar-snapped) \(list(loops))
          bass ranges \(list(timeline.bassRanges))
        """)
        let (_, share, _) = StemTimeline.shares(curve, window: 15)
        let n = share[.vocals]?.count ?? 0
        print("  15s shares v/d/b/o: " + (0..<n).map { i in "\(i * 15):" + StemKind.allCases.map { f(share[$0]![i] * 100, 0) }.joined(separator: "/") }.joined(separator: " "))
    }
    print("throughput \(f(totalAudio / max(totalTime, 1e-9), 1))x realtime; 2 h set estimate \(f(7200 / max(totalAudio / max(totalTime, 1e-9), 1e-9), 0))s; process peak RSS \(f(rss(), 0)) MB")
}

if mode == "beats" {
    let loadStart = Date()
    let model = try BeatThisModel(weights: weights.appendingPathComponent("beat-this-final0/model.safetensors"))
    print("beat-this load \(f(Date().timeIntervalSince(loadStart)))s")
    for id in ids {
        let url = source.appendingPathComponent("\(id).wav")
        let duration = AIAudioStream(url: url, sampleRate: 22_050, channels: 1).duration ?? 0
        Memory.peakMemory = 0
        let start = Date()
        guard let ai = try BeatThisAnalyzer.analyze(fileURL: url, model: model) else { continue }
        let elapsed = Date().timeIntervalSince(start)
        try JSONEncoder().encode(ai).write(to: outDir.appendingPathComponent("beatthis-\(id).json"))
        let current = try JSONDecoder().decode(CurrentAnalysis.self, from: Data(contentsOf: source.appendingPathComponent("analysis-\(id)-v2.json")))
        let beatF = fMeasure(ai.beats, current.beats)
        let downF = fMeasure(ai.downbeats, current.downbeats)
        let downOnBeats = fMeasure(ai.beats, current.downbeats)
        var offsets: [Int: Int] = [:]
        let meter = ai.beatsPerBar ?? 4
        let aiDownBeatIndex = ai.downbeats.map { nearestIndex(ai.beats, $0) }
        for d in current.downbeats where !ai.beats.isEmpty {
            let i = nearestIndex(ai.beats, d)
            guard abs(ai.beats[i] - d) <= 0.07, let last = aiDownBeatIndex.last(where: { $0 <= i }) else { continue }
            offsets[(i - last) % meter, default: 0] += 1
        }
        var phraseBars: [Int: Int] = [:]
        var phraseHits = 0
        for p in current.phraseStarts {
            let i = nearestIndex(ai.downbeats, p)
            guard !ai.downbeats.isEmpty, abs(ai.downbeats[i] - p) <= 0.07 else { continue }
            phraseHits += 1
            phraseBars[i % 8, default: 0] += 1
        }
        print("""
        \(id): \(f(duration, 1))s analysed in \(f(elapsed, 2))s (\(f(duration / elapsed, 1))x realtime), MLX peak \(f(memoryMB(), 0)) MB, process peak RSS \(f(rss(), 0)) MB
          AI bpm \(ai.bpm.map { f($0, 2) } ?? "-") meter \(meter) beats \(ai.beats.count) downbeats \(ai.downbeats.count) conf \(f(ai.confidence)) downConf \(f(ai.downbeatConfidence))
          current bpm \(current.bpm.map { f($0, 2) } ?? "-") beats \(current.beats.count) downbeats \(current.downbeats.count) conf \(f(current.confidence)) downConf \(f(current.downbeatConfidence)) phraseOffsetBars \(current.phraseOffsetBars)
          beat F \(f(beatF)) downbeat F \(f(downF)) current-downbeats-on-AI-beats F \(f(downOnBeats))
          current downbeat position within AI bar (beat offset: count) \(offsets.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
          current phrase starts on AI downbeats \(phraseHits)/\(current.phraseStarts.count), AI bar index mod 8: \(phraseBars.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
          first AI downbeats \(ai.downbeats.prefix(4).map { f($0, 2) }) current \(current.downbeats.prefix(4).map { f($0, 2) })
        """)
        var windows: [String] = []
        var t = 0.0
        while t < duration {
            let r = current.beats.filter { $0 >= t && $0 < t + 30 }
            let e = ai.beats.filter { $0 >= t && $0 < t + 30 }
            let rd = current.downbeats.filter { $0 >= t && $0 < t + 30 }
            let ed = ai.downbeats.filter { $0 >= t && $0 < t + 30 }
            windows.append("\(Int(t)):\(f(fMeasure(r, e), 2))/\(f(fMeasure(rd, ed), 2))")
            t += 30
        }
        print("  per-30s beat/downbeat F: " + windows.joined(separator: " "))
        let spectrogram = BeatThisSpectrogram()
        try AIAudioStream(url: url, sampleRate: 22_050, channels: 1).read { spectrogram.push($0[0]); return true }
        spectrogram.finish()
        let mel = spectrogram.output, frames = spectrogram.frames
        var flux = [Float](repeating: 0, count: frames)
        for i in 1..<frames {
            var s: Float = 0
            for b in 0..<20 { s += max(0, mel[i * 128 + b] - mel[(i - 1) * 128 + b]) }
            flux[i] = s
        }
        func strength(_ times: [Double]) -> Double {
            let values = times.compactMap { t -> Float? in
                let i = Int((t * 50).rounded())
                guard i >= 1, i < frames - 1 else { return nil }
                return max(flux[i - 1], flux[i], flux[i + 1])
            }
            return values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
        }
        let average = Double(flux.reduce(0, +)) / Double(frames)
        var arbiter: [String] = []
        t = 0
        while t < duration {
            let r = current.beats.filter { $0 >= t && $0 < t + 30 }
            let e = ai.beats.filter { $0 >= t && $0 < t + 30 }
            arbiter.append("\(Int(t)):\(f(strength(r) / average, 1))/\(f(strength(e) / average, 1))")
            t += 30
        }
        print("  per-30s low-band onset strength at beats, current/AI (x mean): " + arbiter.joined(separator: " "))
    }
}
