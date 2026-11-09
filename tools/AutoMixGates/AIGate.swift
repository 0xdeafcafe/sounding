import AVFoundation
import Accelerate
import Foundation

func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

func fMeasure(_ reference: [Double], _ estimate: [Double], tolerance: Double = 0.07) -> Double {
    guard !reference.isEmpty, !estimate.isEmpty else { return 0 }
    var hits = 0
    for r in reference {
        let i = BeatTrackerResult.nearestIndex(in: estimate, to: r)
        if abs(estimate[i] - r) <= tolerance { hits += 1 }
    }
    let p = Double(hits) / Double(estimate.count), q = Double(hits) / Double(reference.count)
    return p + q == 0 ? 0 : 2 * p * q / (p + q)
}

@main
enum AIGate {
    static func main() async throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/automix-moves-src")
        let aiDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/ai-audio-out")
        let ids = args.count > 3 ? args[3].split(separator: ",").map(String.init) : ["darkknight", "jungle", "marionette", "voodoo"]
        for id in ids {
            let features = try await BeatTracker.extractFeatures(fileURL: source.appendingPathComponent("\(id).wav"))
            let base = BeatTracker.analyze(features, tempoPrior: nil)
            let ai = try JSONDecoder().decode(BeatThisResult.self, from: Data(contentsOf: aiDir.appendingPathComponent("beatthis-\(id).json")))
            let imposed = BeatTracker.imposing(beats: ai.beats, downbeats: ai.barDownbeats, beatConfidence: ai.confidence, downbeatConfidence: ai.downbeatConfidence, on: features, base: base)
            let result = AIAudioAnalysisResult(version: 1, grid: imposed, gridConfidence: ai.confidence, downbeatConfidence: ai.downbeatConfidence, beatsPerBar: ai.beatsPerBar, stems: nil)
            let planner = result.plannerGrid(phaseFrom: base)
            let low = try lowSpectralFlux(source.appendingPathComponent("\(id).wav"))
            let mean = Double(low.reduce(0, +)) / Double(max(1, low.count))
            func kick(_ times: [Double]) -> Double {
                let v = times.compactMap { t -> Double? in
                    let i = Int((t * 50).rounded())
                    guard i >= 1, i < low.count - 1 else { return nil }
                    return Double(low[(i - 1)...(i + 1)].max() ?? 0)
                }
                return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) / mean
            }
            func offbeat(_ beats: [Double]) -> [Double] { zip(beats, beats.dropFirst()).map { ($0 + $1) / 2 } }
            let v2 = try? JSONDecoder().decode(CachedTracker.self, from: Data(contentsOf: source.appendingPathComponent("analysis-\(id)-v2.json")))
            print("  fresh tracker vs cached v2: beat F \(f(fMeasure(v2?.beats ?? [], base.beats))) downbeat F \(f(fMeasure(v2?.downbeats ?? [], base.downbeats)))")
            print("  kick on-beat/off-beat x mean: tracker \(f(kick(base.beats)))/\(f(kick(offbeat(base.beats)))) AI \(f(kick(imposed?.beats ?? [])))/\(f(kick(offbeat(imposed?.beats ?? []))))")
            let path = result.isGridTrusted ? "AI beats + AI bar phase" : (planner != nil ? "AI beats + tracker bar phase" : "tracker only")
            print("\(id): AI conf \(f(ai.confidence)) downConf \(f(ai.downbeatConfidence)) -> \(path); tracker conf \(f(base.confidence)) downConf \(f(base.downbeatConfidence)) phaseReliable \(base.isPhaseReliable)")
            guard let planner else { continue }
            let onBeat = base.downbeats.filter { d in
                let i = BeatTrackerResult.nearestIndex(in: planner.beats, to: d)
                return abs(planner.beats[i] - d) <= 0.07
            }
            let kept = onBeat.filter { d in
                let i = BeatTrackerResult.nearestIndex(in: planner.downbeats, to: d)
                return abs(planner.downbeats[i] - d) <= 0.07
            }
            print("  bpm tracker \(f(base.bpm ?? 0)) AI file \(f(ai.bpm ?? 0)) planner \(f(planner.bpm ?? 0))")
            print("  kick at beats x mean: tracker \(f(kick(base.beats))) AI \(f(kick(imposed?.beats ?? []))) planner \(f(kick(planner.beats)))")
            print("  kick at downbeats x mean: tracker \(f(kick(base.downbeats))) AI-phase \(f(kick(imposed?.downbeats ?? []))) planner \(f(kick(planner.downbeats)))")
            print("  tracker downbeats already on an AI beat: \(onBeat.count)/\(base.downbeats.count); kept as planner downbeats: \(kept.count) (\(f(100 * Double(kept.count) / Double(max(1, onBeat.count)), 1))%)")
            print("  planner downbeat F vs tracker \(f(fMeasure(base.downbeats, planner.downbeats))) vs AI phase \(f(fMeasure(imposed?.downbeats ?? [], planner.downbeats))); phraseOffsetBars tracker \(base.phraseOffsetBars) AI \(imposed?.phraseOffsetBars ?? -1) planner \(planner.phraseOffsetBars); confidence \(f(planner.confidence, 3)); bars \(planner.bars?.level.count ?? 0)/\(planner.downbeats.count)")
            var windows: [String] = []
            var t = 0.0
            while t < features.analysedSeconds {
                let w = { (x: [Double]) in x.filter { $0 >= t && $0 < t + 60 } }
                windows.append("\(Int(t)):\(f(kick(w(base.beats)), 1))/\(f(kick(w(planner.beats)), 1))")
                t += 60
            }
            print("  per-60s kick at beats tracker/planner: " + windows.joined(separator: " "))
            let wav = source.appendingPathComponent("\(id).wav")
            for (name, curve) in [("sub <60 Hz", try kickFlux(wav, cutoff: 60)), ("hats >6 kHz", try kickFlux(wav, cutoff: 6000, highpass: true))] {
                var bins = [Double](repeating: 0, count: 8)
                for (a, b) in zip(planner.beats, planner.beats.dropFirst()) {
                    for k in 0..<8 {
                        let i = Int(((a + (b - a) * Double(k) / 8) * kickFrameRate).rounded())
                        if i >= 2, i < curve.count - 2 { bins[k] += Double(curve[(i - 2)...(i + 2)].max() ?? 0) }
                    }
                }
                let top = bins.max() ?? 1
                print("  \(name) flux across the planner beat in 8ths (0 = on the beat): " + bins.map { f($0 / top) }.joined(separator: " "))
            }
        }
    }
}

func lowSpectralFlux(_ url: URL, fps: Double = 50, lowHz: Double = 30, highHz: Double = 650) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let rate = format.sampleRate
    let n = 2048
    let hop = Int(rate / fps)
    let dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
    let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    let lo = max(1, Int(lowHz / rate * Double(n))), hi = Int(highHz / rate * Double(n))
    var mono: [Float] = []
    mono.reserveCapacity(Int(file.length))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16)!
    while file.framePosition < file.length {
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { break }
        let channels = Int(format.channelCount)
        for i in 0..<frames {
            var x: Float = 0
            for c in 0..<channels { x += data[c][i] }
            mono.append(x / Float(channels))
        }
    }
    var previous = [Float](repeating: 0, count: hi - lo + 1)
    var flux: [Float] = []
    let zeros = [Float](repeating: 0, count: n)
    var start = -n / 2
    while start + n / 2 < mono.count {
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n where start + i >= 0 && start + i < mono.count { frame[i] = mono[start + i] * window[i] }
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
        var s: Float = 0
        for (k, b) in (lo...hi).enumerated() {
            let m = log1p(1000 * sqrt(re[b] * re[b] + im[b] * im[b]) / Float(n))
            s += max(0, m - previous[k])
            previous[k] = m
        }
        flux.append(s)
        start += hop
    }
    return flux
}

struct CachedTracker: Decodable {
    let beats: [Double]
    let downbeats: [Double]
}

let kickFrameRate = 200.0

func kickFlux(_ url: URL, cutoff: Double = 100, highpass: Bool = false) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let rate = format.sampleRate
    let hop = Int(rate / kickFrameRate)
    let w = 2 * Double.pi * cutoff / rate
    let alpha = sin(w) / (2 * 0.707)
    let a0 = 1 + alpha
    let b0 = Float((highpass ? 1 + cos(w) : 1 - cos(w)) / 2 / a0)
    let b1 = Float((highpass ? -(1 + cos(w)) : 1 - cos(w)) / a0), b2 = b0
    let a1 = Float(-2 * cos(w) / a0), a2 = Float((1 - alpha) / a0)
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    var energy: [Float] = []
    var acc: Float = 0, n = 0
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16)!
    while file.framePosition < file.length {
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { break }
        let channels = Int(format.channelCount)
        for i in 0..<frames {
            var x: Float = 0
            for c in 0..<channels { x += data[c][i] }
            x /= Float(channels)
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            acc += y * y; n += 1
            if n == hop { energy.append(log(1e-9 + acc / Float(hop))); acc = 0; n = 0 }
        }
    }
    var flux = [Float](repeating: 0, count: energy.count)
    for i in 2..<energy.count { flux[i] = max(0, energy[i] - energy[i - 2]) }
    return flux
}
