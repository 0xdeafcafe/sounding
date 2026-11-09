import Foundation
import AVFoundation

let sr = DJEngineConstants.canonicalSampleRate
var failures = 0
var passes = 0

func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passes += 1
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label) \(detail())")
    }
}

func fixture(_ name: String, seconds: Double, tones: [(Double, Float)]) throws -> URL {
    let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    let url = directory.appendingPathComponent("\(name).caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let frames = Int(seconds * sr)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        var value: Float = 0
        for (hertz, amplitude) in tones {
            value += amplitude * Float(sin(2 * Double.pi * hertz * Double(i) / sr))
        }
        buffer.floatChannelData![0][i] = value
        buffer.floatChannelData![1][i] = value
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}

final class Rig {
    let core = MixRenderCore(sampleRate: sr)
    var sources: [MixSource] = []
    var seq: Int64 = 0

    init(a: URL?, b: URL?) throws {
        core.phonesRequested = true
        for (index, url) in [a, b].enumerated() {
            guard let url else { continue }
            let source = try MixSource(url: url, synchronous: true)
            sources.append(source)
            push { .load(seq: $0, deck: index, source: Unmanaged.passUnretained(source)) }
            push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .start(deck: index, fromFrame: 0)) }
        }
    }

    func push(_ make: (Int64) -> MixCommand) {
        seq += 1
        _ = core.ring.push(make(seq))
    }

    func set(_ parameter: MixParameter, _ value: Double) {
        push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .ramp(parameter, to: value, frames: 0, curve: .linear)) }
    }

    func fx(_ deck: Int, kind: MixFXKind?, period: Double = 0.25, feedback: Double = 0.5) {
        push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .deckFX(deck: deck, kind: kind?.rawValue ?? 0, periodSeconds: period, feedback: feedback)) }
    }

    struct Output {
        var left: [Float] = []
        var right: [Float] = []
        var phonesLeft: [Float] = []
        var phonesRight: [Float] = []
    }

    func render(seconds: Double, block: Int = 512) -> Output {
        let total = Int(seconds * sr)
        var out = Output()
        out.left.reserveCapacity(total)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let pl = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let pr = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { [l, r, pl, pr].forEach { $0.deallocate() } }
        var done = 0
        while done < total {
            let n = min(block, total - done)
            core.render(frames: n, left: l, right: r, phonesLeft: pl, phonesRight: pr)
            out.left.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
            out.right.append(contentsOf: UnsafeBufferPointer(start: r, count: n))
            out.phonesLeft.append(contentsOf: UnsafeBufferPointer(start: pl, count: n))
            out.phonesRight.append(contentsOf: UnsafeBufferPointer(start: pr, count: n))
            done += n
        }
        return out
    }
}

func tone(_ x: [Float], _ hertz: Double, skip: Int = 4096) -> Double {
    guard x.count > skip + 1024 else { return 0 }
    let slice = x[skip...]
    let w = 2 * Double.pi * hertz / sr
    var re = 0.0
    var im = 0.0
    for (k, v) in slice.enumerated() {
        re += Double(v) * cos(w * Double(k))
        im += Double(v) * sin(w * Double(k))
    }
    return 2 * (re * re + im * im).squareRoot() / Double(slice.count)
}

func maxStep(_ x: [Float], from: Int = 1) -> Float {
    var m: Float = 0
    for i in max(1, from)..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
    return m
}

func clickRatio(_ x: [Float]) -> Float {
    guard x.count > 4096 else { return 0 }
    var curvature: [Float] = []
    curvature.reserveCapacity(x.count)
    for i in 2..<x.count { curvature.append(abs(x[i] - 2 * x[i - 1] + x[i - 2])) }
    let window = 256
    var worst: Float = 0
    var start = 0
    while start + window * 3 <= curvature.count {
        let before = curvature[start..<(start + window)].max() ?? 0
        let middle = curvature[(start + window)..<(start + 2 * window)].max() ?? 0
        let after = curvature[(start + 2 * window)..<(start + 3 * window)].max() ?? 0
        let context = max(before, after, 1e-4)
        worst = max(worst, middle / context)
        start += window
    }
    return worst
}

func peak(_ x: [Float], from: Int = 0) -> Float {
    x[from...].reduce(0) { max($0, abs($1)) }
}

let lowTone = 440.0
let highTone = 1_000.0
let a = try fixture("deck-a", seconds: 6, tones: [(lowTone, 0.5)])
let b = try fixture("deck-b", seconds: 6, tones: [(highTone, 0.5)])
let bass = try fixture("bass", seconds: 4, tones: [(60, 0.5)])

do {
    let rig = try Rig(a: a, b: b)
    rig.set(.crossfade, 0.5)
    rig.set(.gain(0), 0)
    rig.set(.gain(1), 1)
    rig.set(.cue(0), 1)
    rig.set(.cueMix, 0)
    rig.set(.phonesLevel, 1)
    let out = rig.render(seconds: 1)
    let phonesA = tone(out.phonesLeft, lowTone)
    let phonesB = tone(out.phonesLeft, highTone)
    let masterA = tone(out.left, lowTone)
    let masterB = tone(out.left, highTone)
    expect(abs(phonesA - 0.5) < 0.03, "cue: deck A is in the phones pre-fader", "A=\(phonesA)")
    expect(phonesB < 0.005, "cue: uncued deck B stays out of the phones", "B=\(phonesB)")
    expect(masterA < 0.005, "cue: fader-down deck A stays out of the master", "A=\(masterA)")
    expect(masterB > 0.2, "cue: deck B plays on the master", "B=\(masterB)")
}

do {
    let rig = try Rig(a: a, b: b)
    rig.set(.crossfade, 0.5)
    rig.set(.gain(0), 0)
    rig.set(.cue(0), 1)
    rig.set(.cueMix, 1)
    rig.set(.phonesLevel, 1)
    let out = rig.render(seconds: 1)
    let phonesA = tone(out.phonesLeft, lowTone)
    let phonesB = tone(out.phonesLeft, highTone)
    let masterB = tone(out.left, highTone)
    expect(phonesA < 0.005, "cue mix at Master: cue is gone from the phones", "A=\(phonesA)")
    expect(abs(phonesB - masterB) < 0.01, "cue mix at Master: phones follow the master", "phones=\(phonesB) master=\(masterB)")
}

do {
    let rig = try Rig(a: a, b: b)
    rig.set(.crossfade, 0.5)
    rig.set(.gain(0), 0)
    rig.set(.cue(0), 1)
    rig.set(.cueMix, 0.5)
    rig.set(.phonesLevel, 1)
    rig.set(.splitCue, 1)
    let out = rig.render(seconds: 1)
    let leftA = tone(out.phonesLeft, lowTone)
    let leftB = tone(out.phonesLeft, highTone)
    let rightA = tone(out.phonesRight, lowTone)
    let rightB = tone(out.phonesRight, highTone)
    expect(leftA > 0.4 && leftB < 0.005, "split cue: left ear is the cue only", "A=\(leftA) B=\(leftB)")
    expect(rightB > 0.2 && rightA < 0.005, "split cue: right ear is the master only", "A=\(rightA) B=\(rightB)")
}

do {
    let rig = try Rig(a: a, b: b)
    rig.set(.cue(0), 1)
    rig.set(.cueMix, 0)
    rig.set(.phonesLevel, 0.5)
    let out = rig.render(seconds: 1)
    let level = tone(out.phonesLeft, lowTone)
    expect(abs(level - 0.25) < 0.02, "phones level scales the phones only", "A=\(level)")
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.set(.crossfade, 0)
    _ = rig.render(seconds: 0.5)
    _ = rig.core.meters.take(.deckA)
    _ = rig.core.meters.take(.master)
    _ = rig.render(seconds: 0.6)
    let deck = rig.core.meters.take(.deckA)
    let master = rig.core.meters.take(.master)
    let silent = rig.core.meters.take(.deckB)
    expect(abs(deck.peak - 0.5) < 0.01, "meter: deck A peak reads the 0.5 sine", "peak=\(deck.peak)")
    expect(abs(deck.rms - 0.3536) < 0.02, "meter: deck A RMS reads the 0.5 sine", "rms=\(deck.rms)")
    expect(deck.clips == 0 && master.clips == 0, "meter: no clip at -6 dBFS", "deck=\(deck.clips) master=\(master.clips)")
    expect(master.peak > 0.45, "meter: master sees deck A", "peak=\(master.peak)")
    expect(silent.peak == 0 && silent.rms == 0, "meter: idle deck B reads silence")
    let again = rig.core.meters.take(.deckA)
    expect(again.peak == 0, "meter: peak resets after each read")
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.set(.crossfade, 0)
    rig.set(.inputGain(0), 9)
    _ = rig.render(seconds: 0.5)
    let deck = rig.core.meters.take(.deckA)
    let master = rig.core.meters.take(.master)
    expect(deck.clips > 0, "clip: +9 dB trim clips the channel", "peak=\(deck.peak)")
    expect(master.clips > 0, "clip: master flags the overload before the limiter", "peak=\(master.peak)")
    rig.set(.master, 0.3)
    _ = rig.render(seconds: 0.2)
    _ = rig.core.meters.take(.master)
    let out = rig.render(seconds: 0.5)
    let quieter = rig.core.meters.take(.master)
    expect(quieter.clips == 0, "clip: master level below 0 dBFS clears the clip", "peak=\(quieter.peak)")
    expect(peak(out.left) < 1, "clip: output never exceeds full scale")
}

do {
    let rig = try Rig(a: bass, b: nil)
    rig.set(.crossfade, 0)
    rig.set(.eqLow(0), MixEngine.bassKillDecibels)
    let out = rig.render(seconds: 1)
    let level = tone(out.left, 60, skip: 8192)
    expect(level < 0.02, "EQ: low kill removes a 60 Hz tone", "level=\(level)")
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.set(.crossfade, 0)
    rig.set(.inputGain(0), -6)
    let out = rig.render(seconds: 1)
    let level = tone(out.left, lowTone)
    expect(abs(level - 0.25) < 0.02, "trim: -6 dB halves the deck", "level=\(level)")
}

do {
    expect(abs(MixRenderCore.crossfaderGain(side: 0.1, shape: 1) - 1) < 1e-9, "crossfader: cut curve is open after a sliver")
    expect(MixRenderCore.crossfaderGain(side: 0, shape: 1) == 0, "crossfader: cut curve is shut at the far end")
    let rig = try Rig(a: a, b: nil)
    rig.set(.crossfaderShape, 1)
    rig.set(.crossfade, 0.95)
    let out = rig.render(seconds: 0.5)
    expect(tone(out.left, lowTone) > 0.45, "crossfader: cut curve keeps deck A at full near the B end")
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.set(.crossfade, 0)
    let baseline = rig.render(seconds: 0.3)
    let reference = maxStep(baseline.left, from: 2048)
    rig.fx(0, kind: .echo, period: 0.25)
    rig.set(.fxWet(0), 0.8)
    rig.set(.fxSend(0), 1)
    let on = rig.render(seconds: 1.2)
    rig.set(.fxSend(0), 0)
    let off = rig.render(seconds: 0.6)
    rig.fx(0, kind: .filter, period: 0.5)
    rig.set(.fxSend(0), 1)
    let filter = rig.render(seconds: 1.5)
    rig.fx(0, kind: .reverb)
    let reverb = rig.render(seconds: 1)
    rig.set(.fxWet(0), 0)
    let dry = rig.render(seconds: 0.5)
    let echoLevel = peak(on.left, from: Int(0.5 * sr))
    expect(echoLevel > 0.6, "FX echo: the echo adds a repeat", "peak=\(echoLevel)")
    for (name, chunk) in [("echo on", on), ("echo off", off), ("filter", filter), ("reverb switch", reverb), ("wet to zero", dry)] {
        let spike = clickRatio(chunk.left)
        let step = maxStep(chunk.left)
        expect(spike < 4 && step < reference * 2.2, "FX click-free: \(name)", "ratio=\(spike) step=\(step) sine step=\(reference)")
    }
    let tail = rms(Array(off.left[Int(0.1 * sr)..<Int(0.3 * sr)])) - rms(Array(baseline.left[2048...]))
    expect(tail > 0.01, "FX echo: switching off lets the tail ring out", "extra=\(tail)")
    let filtered = tone(Array(filter.left[Int(0.5 * sr)...]), lowTone, skip: 0)
    expect(filtered < 0.49, "FX filter: the sweep cuts deck A", "level=\(filtered)")
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.set(.cueMix, 0)
    rig.set(.phonesLevel, 1)
    let before = rig.render(seconds: 0.2)
    rig.set(.cue(0), 1)
    let on = rig.render(seconds: 0.2)
    rig.set(.splitCue, 1)
    let split = rig.render(seconds: 0.2)
    rig.set(.cue(0), 0)
    let off = rig.render(seconds: 0.2)
    let sine = Float(0.5 * 2 * Double.pi * lowTone / sr)
    let worst = [before, on, split, off].map { maxStep($0.phonesLeft) }.max() ?? 0
    expect(worst < sine * 1.1, "cue: switching cue and split cue is click-free", "step=\(worst) sine=\(sine)")
}

do {
    let preview = try Rig(a: nil, b: b)
    preview.set(.crossfade, 1)
    let slot = MixPhonesPreviewSlot()
    slot.attach(preview.core, level: 0.5, split: false)
    let n = 2048
    let l = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let sl = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let sr2 = UnsafeMutablePointer<Float>.allocate(capacity: n)
    defer { [l, r, sl, sr2].forEach { $0.deallocate() } }
    var phones: [Float] = []
    for _ in 0..<40 {
        l.initialize(repeating: 0, count: n)
        r.initialize(repeating: 0, count: n)
        slot.mix(into: l, r, scratchLeft: sl, scratchRight: sr2, frames: n)
        phones.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
    }
    let level = tone(phones, highTone)
    expect(abs(level - 0.25) < 0.03, "plan preview: the previewed mix plays in the phones at the phones level", "level=\(level)")
    slot.attach(nil, level: 0, split: false)
    l.initialize(repeating: 0, count: n)
    slot.mix(into: l, r, scratchLeft: sl, scratchRight: sr2, frames: n)
    expect(peak(Array(UnsafeBufferPointer(start: l, count: n))) == 0, "plan preview: stopping clears the phones")
}

func rms(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

do {
    let rig = try Rig(a: a, b: nil)
    rig.core.phonesRequested = false
    rig.set(.cue(0), 1)
    rig.core.phonesActive.store(true, ordering: .relaxed)
    _ = rig.render(seconds: 0.05)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    defer { l.deallocate(); r.deallocate() }
    let read = rig.core.phonesRing.read(left: l, right: r, frames: 1024, target: 2048)
    var energy: Float = 0
    for n in 0..<read { energy += l[n] * l[n] }
    expect(read == 1024 && energy > 0, "phones ring: the cue reaches the phones output", "read=\(read)")
    _ = rig.render(seconds: 0.5)
    _ = rig.core.phonesRing.read(left: l, right: r, frames: 512, target: 2048)
    expect(rig.core.phonesRing.available <= 2048, "phones ring: drift is trimmed to the target latency", "available=\(rig.core.phonesRing.available)")
}

do {
    var meter = DJMeterBallistics()
    meter.update(MixMeterReading(peak: 0.9, rms: 0.5, clips: 0), at: 0)
    meter.update(MixMeterReading(peak: 0.1, rms: 0.05, clips: 0), at: 1)
    expect(meter.heldPeak == 0.9, "ballistics: peak holds for 1.5 s")
    meter.update(MixMeterReading(peak: 0.1, rms: 0.05, clips: 0), at: 2)
    expect(meter.heldPeak < 0.9, "ballistics: held peak falls after the hold")
    meter.update(MixMeterReading(peak: 1, rms: 0.7, clips: 3), at: 3)
    expect(meter.isClipping, "ballistics: clip latches")
    meter.update(MixMeterReading(peak: 0.1, rms: 0.05, clips: 0), at: 5.5)
    expect(!meter.isClipping, "ballistics: clip clears after 2 s")
}

if ProcessInfo.processInfo.environment["DJMIXER_DEVICE_TEST"] == "1" {
    await MainActor.run {
        let core = MixRenderCore(sampleRate: sr)
        let output = MixPhonesOutput(core: core)
        print("      devices: \(output.devices.map { "\($0.name) (\($0.outputChannels) ch)" })")
        for device in output.devices {
            for pair in device.channelPairs.prefix(2) {
                output.select(MixPhonesRoute(deviceUID: device.uid, channelPair: pair))
                output.start()
                let ok = output.isRunning && output.failure == nil && core.phonesActive.load(ordering: .relaxed)
                expect(ok, "phones output opens \(device.name) \(MixOutputDevice.pairLabel(pair)) (silent)", output.failure ?? "")
                output.stop()
            }
        }
        output.select(nil)
    }
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
