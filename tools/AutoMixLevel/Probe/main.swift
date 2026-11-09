import AVFoundation
import Foundation

let sr = 44_100.0
let args = CommandLine.arguments
let corpusFile = URL(fileURLWithPath: args.count > 1 ? args[1] : "tracks.tsv")
let cacheDirectory = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/automix-level-cache")
let scratch = URL(fileURLWithPath: args.count > 3 ? args[3] : "/tmp/automix-level-probe")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func tone(seconds: Double) throws -> URL {
    let url = scratch.appendingPathComponent("probe-tone.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = Int(seconds * sr)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    var state: UInt32 = 7
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        let noise = Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.1
        let v = 0.3 * Float(sin(2 * .pi * 110 * Double(i) / sr)) + noise
        buffer.floatChannelData![0][i] = v
        buffer.floatChannelData![1][i] = v
    }
    try file.write(from: buffer)
    return url
}

func run(restore: Bool) throws -> (MixDeckSnapshot, MixDeckSnapshot) {
    let core = MixRenderCore(sampleRate: sr)
    let source = try MixSource(url: try tone(seconds: 20), synchronous: true)
    var seq: Int64 = 0
    func push(_ c: (Int64) -> MixCommand) { seq += 1; _ = core.ring.push(c(seq)) }
    func now(_ a: MixTimelineAction, group: Int32 = 0) { push { .event(seq: $0, time: 0, immediate: true, group: group, action: a) } }
    push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(source)) }
    now(.ramp(.gain(0), to: 0.8, frames: 0, curve: .linear))
    now(.ramp(.eqHigh(0), to: -10, frames: 0, curve: .linear))
    push { .own(seq: $0, mask: UInt64(1) << UInt64(MixParameter.eqHigh(0).raw)) }
    now(.start(deck: 0, fromFrame: 0))
    let group: Int32 = 9
    let events: [(Int64, MixTimelineAction)] = [
        (0, .ramp(.highPass(0), to: 1_400, frames: Int64(4 * sr), curve: .logarithmic)),
        (0, .ramp(.resonance(0), to: 0.25, frames: Int64(4 * sr), curve: .linear)),
        (0, .ramp(.gain(0), to: 0.5, frames: Int64(4 * sr), curve: .linear)),
        (0, .ramp(.eqHigh(0), to: -30, frames: Int64(4 * sr), curve: .linear)),
        (0, .ramp(.echoSend(0), to: 0.5, frames: 0, curve: .linear)),
        (0, .loop(deck: 0, startFrame: 1 * sr, lengthFrames: 0.5 * sr)),
        (Int64(4 * sr), .clearLoop(deck: 0)),
        (Int64(4 * sr), .ramp(.highPass(0), to: 30, frames: 0, curve: .linear))
    ]
    for (t, a) in events { push { .event(seq: $0, time: t, immediate: false, group: group, action: a) } }
    push { .anchor(seq: $0, group: group, anchor: .deckPosition(deck: 0, frame: 1 * sr)) }
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { l.deallocate(); r.deallocate() }
    func render(_ seconds: Double) { for _ in 0..<Int(seconds * sr / 512) { core.render(frames: 512, left: l, right: r) } }
    render(3)
    let during = core.snapshot().a
    push { restore ? .restoreGroup(seq: $0, group: group) : .cancelGroup(seq: $0, group: group) }
    render(0.5)
    withExtendedLifetime(source) {}
    return (during, core.snapshot().a)
}

for restore in [false, true] {
    let (during, after) = try run(restore: restore)
    print(String(format: "%@ during: hp %.0f Hz res %.2f gain %.2f high %.1f send %.2f loop %.2f pos %.2f s | after: hp %.0f Hz res %.2f gain %.2f high %.1f send %.2f loop %.2f pos %.2f s",
                 restore ? "restore" : "cancel ", during.highPass, during.resonance, during.gain, during.high, during.echoSend, during.loopLength / sr, during.position / sr,
                 after.highPass, after.resonance, after.gain, after.high, after.echoSend, after.loopLength / sr, after.position / sr))
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
}

let cached = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
let paths = try String(contentsOf: corpusFile, encoding: .utf8).split(separator: "\n").compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}
var rng = SplitMix(state: 2026)
var seams = 0
var oldOver = 0, newOver = 0, oldBoostMax = 0.0, oldPeakGain = 0.0, newPeakGain = 0.0, oldAboveCeiling = 0, newAboveCeiling = 0
let ceiling = pow(10, -1.0 / 20)
print("cache files \(cached.count), corpus \(paths.count)")
for path in paths {
    guard let file = cached.first(where: { $0.lastPathComponent.hasPrefix("beats-\(fnv(path))-") }) else { continue }
    guard let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(BeatTrackerResult.self, from: data),
          result.downbeats.count > 40 else { print("unusable analysis \(file.lastPathComponent)"); continue }
    guard let source = try? MixSource(url: URL(fileURLWithPath: path), synchronous: true) else { print("no source \(path)"); continue }
    let deck = MixCoreDeck(index: 0, sampleRate: sr, capacity: 4096)
    deck.source = Unmanaged.passUnretained(source)
    deck.sourceFrames = source.frameCount
    for _ in 0..<20 {
        let k = 8 + Int(rng.next() % UInt64(result.downbeats.count - 16))
        let start = result.downbeats[k] * sr
        let end = result.downbeats[k + 4] * sr
        let fade = MixRenderCore.loopFade
        deck.measureFade(from: end, to: start, length: fade, step: 1)
        var sourcePeak = 0.0, oldPeak = 0.0, newPeak = 0.0
        for n in 0..<fade {
            let w = 0.5 - 0.5 * cos(Double.pi * Double(n) / Double(fade))
            let (ol, _) = deck.read(end + Double(n), integral: true)
            let (nl, _) = deck.read(start + Double(n), integral: true)
            let a = 1 - w
            let mixed = a * a * deck.fadeOldEnergy + w * w * deck.fadeNewEnergy + 2 * a * w * deck.fadeCross
            let target = a * deck.fadeOldEnergy + w * deck.fadeNewEnergy
            let oldGain = mixed > target * 0.25 ? min(2, (target / mixed).squareRoot()) : 2
            oldBoostMax = max(oldBoostMax, oldGain)
            let blend = ol + (nl - ol) * w
            let bound = max(abs(ol), abs(nl))
            sourcePeak = max(sourcePeak, bound)
            oldPeak = max(oldPeak, abs(blend * oldGain))
            newPeak = max(newPeak, min(bound, abs(blend * deck.fadeCompensation(w))))
        }
        seams += 1
        if oldPeak > sourcePeak * 1.0001 { oldOver += 1 }
        if newPeak > sourcePeak * 1.0001 { newOver += 1 }
        if oldPeak > ceiling, sourcePeak <= ceiling { oldAboveCeiling += 1 }
        if newPeak > ceiling, sourcePeak <= ceiling { newAboveCeiling += 1 }
        if sourcePeak > 1e-4 {
            oldPeakGain = max(oldPeakGain, oldPeak / sourcePeak)
            newPeakGain = max(newPeakGain, newPeak / sourcePeak)
        }
    }
    deck.source = nil
    withExtendedLifetime(source) {}
}
print(String(format: "seams %d: old gain max %.2f (%.1f dB); peaks above both sources old %d new %d; new limiter triggers (over -1 dBFS when sources were under) old %d new %d; worst peak gain old %.1f dB new %.1f dB",
             seams, oldBoostMax, 20 * log10(oldBoostMax), oldOver, newOver, oldAboveCeiling, newAboveCeiling, 20 * log10(max(1e-9, oldPeakGain)), 20 * log10(max(1e-9, newPeakGain))))
