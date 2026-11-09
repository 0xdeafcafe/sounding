#if DEBUG
import Foundation
import AVFoundation
@testable import SoundingTV

struct MixFixtureSpec: Hashable, Sendable {
    let id: String
    let duration: TimeInterval
    let bpmStart: Double
    let bpmEnd: Double
    let firstDownbeat: TimeInterval
    let pickupBeats: Int
    let keyPitchClass: Int
    let isMinor: Bool
    let introBars: Int
    let outroBars: Int
    let vocalBars: [ClosedRange<Int>]
    let breakdownBars: [ClosedRange<Int>]

    var signature: String {
        let vocals = vocalBars.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
        let breaks = breakdownBars.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
        return "v3|\(id)|\(duration)|\(bpmStart)|\(bpmEnd)|\(firstDownbeat)|\(pickupBeats)|\(keyPitchClass)|\(isMinor)|\(introBars)|\(outroBars)|\(vocals)|\(breaks)"
    }

    var camelot: CamelotKey { CamelotKey(pitchClass: keyPitchClass, isMinor: isMinor) }

    var keyName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[keyPitchClass] + (isMinor ? "m" : "")
    }

    var meanBPM: Double { (bpmStart + bpmEnd) / 2 }
}

struct MixFixtureTruth: Sendable {
    let spec: MixFixtureSpec
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    let barStarts: [TimeInterval]
    let vocalRanges: [ClosedRange<TimeInterval>]
    let bassRanges: [ClosedRange<TimeInterval>]
    let kickRanges: [ClosedRange<TimeInterval>]

    func bar(at seconds: TimeInterval) -> Int {
        var index = 0
        for (i, start) in barStarts.enumerated() where start <= seconds { index = i }
        return index
    }

    func nearestDownbeat(to seconds: TimeInterval) -> TimeInterval? {
        downbeats.min { abs($0 - seconds) < abs($1 - seconds) }
    }

    func localBeatPeriod(at seconds: TimeInterval) -> Double {
        guard beats.count >= 2 else { return 60 / spec.meanBPM }
        var index = beats.firstIndex { $0 >= seconds } ?? beats.count - 1
        index = min(max(1, index), beats.count - 1)
        return beats[index] - beats[index - 1]
    }

    static func make(_ spec: MixFixtureSpec) -> MixFixtureTruth {
        var beats: [TimeInterval] = []
        let startPeriod = 60 / spec.bpmStart
        var t = spec.firstDownbeat - Double(spec.pickupBeats) * startPeriod
        let estimatedBeats = Int(spec.duration / (60 / max(spec.bpmStart, spec.bpmEnd))) + 8
        var i = 0
        while t < spec.duration - 0.05 {
            if t >= 0 { beats.append(t) }
            let progress = Double(i) / Double(max(1, estimatedBeats))
            let bpm = spec.bpmStart + (spec.bpmEnd - spec.bpmStart) * min(1, progress)
            t += 60 / bpm
            i += 1
        }
        let firstDownbeatIndex = beats.firstIndex { abs($0 - spec.firstDownbeat) < 1e-6 } ?? 0
        var downbeats: [TimeInterval] = []
        var index = firstDownbeatIndex
        while index < beats.count {
            downbeats.append(beats[index])
            index += 4
        }
        let totalBars = downbeats.count
        func seconds(forBar bar: Int) -> TimeInterval {
            if bar < downbeats.count { return downbeats[bar] }
            return spec.duration
        }
        func range(_ bars: ClosedRange<Int>) -> ClosedRange<TimeInterval>? {
            let lower = max(0, min(bars.lowerBound, totalBars))
            let upper = max(lower, min(bars.upperBound + 1, totalBars))
            guard upper > lower else { return nil }
            return seconds(forBar: lower)...seconds(forBar: upper)
        }

        let mainStart = spec.introBars
        let mainEnd = totalBars - spec.outroBars - 1
        var bassBars: [ClosedRange<Int>] = []
        var cursor = mainStart
        for brk in spec.breakdownBars.sorted(by: { $0.lowerBound < $1.lowerBound }) where brk.lowerBound > cursor {
            bassBars.append(cursor...(brk.lowerBound - 1))
            cursor = brk.upperBound + 1
        }
        if cursor <= mainEnd { bassBars.append(cursor...mainEnd) }

        var kickBars: [ClosedRange<Int>] = []
        cursor = 0
        for brk in spec.breakdownBars.sorted(by: { $0.lowerBound < $1.lowerBound }) where brk.lowerBound > cursor {
            kickBars.append(cursor...(brk.lowerBound - 1))
            cursor = brk.upperBound + 1
        }
        if cursor < totalBars { kickBars.append(cursor...(totalBars - 1)) }

        return MixFixtureTruth(
            spec: spec,
            beats: beats,
            downbeats: downbeats,
            barStarts: downbeats,
            vocalRanges: spec.vocalBars.compactMap(range),
            bassRanges: bassBars.compactMap(range),
            kickRanges: kickBars.compactMap(range)
        )
    }
}

struct MixFixture: Sendable {
    let spec: MixFixtureSpec
    let truth: MixFixtureTruth
    let url: URL
    let waveform: [Float]
    let integratedLUFS: Double
}

enum MixFixtureFactory {
    static let sampleRate = DJEngineConstants.canonicalSampleRate

    static func fixture(_ spec: MixFixtureSpec, in directory: URL) throws -> MixFixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let truth = MixFixtureTruth.make(spec)
        let digest = String(stableHash(spec.signature), radix: 16)
        let url = directory.appendingPathComponent("\(spec.id)-\(digest).caf")
        let metaURL = directory.appendingPathComponent("\(spec.id)-\(digest).json")
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(FixtureMeta.self, from: data) {
            return MixFixture(spec: spec, truth: truth, url: url, waveform: meta.waveform, integratedLUFS: meta.integratedLUFS)
        }

        let mono = synthesize(spec: spec, truth: truth)
        try write(mono: mono, to: url)
        let waveform = peakWaveform(mono, count: 1800)
        let lufs = MixMetrics.integratedLoudness(left: mono, right: mono, sampleRate: sampleRate)
        let meta = FixtureMeta(waveform: waveform, integratedLUFS: lufs)
        try JSONEncoder().encode(meta).write(to: metaURL)
        return MixFixture(spec: spec, truth: truth, url: url, waveform: waveform, integratedLUFS: lufs)
    }

    private struct FixtureMeta: Codable {
        let waveform: [Float]
        let integratedLUFS: Double
    }

    static func stableHash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private static func peakWaveform(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: count)
        let n = samples.count
        samples.withUnsafeBufferPointer { src in
            for i in 0..<count {
                let start = i * n / count
                let end = max(start + 1, min(n, (i + 1) * n / count))
                var peak: Float = 0
                var j = start
                while j < end {
                    let v = abs(src[j])
                    if v > peak { peak = v }
                    j += 7
                }
                out[i] = peak
            }
        }
        let maximum = out.max() ?? 1
        return maximum > 0 ? out.map { $0 / maximum } : out
    }

    private static func write(mono: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = Int(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let channels = buffer.floatChannelData else {
            throw MixEngineError.decodeFailed("fixture buffer")
        }
        var offset = 0
        while offset < mono.count {
            let count = min(chunk, mono.count - offset)
            mono.withUnsafeBufferPointer { src in
                for i in 0..<count {
                    channels[0][i] = src[offset + i]
                    channels[1][i] = src[offset + i]
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }

    // MARK: - Synthesis

    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
        }
    }

    private static func midiHz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

    static func synthesize(spec: MixFixtureSpec, truth: MixFixtureTruth) -> [Float] {
        let sr = sampleRate
        let total = Int(spec.duration * sr)
        var out = [Float](repeating: 0, count: total)
        var noise = Noise(state: stableHash(spec.id))
        let totalBars = truth.downbeats.count
        let firstDownbeatIndex = truth.beats.firstIndex { abs($0 - spec.firstDownbeat) < 1e-6 } ?? 0

        func inRanges(_ bar: Int, _ ranges: [ClosedRange<Int>]) -> Bool { ranges.contains { $0.contains(bar) } }
        func inSeconds(_ t: TimeInterval, _ ranges: [ClosedRange<TimeInterval>]) -> Bool {
            ranges.contains { t >= $0.lowerBound && t < $0.upperBound }
        }

        out.withUnsafeMutableBufferPointer { buf in
            func addEvent(at start: TimeInterval, seconds: TimeInterval, _ voice: (Double) -> Double) {
                let first = max(0, Int(start * sr))
                let last = min(total, Int((start + seconds) * sr))
                guard last > first else { return }
                for n in first..<last {
                    let t = Double(n) / sr - start
                    if t < 0 { continue }
                    buf[n] += Float(voice(t))
                }
            }

            let third = spec.isMinor ? 3.0 : 4.0
            let scale: [Double] = spec.isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
            let root = Double(spec.keyPitchClass)

            for (index, beatTime) in truth.beats.enumerated() {
                let relative = index - firstDownbeatIndex
                let bar = relative >= 0 ? relative / 4 : -1
                let beatInBar = relative >= 0 ? relative % 4 : relative + 4
                let period = index + 1 < truth.beats.count ? truth.beats[index + 1] - beatTime : 60 / spec.bpmEnd
                let isBreak = bar >= 0 && inRanges(bar, spec.breakdownBars)

                if relative < 0 {
                    let hatSeed = noise.state
                    var local = Noise(state: hatSeed)
                    addEvent(at: beatTime, seconds: 0.04) { t in Double(local.next()) * exp(-t * 90) * 0.10 }
                    _ = noise.next()
                    continue
                }

                if !isBreak {
                    var phase = 0.0
                    var lastT = 0.0
                    addEvent(at: beatTime, seconds: 0.28) { t in
                        let f = 48 + 110 * exp(-t * 32)
                        phase += 2 * .pi * f * (t - lastT)
                        lastT = t
                        let attack = min(1, t / 0.0015)
                        return sin(phase) * attack * exp(-t * 8.5) * 0.95
                    }
                }

                var hat = Noise(state: noise.state)
                _ = noise.next()
                var previous: Float = 0
                addEvent(at: beatTime + period / 2, seconds: 0.05) { t in
                    let v = hat.next()
                    let bright = v - previous
                    previous = v
                    return Double(bright) * exp(-t * 70) * 0.09
                }

                if !isBreak, beatInBar == 1 || beatInBar == 3, bar >= spec.introBars / 2 {
                    var clap = Noise(state: noise.state)
                    _ = noise.next()
                    var lp: Float = 0
                    addEvent(at: beatTime, seconds: 0.16) { t in
                        let v = clap.next()
                        lp += 0.35 * (v - lp)
                        return Double(v - lp) * exp(-t * 22) * 0.16
                    }
                }

                let barStart = bar < truth.downbeats.count ? truth.downbeats[bar] : beatTime
                if inSeconds(barStart + 0.01, truth.bassRanges) {
                    let note = 36 + root + ((bar % 4 == 3 && beatInBar >= 2) ? 7 : 0)
                    let f = midiHz(note)
                    addEvent(at: beatTime + period / 2, seconds: period * 0.48) { t in
                        let attack = min(1, t / 0.012)
                        let env = attack * exp(-t * 5)
                        return (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * env * 0.42
                    }
                }

                if beatInBar == 0, bar % 8 == 0, bar > 0 {
                    var crash = Noise(state: noise.state)
                    _ = noise.next()
                    var previousCrash: Float = 0
                    addEvent(at: beatTime, seconds: 1.2) { t in
                        let v = crash.next()
                        let bright = v - previousCrash
                        previousCrash = v
                        return Double(bright) * exp(-t * 3.5) * 0.05
                    }
                }

                if inSeconds(beatTime + 0.01, truth.vocalRanges) {
                    let degree = scale[(bar * 3 + beatInBar * 2 + (bar / 2)) % scale.count]
                    let f0 = midiHz(57 + root.truncatingRemainder(dividingBy: 12) + degree)
                    let length = period * 0.92
                    addEvent(at: beatTime, seconds: length) { t in
                        let vibrato = 1 + 0.006 * sin(2 * .pi * 5.2 * t)
                        let attack = min(1, t / 0.02)
                        let release = min(1, max(0, (length - t) / 0.03))
                        var v = 0.0
                        let weights: [Double] = [1.0, 0.55, 0.62, 0.35, 0.22, 0.12]
                        for (h, w) in weights.enumerated() {
                            v += w * sin(2 * .pi * f0 * Double(h + 1) * t * vibrato)
                        }
                        return v * attack * release * 0.075
                    }
                }
            }

            let padNotes = [48 + root, 60 + root, 60 + root + third, 67 + root]
            let padFrequencies = padNotes.map(midiHz)
            let padStart = truth.downbeats.first ?? 0
            var phases = [Double](repeating: 0, count: padFrequencies.count)
            let increments = padFrequencies.map { 2 * .pi * $0 / sr }
            let padFirst = Int(padStart * sr)
            for n in padFirst..<total {
                let t = Double(n) / sr
                let fadeIn = min(1, (t - padStart) / 2)
                let fadeOut = min(1, max(0, (spec.duration - t) / 2))
                var v = 0.0
                for k in 0..<phases.count {
                    phases[k] += increments[k]
                    if phases[k] > 2 * .pi { phases[k] -= 2 * .pi }
                    v += sin(phases[k])
                }
                buf[n] += Float(v * 0.035 * fadeIn * fadeOut)
            }
            _ = totalBars
        }

        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        if peak > 0 {
            let scale = 0.89 / peak
            for i in out.indices { out[i] *= scale }
        }
        return out
    }
}
#endif
