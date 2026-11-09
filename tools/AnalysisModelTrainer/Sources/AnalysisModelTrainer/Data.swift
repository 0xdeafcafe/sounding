import Foundation

enum SafeTensorsWriter {
    static func write(_ tensors: [(String, [Int], [Float])], metadata: [String: String], to url: URL) throws {
        var header: [String: Any] = ["__metadata__": metadata]
        var offset = 0
        for (name, shape, values) in tensors {
            header[name] = ["dtype": "F32", "shape": shape, "data_offsets": [offset, offset + values.count * 4]]
            offset += values.count * 4
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }
        var data = Data()
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        for (_, _, values) in tensors { values.withUnsafeBytes { data.append(contentsOf: $0) } }
        try data.write(to: url)
    }
}

enum VocalRules {
    static let hopSeconds = 0.5
    static let enter: Float = 0.4
    static let leave: Float = 0.22
    static let bridgeSeconds = 2.0
    static let minimumRunSeconds = 1.0
    static let padSeconds = 0.5
    static let sustainedWindowSeconds = 8.0
    static let sustainedFloor: Float = 0.12
    static let sustainedOverBaseline: Float = 3
    static let baselinePercentile = 0.2
    static let sustainedMinimumSeconds = 16.0

    static func smoothed(_ curve: [Float]) -> [Float] {
        guard curve.count > 2 else { return curve }
        return curve.indices.map { i in
            [curve[max(0, i - 1)], curve[i], curve[min(curve.count - 1, i + 1)]].sorted()[1]
        }
    }

    static func ranges(_ curve: [Float]) -> [(Double, Double)] {
        let smooth = smoothed(curve)
        var runs: [(Double, Double)] = []
        var start: Int?
        for (i, value) in smooth.enumerated() {
            if start == nil {
                if value >= enter { start = i }
            } else if value < leave, let s = start {
                runs.append((Double(s) * hopSeconds, Double(i) * hopSeconds))
                start = nil
            }
        }
        if let s = start { runs.append((Double(s) * hopSeconds, Double(smooth.count) * hopSeconds)) }
        let strong = bridged(runs).filter { $0.1 - $0.0 >= minimumRunSeconds }.map { (max(0, $0.0 - padSeconds), $0.1 + padSeconds) }
        return bridged((strong + sustainedRuns(curve)).sorted { $0.0 < $1.0 }).map { (($0.0 * 100).rounded() / 100, ($0.1 * 100).rounded() / 100) }
    }

    static func bridged(_ runs: [(Double, Double)]) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for run in runs {
            if let last = merged.last, run.0 - last.1 < bridgeSeconds {
                merged[merged.count - 1].1 = max(last.1, run.1)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    static func sustainedRuns(_ curve: [Float]) -> [(Double, Double)] {
        let count = curve.count
        guard count > 2 else { return [] }
        let sorted = curve.sorted()
        let baseline = sorted[Int(baselinePercentile * Double(count - 1))]
        let threshold = max(sustainedFloor, sustainedOverBaseline * baseline)
        let half = Int(sustainedWindowSeconds / hopSeconds) / 2
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + Double(curve[i]) }
        var runs: [(Double, Double)] = []
        var start: Int?
        for i in 0...count {
            var on = false
            if i < count {
                let lo = max(0, i - half)
                let hi = min(count, i + half)
                on = (prefix[hi] - prefix[lo]) / Double(hi - lo) >= Double(threshold)
            }
            if on, start == nil { start = i }
            if !on, let s = start {
                if let first = (s..<i).first(where: { curve[$0] >= threshold }),
                   let last = (s..<i).last(where: { curve[$0] >= threshold }) {
                    runs.append((Double(max(0, first - 1)) * hopSeconds, Double(last + 1) * hopSeconds))
                }
                start = nil
            }
        }
        return bridged(runs).filter { $0.1 - $0.0 >= sustainedMinimumSeconds }
    }

    static func sung(_ curve: [Float], bars: [Double], end: Double) -> [Bool] {
        let r = ranges(curve).filter { $0.1 > $0.0 }
        return bars.indices.map { b in
            let lo = bars[b]
            let hi = max(lo, b + 1 < bars.count ? bars[b + 1] : end)
            return r.reduce(0) { $0 + max(0, min($1.1, hi) - max($1.0, lo)) } > 0.01
        }
    }
}
