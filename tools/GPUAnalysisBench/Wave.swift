#if AFTER
import AVFoundation
import Accelerate
import Foundation

final class VocalSink: AnalysisPCMSink, @unchecked Sendable {
    let classifier: VocalClassifier
    init?(overlap: Double) {
        guard let c = VocalClassifier(sampleRate: BeatTracker.sampleRate, overlapFactor: overlap) else { return nil }
        classifier = c
    }
    func consume(_ samples: UnsafeBufferPointer<Float>) { classifier.consume(samples) }
}

final class LegacyTeeSink: AnalysisPCMSink, @unchecked Sendable {
    let extractor: any BeatTrackerFeatureExtracting
    let voice: LegacyVocalClassifier?

    static func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let max = BeatTracker.maxAnalysisSeconds
        let d = (try? await asset.load(.duration).seconds) ?? 0
        return min(max, d.isFinite && d > 0 ? d : max)
    }

    init(duration: Double, options: BeatTracker.Options) {
        let hop = BeatTracker.hop(forDuration: duration, options: options)
        extractor = options.makeExtractor?(hop, duration) ?? BeatTrackerFeatureExtractor(hop: hop, expectedSeconds: duration)
        voice = LegacyVocalClassifier(sampleRate: BeatTracker.sampleRate)
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        extractor.consume(samples)
        voice?.consume(samples)
    }

    func finish() -> BeatTrackerFeatures {
        var features = extractor.finish()
        if let curve = voice?.finish() {
            features.vocalCurve = curve
            features.vocalRanges = VocalClassifier.ranges(curve)
        }
        return features
    }
}

enum DecodeDeterminism {
    static func hash(_ url: URL) async throws -> (UInt64, Int) {
        var h: UInt64 = 0xcbf29ce484222325
        var n = 0
        try await AnalysisPCMDecode.read(fileURL: url, maxSeconds: BeatTracker.maxAnalysisSeconds, yield: nil, begin: { _ in }) { slice in
            for x in slice { h = (h ^ UInt64(x.bitPattern)) &* 0x100000001b3 }
            n += slice.count
        }
        return (h, n)
    }

    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let shard = Int(env["WAVE_SHARD"] ?? "0") ?? 0
        let shards = Int(env["WAVE_SHARDS"] ?? "1") ?? 1
        let mine = entries.enumerated().filter { $0.offset % shards == shard }.map(\.element)
        var rows: [String] = []
        for entry in mine {
            let url = URL(fileURLWithPath: entry.path)
            guard let a = try? await hash(url), let b = try? await hash(url) else { continue }
            rows.append("\(url.lastPathComponent)\t\(a.0 == b.0 && a.1 == b.1)\t\(a.1)\t\(b.1)")
            try rows.joined(separator: "\n").write(to: output.appendingPathComponent("det-\(shard).tsv"), atomically: true, encoding: .utf8)
        }
    }
}

enum LoudGate {
    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let shard = Int(env["WAVE_SHARD"] ?? "0") ?? 0
        let shards = Int(env["WAVE_SHARDS"] ?? "1") ?? 1
        let mine = entries.enumerated().filter { $0.offset % shards == shard }.map(\.element)
        var rows: [String] = []
        for entry in mine {
            let url = URL(fileURLWithPath: entry.path)
            guard let samples = try? await decodeMono(url), let source = try? MixSource(url: url, synchronous: true) else { continue }
            for i in 0..<source.chunkCount { _ = source.chunk(i) }
            let bars = BeatTracker.analyze(extract(samples, backend: .cpu), tempoPrior: nil).downbeats
            let t0 = now()
            let old = Legacy.loudness(source: source, barStarts: bars)
            let t1 = now()
            let new = LocalLoudness.measure(source: source, barStarts: bars, bars: 0..<bars.count).bars
            let t2 = now()
            var lu = 0.0, share = 0.0, n = 0
            for (k, o) in old {
                guard let m = new[k] else { lu = .infinity; continue }
                if o.power > 1e-9 || m.power > 1e-9 { lu = max(lu, abs(o.lufs - m.lufs)); n += 1 }
                share = max(share, abs(o.low - m.low), abs(o.high - m.high))
            }
            if old.count != new.count { lu = .infinity }
            rows.append("\(url.lastPathComponent)\t\(n)\t\(lu)\t\(share)\t\(t1 - t0)\t\(t2 - t1)\t\(source.duration)")
            try rows.joined(separator: "\n").write(to: output.appendingPathComponent("loud-\(shard).tsv"), atomically: true, encoding: .utf8)
        }
    }
}

final class PrefilterCompareSink: AnalysisPCMSink, @unchecked Sendable {
    private let filters: [(Double, Double, Double, Double, Double)]
    private var states: [(Double, Double, Double, Double)]
    private let cascade: DoubleBiquadCascade
    private var a = [Float](), b = [Float]()
    var maxAbs = 0.0
    var errorPower = 0.0
    var signalPower = 0.0

    init() {
        let hp = VocalClassifier.biquad(highPass: true, cutoff: 250, sampleRate: BeatTracker.sampleRate)
        let lp = VocalClassifier.biquad(highPass: false, cutoff: 5_000, sampleRate: BeatTracker.sampleRate)
        filters = [hp, hp, lp, lp]
        states = Array(repeating: (0, 0, 0, 0), count: 4)
        cascade = DoubleBiquadCascade(filters)!
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        if a.count < samples.count { a = [Float](repeating: 0, count: samples.count); b = a }
        a.withUnsafeMutableBufferPointer { LegacyVocalClassifier.prefilter(samples, filters: filters, states: &states, into: $0.baseAddress!) }
        b.withUnsafeMutableBufferPointer { cascade.run(samples.baseAddress!, into: $0.baseAddress!, count: samples.count) }
        for i in 0..<samples.count {
            let d = Double(a[i] - b[i])
            maxAbs = max(maxAbs, abs(d))
            errorPower += d * d
            signalPower += Double(a[i]) * Double(a[i])
        }
    }

    var snr: Double { errorPower > 0 ? 10 * log10(signalPower / errorPower) : .infinity }
}

enum Wave {
    static let overlaps = [0.25, 0.0]

    static func sung(_ ranges: [ClosedRange<TimeInterval>], bars: [Double], end: Double) -> [Bool] {
        bars.indices.map { b in
            let lo = bars[b]
            let hi = b + 1 < bars.count ? bars[b + 1] : end
            let span = lo...max(lo, hi)
            return ranges.reduce(0) { $0 + max(0, min($1.upperBound, span.upperBound) - max($1.lowerBound, span.lowerBound)) } > 0.01
        }
    }

    static func ranges(_ curve: [Float]) -> [ClosedRange<TimeInterval>] {
        VocalClassifier.ranges(curve).compactMap { $0.end > $0.start ? $0.start...$0.end : nil }
    }

    static func join(_ v: [Int8]) -> String { v.map { String($0) }.joined(separator: ",") }

    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let shard = Int(env["WAVE_SHARD"] ?? "0") ?? 0
        let shards = Int(env["WAVE_SHARDS"] ?? "1") ?? 1
        let limit = Int(env["WAVE_LIMIT"] ?? "0") ?? 0
        let all = limit > 0 ? Array(entries.prefix(limit)) : entries
        let mine = all.enumerated().filter { $0.offset % shards == shard }.map(\.element)
        let options = AnalysisFeatureBackend.options(BeatTracker.Options(), backend: .cpu)
        var rows = ["file\tseconds\tresult_equal\tbeats_equal\tdownbeats_equal\tbpm_equal\tkey_equal\tsections_equal\tarrangement_equal\tbar_level_max\tcurve05_diff_points\tcurve05_max\tbars\tagree05\tdiff05\tagree025\tdiff025\tagree0\tdiff0\tlu_max\tlow_max\thigh_max\tpeak_max\tloud_bars\ttimbre_whole\ttimbre_open\ttimbre_close\tframes_old\tframes_new\tprefilter_max\tprefilter_snr_db\ttimbre_noise_whole"]
        var embeds: [String] = []
        let rowsURL = output.appendingPathComponent("wave-\(shard).tsv")
        let embedsURL = output.appendingPathComponent("timbre-\(shard).tsv")
        for (n, entry) in mine.enumerated() {
            let url = URL(fileURLWithPath: entry.path)
            let duration = await LegacyTeeSink.duration(url)
            let tee = LegacyTeeSink(duration: duration, options: options)
            let sinks25 = VocalSink(overlap: 0.25)!, sinks0 = VocalSink(overlap: 0)!
            let compare = PrefilterCompareSink()
            let timbreSink = TimbreFeatureSink()!
            guard let fresh = try? await BeatTracker.extractFeatures(fileURL: url, options: options, sinks: [tee, sinks25, sinks0, compare, timbreSink]) else { print("skip \(entry.path)"); continue }
            let legacy = tee.finish()
            let newTimbre = try? await timbreSink.finish()
            let oldTimbre = try? await Legacy.timbre(url: url)
            let repeatTimbre = n % 4 == 0 ? try? await Legacy.timbre(url: url) : nil
            let curve25 = sinks25.classifier.finish() ?? []
            let curve0 = sinks0.classifier.finish() ?? []
            let rL = BeatTracker.analyze(legacy, tempoPrior: nil)
            let rN = BeatTracker.analyze(fresh, tempoPrior: nil)
            let seconds = legacy.analysedSeconds
            let bpmEqual = rL.bpm == rN.bpm
            let keyEqual = Parity.key(legacy) == Parity.key(fresh)
            let sectionsEqual = rL.sectionStarts == rN.sectionStarts && rL.phraseStarts == rN.phraseStarts
            let arrangementEqual = Parity.sections(rL) == Parity.sections(rN)
            let levelDelta = Parity.maxDelta((rL.bars?.level ?? []).map(Double.init), (rN.bars?.level ?? []).map(Double.init))
            let cL = legacy.vocalCurve ?? [], cN = fresh.vocalCurve ?? []
            var curveDiff = 0, curveMax: Float = 0
            for i in 0..<max(cL.count, cN.count) {
                let a = i < cL.count ? cL[i] : -1, b = i < cN.count ? cN[i] : -1
                if a != b { curveDiff += 1; curveMax = max(curveMax, abs(a - b)) }
            }
            let bars = rL.downbeats
            let base = sung(ranges(cL), bars: bars, end: seconds)
            func compareBars(_ curve: [Float]) -> (Int, Int) {
                let other = sung(ranges(curve), bars: bars, end: seconds)
                let agree = zip(base, other).filter { $0 == $1 }.count
                return (agree, base.count - agree)
            }
            let (a05, d05) = compareBars(cN)
            let (a25, d25) = compareBars(curve25)
            let (a0, d0) = compareBars(curve0)
            var luMax = 0.0, lowMax = 0.0, highMax = 0.0, peakMax = 0.0, loudBars = 0
            if let source = try? MixSource(url: url, synchronous: true) {
                for i in 0..<source.chunkCount { _ = source.chunk(i) }
                let old = Legacy.loudness(source: source, barStarts: bars)
                let new = LocalLoudness.measure(source: source, barStarts: bars, bars: 0..<bars.count).bars
                for (k, o) in old {
                    guard let m = new[k] else { luMax = .infinity; continue }
                    if o.power > 1e-9 || m.power > 1e-9 {
                        luMax = max(luMax, abs(o.lufs - m.lufs))
                        loudBars += 1
                    }
                    lowMax = max(lowMax, abs(o.low - m.low))
                    highMax = max(highMax, abs(o.high - m.high))
                    peakMax = max(peakMax, abs(o.peak - m.peak))
                }
                if new.count != old.count { luMax = .infinity }
            }
            func cos(_ x: [Int8]?, _ y: [Int8]?) -> String {
                guard let x, let y, let c = TimbreEmbedding.cosine(x, y) else { return "nan" }
                return String(format: "%.5f", c)
            }
            rows.append([
                url.lastPathComponent, String(format: "%.1f", seconds), "\(rL == rN)", "\(rL.beats == rN.beats)", "\(rL.downbeats == rN.downbeats)",
                "\(bpmEqual)", "\(keyEqual)", "\(sectionsEqual)", "\(arrangementEqual)", String(format: "%.3f", levelDelta),
                "\(curveDiff)", String(format: "%.3f", curveMax), "\(base.count)", "\(a05)", "\(d05)", "\(a25)", "\(d25)", "\(a0)", "\(d0)",
                String(format: "%.4f", luMax), String(format: "%.5f", lowMax), String(format: "%.5f", highMax), String(format: "%.2e", peakMax), "\(loudBars)",
                cos(oldTimbre?.whole, newTimbre?.whole), cos(oldTimbre?.opening, newTimbre?.opening), cos(oldTimbre?.closing, newTimbre?.closing),
                "\(oldTimbre?.frames ?? -1)", "\(newTimbre?.frames ?? -1)", String(format: "%.2e", compare.maxAbs), String(format: "%.1f", compare.snr),
                cos(oldTimbre?.whole, repeatTimbre?.whole)
            ].joined(separator: "\t"))
            if let o = oldTimbre, let m = newTimbre {
                embeds.append([url.lastPathComponent, join(o.whole), join(o.opening), join(o.closing), join(m.whole), join(m.opening), join(m.closing)].joined(separator: "\t"))
            }
            print("[\(shard):\(n + 1)/\(mine.count)] eq \(rL == rN) curve \(curveDiff) d05 \(d05) d25 \(d25) d0 \(d0) lu \(String(format: "%.3f", luMax)) timbre \(cos(oldTimbre?.whole, newTimbre?.whole)) \(url.lastPathComponent)")
            try rows.joined(separator: "\n").write(to: rowsURL, atomically: true, encoding: .utf8)
            try embeds.joined(separator: "\n").write(to: embedsURL, atomically: true, encoding: .utf8)
        }
    }

    static func summarise(output: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        var header: [String] = []
        var rows: [[String]] = []
        var embeds: [[String]] = []
        for f in files.sorted(by: { $0.path < $1.path }) where f.pathExtension == "tsv" {
            let lines = try String(contentsOf: f, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            if f.lastPathComponent.hasPrefix("wave-") { header = lines.first ?? []; rows += lines.dropFirst() }
            if f.lastPathComponent.hasPrefix("timbre-") { embeds += lines.filter { $0.count == 7 } }
        }
        func col(_ name: String) -> Int { header.firstIndex(of: name)! }
        func count(_ name: String, _ value: String = "true") -> Int { rows.filter { $0[col(name)] == value }.count }
        func dbl(_ r: [String], _ name: String) -> Double { Double(r[col(name)]) ?? .nan }
        var out: [String] = ["tracks: \(rows.count)"]
        for name in ["result_equal", "beats_equal", "downbeats_equal", "bpm_equal", "key_equal", "sections_equal", "arrangement_equal"] {
            out.append("\(name): \(count(name))/\(rows.count)")
        }
        out.append("bar_level_max: \(rows.map { dbl($0, "bar_level_max") }.max() ?? 0)")
        out.append("vocal curve 0.5 (vDSP prefilter) tracks with any differing point: \(rows.filter { $0[col("curve05_diff_points")] != "0" }.count), worst point diff \(rows.map { dbl($0, "curve05_max") }.max() ?? 0)")
        let totalBars = rows.map { dbl($0, "bars") }.reduce(0, +)
        for (label, agree, diff) in [("0.5 vDSP", "agree05", "diff05"), ("0.25", "agree025", "diff025"), ("0", "agree0", "diff0")] {
            let agreeAll = rows.map { dbl($0, agree) }.reduce(0, +)
            let perTrack = rows.filter { dbl($0, "bars") > 0 }.map { dbl($0, agree) / dbl($0, "bars") }
            let diffs = rows.map { Int(dbl($0, diff)) }
            let over1 = diffs.filter { $0 > 1 }.count
            let under99 = perTrack.filter { $0 < 0.99 }.count
            out.append("overlap \(label): bar agreement \(String(format: "%.4f", agreeAll / totalBars)) of \(Int(totalBars)) bars; worst track \(String(format: "%.4f", perTrack.min() ?? 1)); tracks under 99%: \(under99); tracks with sung-set change > 1 bar: \(over1); worst change \(diffs.max() ?? 0) bars; histogram \(Dictionary(grouping: diffs, by: { min($0, 10) }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)\($0.key == 10 ? "+" : ""):\($0.value)" }.joined(separator: " "))")
        }
        out.append("loudness max |dLU| per bar: \(rows.map { dbl($0, "lu_max") }.max() ?? 0) over \(Int(rows.map { dbl($0, "loud_bars") }.reduce(0, +))) bars; low share max \(rows.map { dbl($0, "low_max") }.max() ?? 0); high share max \(rows.map { dbl($0, "high_max") }.max() ?? 0); peak max \(rows.map { dbl($0, "peak_max") }.max() ?? 0)")
        out.append("prefilter: max abs error \(rows.map { dbl($0, "prefilter_max") }.max() ?? 0); worst SNR \(rows.map { dbl($0, "prefilter_snr_db") }.min() ?? 0) dB")
        let whole = rows.map { dbl($0, "timbre_whole") }.filter { !$0.isNaN }.sorted()
        let open = rows.map { dbl($0, "timbre_open") }.filter { !$0.isNaN }.sorted()
        let close = rows.map { dbl($0, "timbre_close") }.filter { !$0.isNaN }.sorted()
        func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? .nan : v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
        out.append("timbre self-cosine old vs new: whole min \(pct(whole, 0)) p1 \(pct(whole, 0.01)) median \(pct(whole, 0.5)); opening min \(pct(open, 0)) median \(pct(open, 0.5)); closing min \(pct(close, 0)) median \(pct(close, 0.5)); frames equal \(rows.filter { $0[col("frames_old")] == $0[col("frames_new")] }.count)/\(rows.count)")
        let noise = rows.map { dbl($0, "timbre_noise_whole") }.filter { !$0.isNaN }.sorted()
        out.append("timbre self-cosine old vs old (run-to-run, every 4th track, \(noise.count) tracks): min \(pct(noise, 0)) median \(pct(noise, 0.5)); equal \(noise.filter { $0 >= 0.999995 }.count)")
        func parse(_ s: String) -> [Int8] { s.split(separator: ",").compactMap { Int8($0) } }
        let olds = embeds.map { TimbreEmbedding(whole: parse($0[1]), opening: parse($0[2]), closing: parse($0[3]), frames: 1) }
        let news = embeds.map { TimbreEmbedding(whole: parse($0[4]), opening: parse($0[5]), closing: parse($0[6]), frames: 1) }
        var deltas: [Double] = []
        for i in olds.indices { for j in olds.indices where i != j {
            deltas.append(abs(TimbreScoring.cost(from: olds[i], to: olds[j]) - TimbreScoring.cost(from: news[i], to: news[j])))
        } }
        deltas.sort()
        out.append("timbre pair cost |delta| over \(deltas.count) ordered pairs (cost range 0...\(TimbreScoring.weight)): median \(String(format: "%.4f", pct(deltas, 0.5))) p99 \(String(format: "%.4f", pct(deltas, 0.99))) max \(String(format: "%.4f", pct(deltas, 1))); pairs over 0.01: \(deltas.filter { $0 > 0.01 }.count), over 0.05: \(deltas.filter { $0 > 0.05 }.count)")
        let text = out.joined(separator: "\n")
        print(text)
        try text.write(to: output.appendingPathComponent("wave-summary.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
