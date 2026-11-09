#if AFTER
import Foundation

enum ModelGate {
    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let shard = Int(env["GATE_SHARD"] ?? "0") ?? 0
        let shards = Int(env["GATE_SHARDS"] ?? "1") ?? 1
        let vocal = env["VOCAL_MODEL"].flatMap { GPUAnalysisNet(url: URL(fileURLWithPath: $0)) }
        let timbre = env["TIMBRE_MODEL"].flatMap { GPUAnalysisNet(url: URL(fileURLWithPath: $0)) }
        let options = AnalysisFeatureBackend.options(BeatTracker.Options(), backend: .gpu)
        var rows = ["index\tseconds\tbars\tagree\tdiff\tcurve_points\tcurve_mae\tsections_equal\tbeats_equal\tour_bars_sung\tapple_bars_sung"]
        var embeds: [String] = []
        let held = entries.enumerated().filter { $0.offset % 5 == 0 }
        for (n, item) in held.enumerated() where n % shards == shard {
            let url = URL(fileURLWithPath: item.element.path)
            guard let mel = GPUMelSink() else { print("no gpu"); return }
            let frames = TimbreFramesSink()
            guard let features = try? await BeatTracker.extractFeatures(fileURL: url, options: options, sinks: [mel, frames]),
                  let melFrames = mel.finish(), let appleFrames = try? await frames.finish() else { print("skip \(url.path)"); continue }
            let apple = BeatTracker.analyze(features, tempoPrior: nil)
            var row = ["\(item.offset)", String(format: "%.1f", features.analysedSeconds)]
            if let vocal, let curve = vocal.vocalCurve(melFrames) {
                var ours = features
                ours.vocalCurve = curve
                ours.vocalRanges = VocalClassifier.ranges(curve)
                let mine = BeatTracker.analyze(ours, tempoPrior: nil)
                let appleCurve = features.vocalCurve ?? []
                let end = features.analysedSeconds
                let a = Wave.sung(apple.vocalSeconds ?? [], bars: apple.downbeats, end: end)
                let b = Wave.sung(mine.vocalSeconds ?? [], bars: apple.downbeats, end: end)
                let agree = zip(a, b).filter { $0 == $1 }.count
                var mae = 0.0
                for i in 0..<min(curve.count, appleCurve.count) { mae += Double(abs(curve[i] - appleCurve[i])) }
                row += ["\(a.count)", "\(agree)", "\(a.count - agree)", "\(curve.count)/\(appleCurve.count)", String(format: "%.4f", mae / Double(max(1, curve.count))),
                        "\(apple.sectionStarts == mine.sectionStarts && apple.phraseStarts == mine.phraseStarts)", "\(apple.beats == mine.beats && apple.downbeats == mine.downbeats)",
                        "\(b.filter { $0 }.count)", "\(a.filter { $0 }.count)"]
            } else {
                row += ["0", "0", "0", "0", "nan", "nan", "nan", "0", "0"]
            }
            rows.append(row.joined(separator: "\t"))
            if let timbre, let ourFrames = timbre.timbreFrames(melFrames), let o = TimbreEmbedding(frames: ourFrames), let a = TimbreEmbedding(frames: appleFrames) {
                embeds.append(["\(item.offset)", Wave.join(a.whole), Wave.join(a.opening), Wave.join(a.closing), Wave.join(o.whole), Wave.join(o.opening), Wave.join(o.closing), "\(appleFrames.count)", "\(ourFrames.count)"].joined(separator: "\t"))
            }
            print("[\(shard)] \(row.joined(separator: " "))")
            try rows.joined(separator: "\n").write(to: output.appendingPathComponent("gate-\(shard).tsv"), atomically: true, encoding: .utf8)
            try embeds.joined(separator: "\n").write(to: output.appendingPathComponent("gatetimbre-\(shard).tsv"), atomically: true, encoding: .utf8)
        }
    }

    static func summarise(output: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        var rows: [[String]] = [], embeds: [[String]] = []
        for f in files where f.pathExtension == "tsv" {
            let lines = try String(contentsOf: f, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            if f.lastPathComponent.hasPrefix("gate-") { rows += lines.dropFirst() }
            if f.lastPathComponent.hasPrefix("gatetimbre-") { embeds += lines.filter { $0.count == 9 } }
        }
        var out: [String] = []
        let vocalRows = rows.filter { Int($0[2]) ?? 0 > 0 }
        if !vocalRows.isEmpty {
            let bars = vocalRows.map { Double($0[2])! }.reduce(0, +)
            let agree = vocalRows.map { Double($0[3])! }.reduce(0, +)
            let diffs = vocalRows.map { Int($0[4])! }
            let under = vocalRows.filter { Double($0[3])! / Double($0[2])! < 0.99 }.count
            let within = diffs.filter { $0 <= 1 }.count
            out.append("vocal: \(vocalRows.count) held-out tracks, \(Int(bars)) bars; sung-bar agreement \(String(format: "%.4f", agree / bars)) (gate >= 0.99); tracks within +-1 bar \(within)/\(vocalRows.count) = \(String(format: "%.1f", 100 * Double(within) / Double(vocalRows.count)))% (gate >= 99%); tracks under 99% agreement \(under); worst \(diffs.max() ?? 0) bars; curve MAE mean \(String(format: "%.4f", vocalRows.compactMap { Double($0[6]) }.reduce(0, +) / Double(vocalRows.count))); sections+phrases equal \(vocalRows.filter { $0[7] == "true" }.count)/\(vocalRows.count); beats equal \(vocalRows.filter { $0[8] == "true" }.count)/\(vocalRows.count); sung bars ours \(vocalRows.map { Int($0[9])! }.reduce(0, +)) vs Apple \(vocalRows.map { Int($0[10])! }.reduce(0, +))")
            out.append("vocal histogram of per-track bar differences: \(Dictionary(grouping: diffs, by: { min($0, 10) }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)\($0.key == 10 ? "+" : ""):\($0.value)" }.joined(separator: " "))")
        }
        if !embeds.isEmpty {
            func parse(_ s: String) -> [Int8] { s.split(separator: ",").compactMap { Int8($0) } }
            let apple = embeds.map { TimbreEmbedding(whole: parse($0[1]), opening: parse($0[2]), closing: parse($0[3]), frames: 1) }
            let ours = embeds.map { TimbreEmbedding(whole: parse($0[4]), opening: parse($0[5]), closing: parse($0[6]), frames: 1) }
            var a: [Double] = [], b: [Double] = []
            var overlap = 0.0, overlapBlend = 0.0
            func blend(_ x: TimbreEmbedding, _ y: TimbreEmbedding) -> Double {
                (1 - TimbreScoring.seamWeight) * (x.similarity(to: y) ?? 0) + TimbreScoring.seamWeight * (x.seam(into: y) ?? 0)
            }
            for i in apple.indices {
                var ra: [(Int, Double, Double)] = [], rb: [(Int, Double, Double)] = []
                for j in apple.indices where j != i {
                    let ca = TimbreScoring.cost(from: apple[i], to: apple[j]), cb = TimbreScoring.cost(from: ours[i], to: ours[j])
                    a.append(ca); b.append(cb)
                    ra.append((j, ca, -blend(apple[i], apple[j]))); rb.append((j, cb, -blend(ours[i], ours[j])))
                }
                func top(_ r: [(Int, Double, Double)], _ byBlend: Bool) -> Set<Int> {
                    Set(r.sorted { byBlend ? $0.2 < $1.2 : ($0.1, $0.0) < ($1.1, $1.0) }.prefix(5).map(\.0))
                }
                overlap += Double(top(ra, false).intersection(top(rb, false)).count) / 5
                overlapBlend += Double(top(ra, true).intersection(top(rb, true)).count) / 5
            }
            let selves = zip(apple, ours).map { TimbreEmbedding.cosine($0.whole, $1.whole) ?? 0 }.sorted()
            out.append("timbre: \(apple.count) held-out tracks, \(a.count) ordered pairs; pair-cost Spearman \(String(format: "%.4f", Rank.spearman(a, b))) (gate >= 0.95); top-5 neighbour overlap \(String(format: "%.3f", overlap / Double(apple.count))) by cost, \(String(format: "%.3f", overlapBlend / Double(apple.count))) by unclamped blend (gate >= 0.80); whole self-cosine min \(String(format: "%.4f", selves.first ?? 0)) median \(String(format: "%.4f", selves[selves.count / 2])); pairs at cost 0: Apple \(a.filter { $0 == 0 }.count), ours \(b.filter { $0 == 0 }.count); at cap: Apple \(a.filter { $0 >= TimbreScoring.weight }.count), ours \(b.filter { $0 >= TimbreScoring.weight }.count)")
        }
        let text = out.joined(separator: "\n")
        print(text)
        try text.write(to: output.appendingPathComponent("gate-summary.txt"), atomically: true, encoding: .utf8)
    }
}

enum Rank {
    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            for k in i...j { r[order[k]] = Double(i + j) / 2 }
            i = j + 1
        }
        return r
    }

    static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        let ra = ranks(a), rb = ranks(b)
        let ma = ra.reduce(0, +) / Double(max(1, ra.count)), mb = rb.reduce(0, +) / Double(max(1, rb.count))
        var num = 0.0, da = 0.0, db = 0.0
        for i in ra.indices {
            num += (ra[i] - ma) * (rb[i] - mb); da += (ra[i] - ma) * (ra[i] - ma); db += (rb[i] - mb) * (rb[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}
#endif
#if AFTER
enum ModelSpeed {
    static func run(entries: [Entry], output: URL, limit: Int) async throws {
        let env = ProcessInfo.processInfo.environment
        let vocal = env["VOCAL_MODEL"].flatMap { GPUAnalysisNet(url: URL(fileURLWithPath: $0)) }
        let timbre = env["TIMBRE_MODEL"].flatMap { GPUAnalysisNet(url: URL(fileURLWithPath: $0)) }
        let held = entries.enumerated().filter { $0.offset % 5 == 0 }.map(\.element).prefix(limit)
        let wall = Stages(), cpu = Stages()
        var audio = 0.0
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let t = now(), c = Pipe.processCPU()
            let v = try body()
            wall.add(name, now() - t)
            cpu.add(name, Pipe.processCPU() - c)
            return v
        }
        _ = GPUModelContext.shared
        for entry in held {
            guard let samples = try? await decodeMono(URL(fileURLWithPath: entry.path)) else { continue }
            audio += Double(samples.count) / BeatTracker.sampleRate
            _ = timed("Apple vocal: pre-filter + SoundAnalysis") { () -> Int in
                let voice = VocalClassifier(sampleRate: BeatTracker.sampleRate)!
                Pipe.chunks(samples) { voice.consume($0) }
                return voice.finish()?.count ?? 0
            }
            let t = now(), c = Pipe.processCPU()
            let sink = TimbreFramesSink()
            Pipe.chunks(samples) { sink.consume($0) }
            _ = try? await sink.finish()
            wall.add("Apple timbre: AudioFeaturePrint", now() - t)
            cpu.add("Apple timbre: AudioFeaturePrint", Pipe.processCPU() - c)
            let mel = timed("ours: GPU mel (streamed)") { () -> AnalysisMelFrames? in
                let m = GPUMelSink()!
                Pipe.chunks(samples) { m.consume($0) }
                return m.finish()
            }
            if let mel, let vocal { _ = timed("ours: vocal net") { vocal.vocalCurve(mel) } }
            if let mel, let timbre { _ = timed("ours: timbre net") { timbre.timbreFrames(mel) } }
        }
        let minutes = audio / 60
        var lines = ["\(held.count) held-out tracks, \(String(format: "%.1f", minutes)) audio minutes; ms per audio minute (wall / process CPU)"]
        for name in wall.order {
            lines.append("\(name)\t\(String(format: "%.1f", wall.seconds[name]! * 1000 / minutes))\t\(String(format: "%.1f", cpu.seconds[name]! * 1000 / minutes))")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        try text.write(to: output.appendingPathComponent("model-speed.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
