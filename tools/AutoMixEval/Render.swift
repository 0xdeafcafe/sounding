import AVFoundation
import Accelerate
import Foundation

let sr = 44_100.0

func readAudio(_ url: URL) throws -> (left: [Float], right: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let n = Int(buffer.frameLength)
    let l = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
    let r = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)) : l
    return (l, r)
}

func freeBytes(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    return Int64(values?.volumeAvailableCapacity ?? 0)
}

func writeAudio(_ left: [Float], _ right: [Float], base: URL) throws -> URL? {
    let free = freeBytes(base.deletingLastPathComponent())
    if free > 1_500_000_000 {
        let url = base.appendingPathExtension("wav")
        try writeWav(left, right, to: url)
        return url
    }
    guard free > 150_000_000 else { return nil }
    let url = base.appendingPathExtension("m4a")
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = AVAudioFrameCount(left.count)
    for i in 0..<left.count {
        buffer.floatChannelData![0][i] = left[i]
        buffer.floatChannelData![1][i] = right[i]
    }
    try file.write(from: buffer)
    return url
}

func writeWav(_ left: [Float], _ right: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = AVAudioFrameCount(left.count)
    for i in 0..<left.count {
        buffer.floatChannelData![0][i] = left[i]
        buffer.floatChannelData![1][i] = right[i]
    }
    try file.write(from: buffer)
}

struct Pass {
    var left: [Float]
    var right: [Float]
    var length: Double
    var phaseLock: Bool
}

func renderPass(outURL: URL, inURL: URL, plan: Plan, mods: Mods, lead: Double, tail: Double, mute: Int? = nil) throws -> Pass {
    let core = MixRenderCore(sampleRate: sr)
    let a = try MixSource(url: outURL, synchronous: true)
    let b = try MixSource(url: inURL, synchronous: true)
    var seq: Int64 = 0
    func push(_ make: (Int64) -> MixCommand) {
        seq += 1
        _ = core.ring.push(make(seq))
    }
    push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(a)) }
    push { .load(seq: $0, deck: 1, source: Unmanaged.passUnretained(b)) }
    var tables: [MixBeatTable] = []
    for (deck, grid) in [(0, plan.outgoingBeatGrid), (1, plan.incomingBeatGrid)] {
        if let grid, let table = MixBeatTable(grid: grid, sampleRate: sr) {
            tables.append(table)
            push { .beats(seq: $0, deck: deck, table: Unmanaged.passUnretained(table)) }
        }
    }
    func now(_ action: MixTimelineAction) { push { .event(seq: $0, time: 0, immediate: true, group: 0, action: action) } }
    now(.ramp(.crossfade, to: 0, frames: 0, curve: .linear))
    if !mods.killBassSwap { now(.ramp(.eqLow(1), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear)) }
    if plan.accent == .incomingFilterOpen { now(.ramp(.lowPass(1), to: DJEngineConstants.accentClosedFilterHz, frames: 0, curve: .linear)) }
    now(.ramp(.rate(1), to: plan.incomingRateRatio, frames: 0, curve: .linear))
    if mods.incomingGain != 1 { now(.ramp(.gain(1), to: mods.incomingGain, frames: 0, curve: .linear)) }
    if let mute { now(.ramp(.gain(mute), to: 0, frames: 0, curve: .linear)) }
    let start = max(0, plan.mixPointSeconds - lead)
    now(.start(deck: 0, fromFrame: start * sr))
    let phaseLock = !mods.noPhaseLock && (plan.outgoingBeatGrid?.isPhaseVerified ?? false) && (plan.incomingBeatGrid?.isPhaseVerified ?? false) && plan.templateId != DJTemplates.cutOnTheOne
    let input = MixTransitionTimelineInput(
        outgoing: 0, incoming: 1, sampleRate: sr, anchorSourceSeconds: plan.mixPointSeconds,
        window: max(0.15, plan.transitionSeconds), entrySeconds: plan.entrySeconds,
        outgoingRate: 1, incomingRate: plan.incomingRateRatio,
        outgoingGrid: plan.outgoingBeatGrid, incomingGrid: plan.incomingBeatGrid,
        stages: plan.stages, bassSwapAtSeconds: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds,
        filterAccent: plan.accent, defersIncomingStart: false, phaseLock: phaseLock, move: plan.move,
        riserGain: 0, incomingMidCutDecibels: plan.incomingMidCutDecibels
    )
    let timeline = MixTimeline.transition(input)
    for event in timeline.events {
        if mods.killBassSwap, case .ramp(let p, _, _, _) = event.action, p == .eqLow(0) || p == .eqLow(1) { continue }
        push { .event(seq: $0, time: event.offset, immediate: false, group: 7, action: event.action) }
    }
    push { .anchor(seq: $0, group: 7, anchor: timeline.anchor) }
    let length = Double(timeline.lengthFrames) / sr
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
    withExtendedLifetime((a, b, tables)) {}
    return Pass(left: left, right: right, length: length, phaseLock: phaseLock)
}

func biquadLowPass(_ x: [Float], cutoff: Double) -> [Float] {
    let w = tan(.pi * cutoff / sr)
    let q = 1 / sqrt(2.0)
    let norm = 1 / (1 + w / q + w * w)
    let b0 = Float(w * w * norm), b1 = 2 * b0, b2 = b0
    let a1 = Float(2 * (w * w - 1) * norm), a2 = Float((1 - w / q + w * w) * norm)
    var y = x
    for _ in 0..<2 {
        let input = y
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let v = b0 * input[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input[i]; y2 = y1; y1 = v
            out[i] = v
        }
        y = out
    }
    return y
}

func rmsDB(_ x: [Float], _ lo: Int, _ hi: Int) -> Double {
    let a = max(0, lo), b = min(x.count, hi)
    guard b > a else { return -120 }
    var s: Double = 0
    for i in a..<b { s += Double(x[i] * x[i]) }
    return 10 * log10(max(1e-12, s / Double(b - a)))
}

func d2Max(_ x: [Float], _ lo: Int, _ hi: Int) -> Float {
    var m: Float = 0
    let a = max(2, lo), b = min(x.count, hi)
    guard b > a else { return 0 }
    for i in a..<b { m = max(m, abs(x[i] - 2 * x[i - 1] + x[i - 2])) }
    return m
}

func bands(_ x: [Float], columns: Int) -> [(Float, Float, Float)] {
    let n = 2048
    let log2n = vDSP_Length(11)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    let lowEdge = Int(250 / sr * Double(n)), midEdge = Int(2500 / sr * Double(n))
    var out: [(Float, Float, Float)] = []
    for c in 0..<columns {
        let center = (c * x.count + x.count / 2) / columns
        let s = max(0, min(x.count - n, center - n / 2))
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n where s + i < x.count { frame[i] = x[s + i] * window[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        var lo: Float = 0, mid: Float = 0, hi: Float = 0
        for i in 1..<n / 2 {
            if i < lowEdge { lo += mags[i] } else if i < midEdge { mid += mags[i] } else { hi += mags[i] }
        }
        out.append((sqrt(lo), sqrt(mid), sqrt(hi)))
    }
    return out
}

struct Metrics: Codable {
    var transitionSeconds: Double
    var clipSeconds: Double
    var mixStartInClip: Double
    var mixEndInClip: Double
    var phaseLock: Bool
    var rate: Double
    var energyStepDB: Double
    var maxLevelJumpDB: Double
    var vocalOverlapSeconds: Double
    var vocalUnderBlendSeconds: Double
    var plannedVocalOverlapSeconds: Double
    var phaseErrorMs: Double?
    var phaseCorrelation: Double?
    var doubleBassSeconds: Double
    var clicks: Int
    var peakDBFS: Double
    var incomingEntryRMSDB: Double
    var incomingEntryBeatLed: Bool?
    var payoffOverlapSeconds: Double
    var exitOnPhrase: Bool
    var entryOnDownbeat: Bool
    var dropsLeftAfterExit: Int
}

struct Analysis {
    var metrics: Metrics
    var mixL: [Float]
    var mixR: [Float]
    var outStem: [Float]
    var inStem: [Float]
    var outDry: [Float]
    var inDry: [Float]
    var outLow: [Float]
    var inLow: [Float]
    var mixMono: [Float]
    var clipStartRender: Double
    var lead: Double
    var outVocals: [ClosedRange<Double>]
    var inVocals: [ClosedRange<Double>]
    var outDownbeats: [Double]
    var inDownbeats: [Double]
    var outPhrases: [Double]
    var inPhrases: [Double]
    var beatPeriod: Double
}

func analyse(_ c: EvalCase, out o: Track, in i: Track) throws -> Analysis {
    let lead = 20.0, tail = 20.0
    let mix = try renderPass(outURL: o.url, inURL: i.url, plan: c.plan, mods: c.mods, lead: lead, tail: tail)
    let outOnly = try renderPass(outURL: o.url, inURL: i.url, plan: c.plan, mods: c.mods, lead: lead, tail: tail, mute: 1)
    let inOnly = try renderPass(outURL: o.url, inURL: i.url, plan: c.plan, mods: c.mods, lead: lead, tail: tail, mute: 0)
    let length = mix.length
    let spare = 36 - length
    let pre = spare >= 8 ? spare / 2 : 4
    let post = spare >= 8 ? spare / 2 : 4
    let clipStart = lead - pre
    let clipEnd = min(lead + length + post, lead + length + tail)
    let lo = Int(clipStart * sr), hi = min(mix.left.count, Int(clipEnd * sr))
    let mixL = Array(mix.left[lo..<hi]), mixR = Array(mix.right[lo..<hi])
    let mono = zip(mixL, mixR).map { ($0 + $1) / 2 }
    let outStem = (lo..<hi).map { (outOnly.left[$0] + outOnly.right[$0]) / 2 }
    let inStem = (lo..<hi).map { (inOnly.left[$0] + inOnly.right[$0]) / 2 }
    let n = mono.count
    let renderStartSource = max(0, c.plan.mixPointSeconds - lead)
    let rate = c.plan.incomingRateRatio
    func outSource(_ clipT: Double) -> Double { renderStartSource + clipStart + clipT }
    func inSource(_ clipT: Double) -> Double { c.plan.entrySeconds + (clipStart + clipT - lead) * rate }
    let outDry = (0..<n).map { k -> Float in
        let j = Int(outSource(Double(k) / sr) * sr)
        return j >= 0 && j < o.mono.count ? o.mono[j] : 0
    }
    let inDry = (0..<n).map { k -> Float in
        let t = Double(k) / sr
        guard clipStart + t >= lead else { return 0 }
        let j = Int(inSource(t) * sr)
        return j >= 0 && j < i.mono.count ? i.mono[j] : 0
    }
    let mixStart = pre
    let mixEnd = pre + length
    func f(_ t: Double) -> Int { max(0, min(n, Int(t * sr))) }

    let before = rmsDB(mono, f(max(0, mixStart - 6)), f(mixStart))
    let after = rmsDB(mono, f(mixEnd), f(min(Double(n) / sr, mixEnd + 6)))
    var jump = 0.0
    var t = max(0, mixStart - 2)
    while t + 2 <= min(Double(n) / sr, mixEnd + 2) {
        jump = max(jump, abs(rmsDB(mono, f(t + 1), f(t + 2)) - rmsDB(mono, f(t), f(t + 1))))
        t += 0.25
    }

    let outLow = biquadLowPass(outStem, cutoff: 120)
    let inLow = biquadLowPass(inStem, cutoff: 120)
    var doubleBass = 0.0
    var vocal = 0.0
    var under = 0.0
    let block = Int(0.1 * sr)
    let outVocals = o.features.vocalRanges.map { ($0.lowerBound - renderStartSource - clipStart)...($0.upperBound - renderStartSource - clipStart) }
    let inVocals = i.features.vocalRanges.map { (($0.lowerBound - c.plan.entrySeconds) / rate + lead - clipStart)...(($0.upperBound - c.plan.entrySeconds) / rate + lead - clipStart) }
    var k = 0
    while k + block <= n {
        let tc = Double(k + block / 2) / sr
        if rmsDB(outLow, k, k + block) > -28, rmsDB(inLow, k, k + block) > -28 { doubleBass += 0.1 }
        if rmsDB(outStem, k, k + block) > -30, rmsDB(inStem, k, k + block) > -30 {
            let ov = outVocals.contains { $0.contains(tc) }, iv = inVocals.contains { $0.contains(tc) }
            if ov && iv { vocal += 0.1 }
            if ov || iv { under += 0.1 }
        }
        k += block
    }

    var phase: Double?
    var corr: Double?
    let env = 44
    func onset(_ x: [Float]) -> [Double] {
        var e: [Double] = []
        var j = 0
        while j + env <= x.count {
            var s: Double = 0
            for q in j..<(j + env) { s += Double(abs(x[q])) }
            e.append(s / Double(env))
            j += env
        }
        return e.indices.map { $0 == 0 ? 0 : max(0, e[$0] - e[$0 - 1]) }
    }
    if length > 2 {
        let oe = onset(outStem), ie = onset(inStem)
        var active: [Int] = []
        var q = 0
        while q + block <= n {
            if rmsDB(outStem, q, q + block) > -36, rmsDB(inStem, q, q + block) > -36 { active.append(q / env) }
            q += block
        }
        if active.count >= 20 {
            let maxLag = Int(min(0.12, (o.features.beatGrid?.beatPeriod ?? 0.5) * 0.4) * 1000)
            var best = (lag: 0, score: -1.0)
            let span = block / env
            for lag in -maxLag...maxLag {
                var xy = 0.0, xx = 0.0, yy = 0.0
                for s in active {
                    for u in s..<(s + span) {
                        let v = u + lag
                        guard u >= 0, u < oe.count, v >= 0, v < ie.count else { continue }
                        xy += oe[u] * ie[v]; xx += oe[u] * oe[u]; yy += ie[v] * ie[v]
                    }
                }
                let cc = xy / max(1e-12, sqrt(xx * yy))
                if cc > best.score { best = (lag, cc) }
            }
            phase = Double(best.lag) * Double(env) / sr * 1000
            corr = best.score
        }
    }

    let outCeil = d2Max(outDry, 0, n)
    let inCeil = d2Max(i.mono, Int(c.plan.entrySeconds * sr), Int((c.plan.entrySeconds + 40) * sr))
    let ceiling = (outCeil + inCeil) * 1.1
    var clicks = 0
    var q = f(mixStart - 0.2)
    let stop = f(mixEnd + 0.5)
    let cb = Int(0.005 * sr)
    while q + cb <= stop {
        if d2Max(mono, q, q + cb) > ceiling { clicks += 1; q += Int(0.05 * sr) } else { q += cb }
    }
    var peak: Float = 0
    for v in mixL { peak = max(peak, abs(v)) }
    for v in mixR { peak = max(peak, abs(v)) }

    let entryRMS = rmsDB(i.mono, Int(c.plan.entrySeconds * sr), Int((c.plan.entrySeconds + 4) * sr))
    let beatLed = DJMoveRails.beatLedBars(i.features).map { $0[min($0.count - 1, barAt(i, c.plan.entrySeconds))] }
    let runs = DJMoveRails.payoffRuns(o.features).map { downbeat(o, $0.lowerBound)...downbeat(o, $0.upperBound) }
    let exitWindow = c.plan.mixPointSeconds...(c.plan.mixPointSeconds + max(0.01, c.plan.transitionSeconds))
    var payoff = 0.0
    for r in runs { payoff += max(0, min(r.upperBound, exitWindow.upperBound) - max(r.lowerBound, exitWindow.lowerBound)) }
    if c.plan.transitionSeconds < 1, runs.contains(where: { $0.contains(c.plan.mixPointSeconds) && $0.lowerBound < c.plan.mixPointSeconds - 1 }) { payoff = max(payoff, 1) }
    let dropsLeft = runs.filter { $0.lowerBound > exitWindow.upperBound }.count
    let onPhrase = o.result.phraseStarts.contains { abs($0 - c.plan.mixPointSeconds) < 0.05 }
    let onDownbeat = i.result.downbeats.contains { abs($0 - c.plan.entrySeconds) < 0.02 }
    let planned = DJMixRules.vocalOverlapSeconds(outgoing: o.features.vocalRanges, from: c.plan.mixPointSeconds, length: c.plan.transitionSeconds, incoming: i.features.vocalRanges, entry: c.plan.entrySeconds)

    let metrics = Metrics(
        transitionSeconds: length, clipSeconds: Double(n) / sr, mixStartInClip: mixStart, mixEndInClip: mixEnd,
        phaseLock: mix.phaseLock, rate: rate, energyStepDB: after - before, maxLevelJumpDB: jump,
        vocalOverlapSeconds: vocal, vocalUnderBlendSeconds: under, plannedVocalOverlapSeconds: planned, phaseErrorMs: phase, phaseCorrelation: corr,
        doubleBassSeconds: doubleBass, clicks: clicks, peakDBFS: 20 * log10(max(1e-9, Double(peak))),
        incomingEntryRMSDB: entryRMS, incomingEntryBeatLed: beatLed, payoffOverlapSeconds: payoff,
        exitOnPhrase: onPhrase, entryOnDownbeat: onDownbeat, dropsLeftAfterExit: dropsLeft
    )
    let outDown = o.result.downbeats.map { $0 - renderStartSource - clipStart }.filter { $0 >= 0 && $0 <= Double(n) / sr }
    let inDown = i.result.downbeats.map { ($0 - c.plan.entrySeconds) / rate + lead - clipStart }.filter { $0 >= mixStart - 0.01 && $0 <= Double(n) / sr }
    let outPh = o.result.phraseStarts.map { $0 - renderStartSource - clipStart }.filter { $0 >= 0 && $0 <= Double(n) / sr }
    let inPh = i.result.phraseStarts.map { ($0 - c.plan.entrySeconds) / rate + lead - clipStart }.filter { $0 >= mixStart - 0.01 && $0 <= Double(n) / sr }
    return Analysis(
        metrics: metrics, mixL: mixL, mixR: mixR, outStem: outStem, inStem: inStem, outDry: outDry, inDry: inDry,
        outLow: outLow, inLow: inLow, mixMono: mono, clipStartRender: clipStart, lead: lead,
        outVocals: outVocals, inVocals: inVocals, outDownbeats: outDown, inDownbeats: inDown, outPhrases: outPh, inPhrases: inPh,
        beatPeriod: o.features.beatGrid?.beatPeriod ?? 0.5
    )
}

struct Gate: Codable {
    var name: String
    var pass: Bool
    var value: Double?
    var limit: String
}

func gates(_ m: Metrics) -> [Gate] {
    [
        Gate(name: "vocal_overlap", pass: m.vocalOverlapSeconds <= 2 && m.vocalUnderBlendSeconds <= 4, value: m.vocalUnderBlendSeconds, limit: "<= 2 s of vocals on both decks and <= 4 s of either deck's vocals while both decks are audible"),
        Gate(name: "level_step", pass: abs(m.energyStepDB) <= DJMixRules.maxLevelStepDecibels, value: m.energyStepDB, limit: "|after - before| <= DJMixRules.maxLevelStepDecibels (6 dB)"),
        Gate(name: "clicks", pass: m.clicks == 0, value: Double(m.clicks), limit: "no second-difference spike above the dry sources' ceiling x1.1"),
        Gate(name: "true_peak", pass: m.peakDBFS <= -0.1, value: m.peakDBFS, limit: "sample peak <= -0.1 dBFS"),
        Gate(name: "payoff", pass: m.payoffOverlapSeconds <= 2, value: m.payoffOverlapSeconds, limit: "mix window overlaps an outgoing payoff run by <= 2 s (DJMoveRails.payoffRuns)"),
        Gate(name: "entry_energy", pass: m.incomingEntryRMSDB >= -30 && (m.incomingEntryBeatLed ?? true), value: m.incomingEntryRMSDB, limit: "incoming entry >= -30 dB RMS and beat-led (DJMoveRails.beatLedBars)"),
        Gate(name: "phase", pass: m.phaseErrorMs.map { abs($0) <= 15 } ?? true, value: m.phaseErrorMs, limit: "|kick onset lag| <= 15 ms during the overlap"),
        Gate(name: "double_bass", pass: m.doubleBassSeconds <= 2, value: m.doubleBassSeconds, limit: "<= 2 s with both decks' sub-120 Hz above -28 dBFS"),
        Gate(name: "grid", pass: m.exitOnPhrase && m.entryOnDownbeat, value: nil, limit: "exit on an outgoing phrase start, entry on an incoming downbeat")
    ]
}
