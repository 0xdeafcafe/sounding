import AVFoundation
import Accelerate
import Foundation

let args = CommandLine.arguments
let corpusFile = URL(fileURLWithPath: args.count > 1 ? args[1] : "tracks.tsv")
let cacheDirectory = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/automix-level-cache")
let outputDirectory = URL(fileURLWithPath: args.count > 3 ? args[3] : "/tmp/automix-level-out")
let pairTarget = args.count > 4 ? Int(args[4]) ?? 150 : 150
let packCount = args.count > 5 ? Int(args[5]) ?? 12 : 12
let seed: UInt64 = 2026
let sr = 44_100.0
#if AFTER
let build = "after"
#else
let build = "before"
#endif
try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

struct Entry { var seconds: Double; var path: String }

let entries: [Entry] = try String(contentsOf: corpusFile, encoding: .utf8).split(separator: "\n").compactMap { line in
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
    return Entry(seconds: seconds, path: String(parts[1]))
}

func cacheURL(_ path: String) -> URL {
    let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return cacheDirectory.appendingPathComponent("beats-\(fnv(path))-\(Int(mtime))-v\(BeatTracker.version).json")
}

func analysis(_ path: String) async -> BeatTrackerResult? {
    let cache = cacheURL(path)
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(BeatTrackerResult.self, from: data) { return cached }
    guard let result = try? await BeatTracker.analyze(fileURL: URL(fileURLWithPath: path)) else { return nil }
    try? JSONEncoder().encode(result).write(to: cache)
    return result
}

var rng = SplitMix(state: seed)
var pool = entries.filter { $0.seconds >= 150 && $0.seconds <= 600 }
for i in stride(from: pool.count - 1, to: 0, by: -1) { pool.swapAt(i, rng.below(i + 1)) }
let poolSize = min(pool.count, 72)
let chosen = Array(pool.prefix(poolSize))
print("pool \(chosen.count) tracks from \(entries.count), seed \(seed)")

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
let results = Box<[String: BeatTrackerResult]>([:])
let lock = NSLock()
let started = Date()
await withTaskGroup(of: Void.self) { group in
    var next = 0
    func add() {
        guard next < chosen.count else { return }
        let path = chosen[next].path
        next += 1
        group.addTask {
            if let r = await analysis(path) {
                lock.lock(); results.value[path] = r; lock.unlock()
            }
        }
    }
    for _ in 0..<6 { add() }
    while await group.next() != nil { add() }
}
print("analysed \(results.value.count) in \(Int(Date().timeIntervalSince(started))) s")

struct Track {
    var path: String
    var result: BeatTrackerResult
    var grid: BeatGrid
    var level: [Float]
    var downbeats: [Double]
    var integrated: Double
    var peak: Double
}

struct Loudness: Codable { var integrated: Double; var peak: Double }

func integratedLoudness(_ path: String, downbeats: [Double]) -> Loudness? {
    let cache = URL(fileURLWithPath: cacheURL(path).path.replacingOccurrences(of: "/beats-", with: "/loud-"))
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(Loudness.self, from: data) { return cached }
    guard let source = try? MixSource(url: URL(fileURLWithPath: path), synchronous: true) else { return nil }
    let bars = LocalLoudness.measure(source: source, barStarts: downbeats, bars: 0..<downbeats.count)
    let powers = bars.bars.values.map(\.power).filter { $0 > 1e-7 }
    let gate = (powers.reduce(0, +) / Double(max(1, powers.count))) * 0.1
    let gated = powers.filter { $0 >= gate }
    let value = Loudness(
        integrated: LocalLoudness.lufs(gated.reduce(0, +) / Double(max(1, gated.count))),
        peak: 20 * log10(max(1e-9, bars.bars.values.map(\.peak).max() ?? 1))
    )
    try? JSONEncoder().encode(value).write(to: cache)
    return value
}

var tracks: [String: Track] = [:]
var rejected: Set<String> = []
func track(_ path: String) -> Track? {
    if let t = tracks[path] { return t }
    guard !rejected.contains(path) else { return nil }
    let downbeats = results.value[path]?.downbeats.sorted() ?? []
    guard let result = results.value[path], let grid = result.beatGrid(), downbeats.count > 48,
          let level = result.bars?.level, level.count == result.downbeats.count,
          let loudness = autoreleasepool(invoking: { integratedLoudness(path, downbeats: downbeats) }) else {
        rejected.insert(path)
        return nil
    }
    let t = Track(path: path, result: result, grid: grid, level: level, downbeats: downbeats, integrated: loudness.integrated, peak: loudness.peak)
    tracks[path] = t
    return t
}

func bodyBars(_ t: Track, from: Int, count: Int) -> Bool {
    guard from >= 0, from + count <= t.level.count else { return false }
    let median = t.level.sorted()[t.level.count / 2]
    var loud = 0
    for k in from..<(from + count) where t.level[k] >= median - 1.5 { loud += 1 }
    return loud >= count - 1
}

func exitBar(_ t: Track, blend: Int) -> Int? {
    let n = t.downbeats.count
    let offset = t.result.phraseOffsetBars
    var candidates: [Int] = []
    var k = Int(Double(n) * 0.5)
    while k + blend + 2 < n, k < Int(Double(n) * 0.85) {
        if (k - offset) % 8 == 0, bodyBars(t, from: k - 8, count: 8 + blend) { candidates.append(k) }
        k += 1
    }
    return candidates.first
}

func entryBar(_ t: Track, blend: Int) -> Int? {
    let n = t.downbeats.count
    let offset = t.result.phraseOffsetBars
    var k = max(8, Int(Double(n) * 0.1))
    while k + blend + 8 < n, k < Int(Double(n) * 0.5) {
        if (k - offset) % 8 == 0, bodyBars(t, from: k, count: blend + 8) { return k }
        k += 1
    }
    return nil
}

struct Pair { var out: String; var inc: String; var exit: Int; var entry: Int; var ratio: Double; var loop: Bool; var blend: Int }
var pairs: [Pair] = []
var tries = 0
let ready = chosen.map(\.path).filter { results.value[$0] != nil }
while pairs.count < pairTarget, tries < 20_000, ready.count > 2 {
    tries += 1
    let a = ready[rng.below(ready.count)]
    let b = ready[rng.below(ready.count)]
    guard a != b, !pairs.contains(where: { $0.out == a && $0.inc == b }) else { continue }
    guard let ra = results.value[a], let rb = results.value[b], let ba = ra.bpm, let bb = rb.bpm else { continue }
    let ratio = ba / bb
    guard abs(ratio - 1) <= 0.08 else { continue }
    let loop = rng.below(5) == 0
    let blend = loop ? 8 : [16, 16, 32][rng.below(3)]
    guard let ta = track(a), let tb = track(b), let exit = exitBar(ta, blend: blend), let entry = entryBar(tb, blend: blend) else { continue }
    pairs.append(Pair(out: a, inc: b, exit: exit, entry: entry, ratio: ratio, loop: loop, blend: blend))
}
print("pairs \(pairs.count) after \(tries) draws")

struct Renders {
    var mix: [Float]
    var mixR: [Float]
    var soloA: [Float]
    var soloB: [Float]
    var preL: [Float]
    var preR: [Float]
    var start: Double
    var fadeStart: Double
    var fadeEnd: Double
    var beat: Double
    var shape: Double
}

func normalisation(_ t: Track) -> Double {
    #if AFTER
    return LoudnessNormalization.gain(measuredLUFS: Float(t.integrated), peakDecibels: Float(t.peak))
    #else
    return LoudnessNormalization.attenuation(measuredLUFS: Float(t.integrated))
    #endif
}

func render(_ pair: Pair, sources: (MixSource, MixSource), solo: Int?, master: Double) -> (left: [Float], right: [Float], window: (Double, Double), lead: Double, total: Double, shape: Double) {
    let ta = tracks[pair.out]!
    let tb = tracks[pair.inc]!
    let core = MixRenderCore(sampleRate: sr)
    var seq: Int64 = 0
    func push(_ make: (Int64) -> MixCommand) { seq += 1; _ = core.ring.push(make(seq)) }
    push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(sources.0)) }
    push { .load(seq: $0, deck: 1, source: Unmanaged.passUnretained(sources.1)) }
    let tableA = MixBeatTable(grid: ta.grid, sampleRate: sr)
    let tableB = MixBeatTable(grid: tb.grid, sampleRate: sr)
    if let tableA { push { .beats(seq: $0, deck: 0, table: Unmanaged.passUnretained(tableA)) } }
    if let tableB { push { .beats(seq: $0, deck: 1, table: Unmanaged.passUnretained(tableB)) } }
    func now(_ action: MixTimelineAction) { push { .event(seq: $0, time: 0, immediate: true, group: 0, action: action) } }
    let gainA = normalisation(ta)
    let gainB = normalisation(tb)
    now(.ramp(.crossfade, to: 0, frames: 0, curve: .linear))
    now(.ramp(.eqLow(1), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
    now(.ramp(.rate(1), to: pair.ratio, frames: 0, curve: .linear))
    now(.ramp(.gain(0), to: gainA, frames: 0, curve: .linear))
    now(.ramp(.gain(1), to: gainB, frames: 0, curve: .linear))
    now(.ramp(.master, to: master, frames: 0, curve: .linear))
    if let solo { push { .solo(seq: $0, deck: solo) } }
    let mixPoint = ta.downbeats[pair.exit]
    let entry = tb.downbeats[pair.entry]
    let barSeconds = ta.downbeats[pair.exit + 1] - ta.downbeats[pair.exit]
    let lead = 8 * barSeconds
    now(.start(deck: 0, fromFrame: (mixPoint - lead) * sr))
    let lock = ta.grid.isPhaseVerified && tb.grid.isPhaseVerified
    var move = pair.loop ? MixMove.loopMix(outLoop: 4, inLoop: 0, fadeIn: 8, fadeOut: 4) : MixMove.blend(bars: pair.blend, swapAt: pair.blend / 2)
    #if AFTER
    let outBars = max(0, pair.exit - 8)..<(pair.exit + 8)
    let inBars = pair.entry..<(pair.entry + 16)
    let outBody = LocalLoudness.measure(source: sources.0, barStarts: ta.downbeats, bars: outBars).body(bars: outBars)
    let inBody = LocalLoudness.measure(source: sources.1, barStarts: tb.downbeats, bars: inBars).body(bars: inBars)
    let level = TransitionLevel.plan(outgoing: outBody, incoming: inBody, outgoingGain: gainA, incomingGain: gainB)
    #endif
    if pair.loop { move.shape = nil }
    var input = MixTransitionTimelineInput(
        outgoing: 0, incoming: 1, sampleRate: sr, anchorSourceSeconds: mixPoint, window: Double(pair.blend) * barSeconds,
        entrySeconds: entry, outgoingRate: 1, incomingRate: pair.ratio, outgoingGrid: ta.grid, incomingGrid: tb.grid,
        stages: [], bassSwapAtSeconds: nil, bassSwapSeconds: nil, filterAccent: nil, defersIncomingStart: false,
        phaseLock: lock, move: move, riserGain: 0, incomingMidCutDecibels: 0
    )
    #if AFTER
    input.level = level
    #endif
    _ = input
    let timeline = MixTimeline.transition(input)
    var shape = 0.0
    for event in timeline.events {
        if case .ramp(let p, let v, _, _) = event.action, p == .crossfadeCurve, v > 0 { shape = v }
        push { .event(seq: $0, time: event.offset, immediate: false, group: 7, action: event.action) }
    }
    push { .anchor(seq: $0, group: 7, anchor: timeline.anchor) }
    let length = Double(timeline.lengthFrames) / sr
    var fadeStart = Double.infinity
    var fadeEnd = 0.0
    for event in timeline.events {
        if case .ramp(let p, _, let frames, _) = event.action, p == .crossfade {
            fadeStart = min(fadeStart, Double(event.offset) / sr)
            fadeEnd = max(fadeEnd, Double(event.offset + frames) / sr)
        }
    }
    let tail = 8 * barSeconds
    let total = Int((lead + length + tail) * sr)
    var left = [Float](repeating: 0, count: total)
    var right = [Float](repeating: 0, count: total)
    let block = 512
    let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { l.deallocate(); r.deallocate() }
    var done = 0
    while done < total {
        let n = min(block, total - done)
        core.render(frames: n, left: l, right: r)
        for k in 0..<n { left[done + k] = l[k]; right[done + k] = r[k] }
        done += n
    }
    withExtendedLifetime((tableA, tableB)) {}
    return (left, right, (lead + fadeStart, lead + min(fadeEnd, length)), lead, Double(total) / sr, shape)
}

func kWeighted(_ l: [Float], _ r: [Float]) -> [Double] {
    var meter = KWeightedMeter(sampleRate: sr)
    let hop = Int(sr * 0.1)
    var blocks: [Double] = []
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: hop * 2)
    defer { buffer.deallocate() }
    var i = 0
    while i + hop <= l.count {
        for k in 0..<hop { buffer[2 * k] = l[i + k]; buffer[2 * k + 1] = r[i + k] }
        meter.begin()
        meter.process(buffer, frames: hop)
        blocks.append(meter.bar().power)
        i += hop
    }
    return blocks
}

func lufs(_ blocks: [Double], _ from: Double, _ to: Double) -> Double {
    let a = max(0, Int(from * 10)), b = min(blocks.count, Int(to * 10))
    guard b > a else { return -70 }
    return LocalLoudness.lufs(blocks[a..<b].reduce(0, +) / Double(b - a))
}

func shortTerm(_ blocks: [Double], from: Double, to: Double) -> [Double] {
    var out: [Double] = []
    var t = from
    while t + 3 <= to + 0.01 {
        out.append(lufs(blocks, t, t + 3))
        t += 0.5
    }
    return out
}

func truePeak(_ x: [Float], _ y: [Float]) -> Double {
    let taps = 12
    var kernels: [[Float]] = []
    for phase in 1..<4 {
        let frac = Double(phase) / 4
        kernels.append((-taps..<taps).map { t in
            let d = Double(t) + 1 - frac
            let sinc = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
            return Float(sinc * (0.5 + 0.5 * cos(.pi * d / Double(taps + 1))))
        })
    }
    var peak: Float = 0
    for signal in [x, y] {
        var mags = [Float](repeating: 0, count: signal.count)
        vDSP_vabs(signal, 1, &mags, 1, vDSP_Length(signal.count))
        peak = max(peak, mags.max() ?? 0)
        for k in kernels {
            let n = signal.count - 2 * taps
            guard n > 0 else { continue }
            var out = [Float](repeating: 0, count: n)
            vDSP_conv(signal, 1, k.reversed(), 1, &out, 1, vDSP_Length(n), vDSP_Length(k.count))
            var m: Float = 0
            vDSP_maxmgv(out, 1, &m, vDSP_Length(n))
            peak = max(peak, m)
        }
    }
    return 20 * log10(max(1e-9, Double(peak)))
}

func lowBand(_ l: [Float], _ r: [Float], window: Int) -> [Double] {
    var lp1 = KWeightedMeter.Biquad.lowPass(150, sampleRate: sr)
    var lp2 = KWeightedMeter.Biquad.lowPass(150, sampleRate: sr)
    var out: [Double] = []
    var sum = 0.0
    var count = 0
    for i in 0..<l.count {
        let v = lp2.run(lp1.run(Double(l[i] + r[i]) * 0.5))
        sum += v * v
        count += 1
        if count == window { out.append(sum / Double(window)); sum = 0; count = 0 }
    }
    return out
}

func db(_ p: Double) -> Double { 10 * log10(max(1e-12, p)) }

struct Metrics: Codable {
    var pair: Int
    var out: String
    var inc: String
    var loop: Bool
    var bars: Int
    var shape: Double
    var levelBefore: Double
    var levelAfter: Double
    var step: Double
    var dip: Double
    var swell: Double
    var truePeak: Double
    var limiterSeconds: Double
    var limiterDeepSeconds: Double
    var limiterMaxDB: Double
    var preLUFS: Double
    var postLUFS: Double
    var lowOverlapShare: Double
    var lowOverlapSeconds: Double
    var bassHoleBeats: Int
}

var metrics: [Metrics] = []
let packEvery = max(1, pairs.count / max(1, packCount))
var packed = 0
let packDirectory = outputDirectory.appendingPathComponent("pack")
try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)

func writeM4A(_ l: [Float], _ r: [Float], from: Double, to: Double, url: URL) throws {
    let a = max(0, Int(from * sr)), b = min(l.count, Int(to * sr))
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(b - a))!
    buffer.frameLength = AVAudioFrameCount(b - a)
    for i in a..<b {
        buffer.floatChannelData![0][i - a] = l[i]
        buffer.floatChannelData![1][i - a] = r[i]
    }
    try file.write(from: buffer)
}

let renderStart = Date()
for (index, pair) in pairs.enumerated() { try autoreleasepool {
    guard let sa = try? MixSource(url: URL(fileURLWithPath: pair.out), synchronous: true),
          let sb = try? MixSource(url: URL(fileURLWithPath: pair.inc), synchronous: true) else { return }
    let mix = render(pair, sources: (sa, sb), solo: nil, master: 1)
    let a = render(pair, sources: (sa, sb), solo: 0, master: 0.1)
    let b = render(pair, sources: (sa, sb), solo: 1, master: 0.1)
    let n = min(mix.left.count, a.left.count, b.left.count)
    var preL = [Float](repeating: 0, count: n)
    var preR = [Float](repeating: 0, count: n)
    for i in 0..<n { preL[i] = (a.left[i] + b.left[i]) * 10; preR[i] = (a.right[i] + b.right[i]) * 10 }
    let ta = tracks[pair.out]!
    let beat = (ta.downbeats[pair.exit + 1] - ta.downbeats[pair.exit]) / 4
    let (fadeStart, fadeEnd) = mix.window
    let post = kWeighted(mix.left, mix.right)
    let pre = kWeighted(preL, preR)
    let before = lufs(post, fadeStart - 32 * beat, fadeStart)
    let after = lufs(post, fadeEnd, min(mix.total, fadeEnd + 32 * beat))
    let st = shortTerm(post, from: fadeStart, to: fadeEnd)
    let lower = min(before, after), higher = max(before, after)
    let dip = max(0, lower - (st.min() ?? lower))
    let swell = max(0, (st.max() ?? higher) - higher)
    let tp = truePeak(Array(mix.left[Int(fadeStart * sr)..<Int(min(mix.total, fadeEnd) * sr)]), Array(mix.right[Int(fadeStart * sr)..<Int(min(mix.total, fadeEnd) * sr)]))
    let block = Int(sr * 0.01)
    let delay = MixLimiter.lookahead
    var reduced = 0, deep = 0
    var worst = 0.0
    var i = Int(fadeStart * sr) + delay
    let stop = min(n, Int(fadeEnd * sr))
    while i + block < stop {
        var sp = 0.0, sq = 0.0
        for k in i..<(i + block) {
            sp += Double(mix.left[k] * mix.left[k] + mix.right[k] * mix.right[k])
            sq += Double(preL[k - delay] * preL[k - delay] + preR[k - delay] * preR[k - delay])
        }
        if sq > 1e-9 {
            let gr = 10 * log10(max(1e-12, sp) / sq)
            if gr < -0.5 { reduced += 1 }
            if gr < -2 { deep += 1 }
            worst = min(worst, gr)
        }
        i += block
    }
    let window = Int(sr * 0.05)
    let lowA = lowBand(a.left, a.right, window: window)
    let lowB = lowBand(b.left, b.right, window: window)
    let lo = Int(fadeStart / 0.05), hi = min(lowA.count, lowB.count, Int(fadeEnd / 0.05))
    var overlap = 0.0, total = 0.0, overlapSeconds = 0.0
    if hi > lo {
        for k in lo..<hi {
            overlap += min(lowA[k], lowB[k])
            total += lowA[k] + lowB[k]
            if db(lowA[k]) > -60, db(lowB[k]) > -60, abs(db(lowA[k]) - db(lowB[k])) < 10 { overlapSeconds += 0.05 }
        }
    }
    let beatWindow = max(1, Int(beat / 0.05))
    let preLow = lowA[max(0, lo - 8 * beatWindow)..<max(1, lo)].reduce(0, +) / Double(max(1, lo - max(0, lo - 8 * beatWindow)))
    let tailLo = min(lowB.count - 1, Int(fadeEnd / 0.05))
    let tailHi = min(lowB.count, tailLo + 8 * beatWindow)
    let postLow = lowB[tailLo..<max(tailLo + 1, tailHi)].reduce(0, +) / Double(max(1, tailHi - tailLo))
    let reference = min(db(preLow), db(postLow))
    var holes = 0
    var k = lo
    while k + beatWindow <= hi {
        var s = 0.0
        for j in k..<(k + beatWindow) { s += lowA[j] + lowB[j] }
        if db(s / Double(beatWindow)) < reference - 6 { holes += 1 }
        k += beatWindow
    }
    let m = Metrics(
        pair: index, out: (pair.out as NSString).lastPathComponent, inc: (pair.inc as NSString).lastPathComponent,
        loop: pair.loop, bars: pair.blend, shape: mix.shape,
        levelBefore: before, levelAfter: after, step: after - before, dip: dip, swell: swell, truePeak: tp,
        limiterSeconds: Double(reduced) * 0.01, limiterDeepSeconds: Double(deep) * 0.01, limiterMaxDB: worst,
        preLUFS: lufs(pre, fadeStart, fadeEnd), postLUFS: lufs(post, fadeStart, fadeEnd),
        lowOverlapShare: total > 0 ? overlap / total : 0, lowOverlapSeconds: overlapSeconds, bassHoleBeats: holes
    )
    metrics.append(m)
    print(String(format: "%3d %@ step %+.1f dip %.1f swell %.1f tp %.1f lim %.1fs pre %.1f post %.1f low %.2f holes %d shape %.2f", index, pair.loop ? "loop " : "blend", m.step, m.dip, m.swell, m.truePeak, m.limiterSeconds, m.preLUFS, m.postLUFS, m.lowOverlapShare, m.bassHoleBeats, m.shape))
    if index % packEvery == 0, packed < packCount {
        packed += 1
        let name = String(format: "%02d-%@", packed, build)
        try writeM4A(mix.left, mix.right, from: max(0, fadeStart - 16 * beat), to: min(mix.total, fadeEnd + 16 * beat), url: packDirectory.appendingPathComponent("\(name).m4a"))
        try "\(name) \(m.out) -> \(m.inc) | \(pair.loop ? "loop mix" : "blend \(pair.blend) bars")\n".appendLine(to: packDirectory.appendingPathComponent("pack-\(build).txt"))
    }
    withExtendedLifetime((sa, sb)) {}
} }

extension String {
    func appendLine(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(utf8))
            try handle.close()
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

print("rendered \(metrics.count) pairs in \(Int(Date().timeIntervalSince(renderStart))) s")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(metrics).write(to: outputDirectory.appendingPathComponent("metrics-\(build).json"))

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}
func line(_ name: String, _ xs: [Double]) -> String {
    String(format: "%-22@ median %7.2f  p90 %7.2f  max %7.2f", name as NSString, percentile(xs, 0.5), percentile(xs, 0.9), xs.max() ?? 0)
}
var summary = "build \(build), \(metrics.count) pairs (\(metrics.filter(\.loop).count) loop mixes), seed \(seed)\n"
summary += line("abs step LU", metrics.map { abs($0.step) }) + "\n"
summary += line("step LU", metrics.map(\.step)) + "\n"
summary += line("dip LU", metrics.map(\.dip)) + "\n"
summary += line("swell LU", metrics.map(\.swell)) + "\n"
summary += line("true peak dBTP", metrics.map(\.truePeak)) + "\n"
summary += line("limiter >0.5 dB s", metrics.map(\.limiterSeconds)) + "\n"
summary += line("limiter >2 dB s", metrics.map(\.limiterDeepSeconds)) + "\n"
summary += line("limiter deepest dB", metrics.map { -$0.limiterMaxDB }) + "\n"
summary += line("pre-limit LUFS", metrics.map(\.preLUFS)) + "\n"
summary += line("post-limit LUFS", metrics.map(\.postLUFS)) + "\n"
summary += line("low overlap share", metrics.map(\.lowOverlapShare)) + "\n"
summary += line("low overlap s", metrics.map(\.lowOverlapSeconds)) + "\n"
summary += line("bass hole beats", metrics.map { Double($0.bassHoleBeats) }) + "\n"
summary += "gates: |step|<=1 LU \(metrics.filter { abs($0.step) <= 1 }.count)/\(metrics.count), dip<=1.5 \(metrics.filter { $0.dip <= 1.5 }.count), swell<=3 \(metrics.filter { $0.swell <= 3 }.count), tp<=-1 \(metrics.filter { $0.truePeak <= -0.95 }.count), bass holes 0 \(metrics.filter { $0.bassHoleBeats == 0 }.count)\n"
print(summary)
try summary.write(to: outputDirectory.appendingPathComponent("summary-\(build).txt"), atomically: true, encoding: .utf8)
