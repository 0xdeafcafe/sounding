import Foundation

enum Parity {
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func key(_ features: BeatTrackerFeatures) -> String {
        var sum = [Double](repeating: 0, count: 12)
        let slow = features.chroma.count / 12
        for s in 0..<slow { for k in 0..<12 { sum[k] += Double(features.chroma[s * 12 + k]) } }
        func pearson(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var n = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { n += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return n / max(1e-12, (da * db).squareRoot())
        }
        var best = (-2.0, "none")
        for tonic in 0..<12 {
            let rotated = (0..<12).map { sum[($0 + tonic) % 12] }
            let a = pearson(rotated, major), b = pearson(rotated, minor)
            if a > best.0 { best = (a, names[tonic] + "maj") }
            if b > best.0 { best = (b, names[tonic] + "min") }
        }
        return best.1
    }

    static func maxDelta(_ a: [Float], _ b: [Float]) -> (abs: Double, rel: Double) {
        guard a.count == b.count else { return (.infinity, .infinity) }
        var worst = 0.0, worstRel = 0.0
        for i in a.indices {
            let d = Double(abs(a[i] - b[i]))
            worst = max(worst, d)
            worstRel = max(worstRel, d / max(1e-6, Double(max(abs(a[i]), abs(b[i])))))
        }
        return (worst, worstRel)
    }

    static func maxDelta(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    static func sections(_ r: BeatTrackerResult) -> String {
        guard let a = TrackArrangement.build(r, ai: nil) else { return "none" }
        return (a.intervals.map { "\($0.role.rawValue):\($0.bars)" } + a.boundaries.map { "b\($0.bar)\($0.isSection ? "s" : "")" }).joined(separator: ",")
    }

    static func run(entries: [Entry], output: URL, limit: Int) async throws {
        let chosen = limit > 0 ? Array(entries.prefix(limit)) : entries
        _ = AnalysisBackend.isGPUAvailable
        if let warm = chosen.first, let s = try? await decodeMono(URL(fileURLWithPath: warm.path), maxSeconds: 20) {
            _ = extract(s, backend: .gpu)
        }
        var rows = ["file\tseconds\tcpu_features_s\tgpu_features_s\tanalyze_s\tbeats\tbeat_max_ms\tbpm_cpu\tbpm_gpu\tkey_cpu\tkey_gpu\tdownbeat_max_ms\tsections_equal\tarrangement_equal\tbar_level_max\tfeature_rel_max\tchroma_abs_max\tpass"]
        var failures: [String] = []
        var cpuThread = 0.0, gpuThread = 0.0
        var cpuTotal = 0.0, gpuTotal = 0.0, analyzeTotal = 0.0, decodeTotal = 0.0, audio = 0.0
        var passed = 0, compared = 0
        for (n, entry) in chosen.enumerated() {
            let url = URL(fileURLWithPath: entry.path)
            let t0 = now()
            guard let samples = try? await decodeMono(url) else { print("skip \(entry.path)"); continue }
            decodeTotal += now() - t0
            let seconds = Double(samples.count) / BeatTracker.sampleRate
            audio += seconds
            let t1 = now(), c1 = MixCPU.threadCPU()
            let cpu = extract(samples, backend: .cpu)
            let t2 = now(), c2 = MixCPU.threadCPU()
            let gpu = extract(samples, backend: .gpu)
            let t3 = now(), c3 = MixCPU.threadCPU()
            cpuThread += c2 - c1
            gpuThread += c3 - c2
            cpuTotal += t2 - t1
            gpuTotal += t3 - t2
            let rc = BeatTracker.analyze(cpu, tempoPrior: nil)
            let t4 = now()
            let rg = BeatTracker.analyze(gpu, tempoPrior: nil)
            analyzeTotal += t4 - t3
            compared += 1
            let beatDelta = maxDelta(rc.beats, rg.beats)
            let downDelta = maxDelta(rc.downbeats, rg.downbeats)
            let bpmOK = (rc.bpm == nil && rg.bpm == nil) || (rc.bpm != nil && rg.bpm != nil && abs(rc.bpm! - rg.bpm!) <= 0.01 + 1e-9)
            let kc = key(cpu), kg = key(gpu)
            let sectionsEqual = rc.sectionStarts == rg.sectionStarts && rc.phraseStarts == rg.phraseStarts
            let arrangementEqual = sections(rc) == sections(rg)
            let levelDelta = maxDelta((rc.bars?.level ?? []).map(Double.init), (rg.bars?.level ?? []).map(Double.init))
            let bandsRel = [maxDelta(cpu.low, gpu.low), maxDelta(cpu.lowMid, gpu.lowMid), maxDelta(cpu.mid, gpu.mid), maxDelta(cpu.high, gpu.high)].map(\.rel).max() ?? 0
            let chromaAbs = max(maxDelta(cpu.chroma, gpu.chroma).abs, maxDelta(cpu.bandEnergy, gpu.bandEnergy).abs)
            let ok = beatDelta <= 0.001 && downDelta <= 0.001 && bpmOK && kc == kg && sectionsEqual && arrangementEqual && levelDelta <= 0.1
            if ok { passed += 1 } else { failures.append(url.lastPathComponent) }
            rows.append([
                url.lastPathComponent, String(format: "%.1f", seconds), String(format: "%.3f", t2 - t1), String(format: "%.3f", t3 - t2),
                String(format: "%.3f", t4 - t3), "\(rc.beats.count)/\(rg.beats.count)", String(format: "%.3f", beatDelta * 1000),
                rc.bpm.map { String($0) } ?? "nil", rg.bpm.map { String($0) } ?? "nil", kc, kg, String(format: "%.3f", downDelta * 1000),
                "\(sectionsEqual)", "\(arrangementEqual)", String(format: "%.2f", levelDelta), String(format: "%.2e", bandsRel), String(format: "%.2e", chromaAbs), ok ? "pass" : "FAIL"
            ].joined(separator: "\t"))
            print("[\(n + 1)/\(chosen.count)] \(ok ? "pass" : "FAIL") cpu \(String(format: "%.3f", t2 - t1)) gpu \(String(format: "%.3f", t3 - t2)) rel \(String(format: "%.1e", bandsRel)) \(url.lastPathComponent)")
        }
        let minutes = audio / 60
        let summary = """
        tracks compared: \(compared), pass: \(passed), fail: \(compared - passed)
        audio minutes: \(String(format: "%.1f", minutes))
        decode ms/min: \(String(format: "%.1f", decodeTotal / minutes * 1000))
        features cpu ms/min: \(String(format: "%.1f", cpuTotal / minutes * 1000))
        features gpu ms/min: \(String(format: "%.1f", gpuTotal / minutes * 1000))
        features speed-up: \(String(format: "%.2fx", cpuTotal / max(1e-9, gpuTotal)))
        features thread CPU ms/min: cpu path \(String(format: "%.1f", cpuThread / minutes * 1000)), gpu path \(String(format: "%.1f", gpuThread / minutes * 1000))
        analyze ms/min (per run): \(String(format: "%.1f", analyzeTotal / minutes * 1000))
        failures: \(failures.joined(separator: " | "))
        """
        print(summary)
        try rows.joined(separator: "\n").write(to: output.appendingPathComponent("parity.tsv"), atomically: true, encoding: .utf8)
        try summary.write(to: output.appendingPathComponent("parity-summary.txt"), atomically: true, encoding: .utf8)
    }
}
