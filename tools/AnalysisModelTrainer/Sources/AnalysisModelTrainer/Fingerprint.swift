import Foundation

enum Fingerprint {
    struct Landmark {
        let hash: UInt32
        let frame: Int
    }

    static func peaks(_ track: LabelTrack) -> [(Int, Int)] {
        let bands = track.bands, frames = track.frames
        let lo = 4, hi = min(bands, 56)
        var peaks: [(Int, Int)] = []
        let radiusT = 6, radiusB = 3
        var t = radiusT
        while t < frames - radiusT {
            var candidates: [(Float, Int)] = []
            for b in lo..<hi {
                let v = track.melValue(t, b)
                var isPeak = true
                outer: for dt in -radiusT...radiusT {
                    for db in -radiusB...radiusB where !(dt == 0 && db == 0) {
                        let bb = b + db
                        guard bb >= 0 && bb < bands else { continue }
                        if track.melValue(t + dt, bb) >= v { isPeak = false; break outer }
                    }
                }
                if isPeak { candidates.append((v, b)) }
            }
            for (_, b) in candidates.sorted(by: { $0.0 > $1.0 }).prefix(3) { peaks.append((t, b)) }
            t += 1
        }
        return peaks
    }

    static func landmarks(_ track: LabelTrack) -> [Landmark] {
        let p = peaks(track)
        var out: [Landmark] = []
        for i in p.indices {
            var targets: [(Int, Int)] = []
            var j = i + 1
            while j < p.count && targets.count < 5 {
                let dt = p[j].0 - p[i].0
                if dt > 60 { break }
                if dt >= 4 { targets.append(p[j]) }
                j += 1
            }
            for a in targets.indices {
                for b in (a + 1)..<targets.count {
                    let d1 = UInt32((targets[a].0 - p[i].0) / 4), d2 = UInt32((targets[b].0 - p[i].0) / 4)
                    let hash = UInt32(p[i].1) << 26 | UInt32(targets[a].1) << 20 | UInt32(targets[b].1) << 14 | d1 << 7 | d2
                    out.append(Landmark(hash: hash, frame: p[i].0))
                }
            }
        }
        return out
    }

    struct Index {
        var table: [UInt32: [(Int32, Int32)]] = [:]
        var names: [String] = []
        var seconds: [Double] = []
    }

    static func index(_ tracks: [LabelTrack]) -> Index {
        var index = Index()
        for (n, track) in tracks.enumerated() {
            index.names.append(track.key)
            index.seconds.append(track.seconds)
            for l in landmarks(track) { index.table[l.hash, default: []].append((Int32(n), Int32(l.frame))) }
        }
        return index
    }

    struct Match {
        let reference: Int
        let block: Int
        let votes: Int
    }

    static let blockFrames = 1500

    static func matches(_ query: LabelTrack, against index: Index, skipSelf: String? = nil) -> [Match] {
        var votes: [Int: [Int: [Int: Int]]] = [:]
        for l in landmarks(query) {
            guard let hits = index.table[l.hash] else { continue }
            if hits.count > 400 { continue }
            let block = l.frame / blockFrames
            for (ref, frame) in hits {
                if let skipSelf, index.names[Int(ref)] == skipSelf { continue }
                let offsetBin = (l.frame - Int(frame)) / 50
                votes[Int(ref), default: [:]][block, default: [:]][offsetBin, default: 0] += 1
            }
        }
        var out: [Match] = []
        for (ref, blocks) in votes {
            for (block, bins) in blocks {
                var best = 0
                for (bin, v) in bins { best = max(best, v + (bins[bin + 1] ?? 0)) }
                out.append(Match(reference: ref, block: block, votes: best))
            }
        }
        return out
    }

    static func run(root: URL, sources: [String], threshold: Int) throws {
        let all = try loadTracks(root, sources: ["corpus"] + sources)
        let corpus = all.filter { $0.source == "corpus" }
        let test = corpus.filter { $0.split == .test }
        let t0 = Date()
        let index = index(test)
        print("indexed \(test.count) test tracks, \(index.table.count) hashes in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        var lines: [String] = []
        var report: [String] = []
        func scan(_ track: LabelTrack) -> [Match] { matches(track, against: index, skipSelf: track.key) }
        var calibration: [Int] = []
        for track in corpus.filter({ $0.split != .test }) {
            let best = scan(track).map(\.votes).max() ?? 0
            calibration.append(best)
            if best >= threshold {
                report.append("corpus-dupe \(track.key) best \(best)")
                lines.append("\(track.key)\t0\t\(String(format: "%.1f", track.seconds + 1))")
            }
        }
        var selfScores: [Int] = []
        for track in test.prefix(20) {
            let best = matches(track, against: index).filter { index.names[$0.reference] == track.key }.map(\.votes).max() ?? 0
            selfScores.append(best)
        }
        calibration.sort()
        selfScores.sort()
        print("calibration: non-test corpus best-block votes p50 \(calibration[calibration.count / 2]) p99 \(calibration[Int(Double(calibration.count) * 0.99)]) max \(calibration.last ?? 0); test self-match block votes min \(selfScores.first ?? 0) median \(selfScores[selfScores.count / 2])")
        for track in all where track.source != "corpus" {
            let hits = scan(track).filter { $0.votes >= threshold }
            guard !hits.isEmpty else { continue }
            let single = track.seconds < 20 * 60
            if single {
                lines.append("\(track.key)\t0\t\(String(format: "%.1f", track.seconds + 1))")
            } else {
                var ranges: [(Double, Double)] = []
                for h in hits.sorted(by: { $0.block < $1.block }) {
                    let a = max(0, Double(h.block * blockFrames) / 50 - 90), b = Double((h.block + 1) * blockFrames) / 50 + 90
                    if let last = ranges.last, a <= last.1 { ranges[ranges.count - 1].1 = max(last.1, b) } else { ranges.append((a, b)) }
                }
                for r in ranges { lines.append("\(track.key)\t\(String(format: "%.1f", r.0))\t\(String(format: "%.1f", r.1))") }
            }
            let refs = Set(hits.map { index.names[$0.reference] }).sorted().joined(separator: ",")
            report.append("\(track.key) \(String(format: "%.0f", track.seconds))s matches \(refs) best \(hits.map(\.votes).max() ?? 0)")
        }
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("exclusions.tsv"), atomically: true, encoding: .utf8)
        try report.joined(separator: "\n").write(to: root.appendingPathComponent("dedupe-report.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        print("excluded ranges: \(lines.count)")
    }
}
