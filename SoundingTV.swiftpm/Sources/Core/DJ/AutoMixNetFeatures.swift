import Foundation

nonisolated struct MixWindowBands: Codable, Equatable, Sendable {
    var before: [Double]
    var during: [Double]
    var after: [Double]
    var lowOverlap: Double
    var maxLevelJumpDecibels: Double?
    var spectralFlux: Double?

    static let bandCount = 3
}

nonisolated struct AutoMixNetObservation: Codable, Equatable, Sendable {
    var moveType: String
    var blendBars: Double
    var energyStep: Double?
    var bands: MixWindowBands?
    var vocalOverlapSeconds: Double?
    var phaseErrorBeats: Double?
    var gridConfidence: Double?
    var keyDistance: Int?
    var bpmDeltaPercent: Double?
    var exitSection: String
    var entrySection: String
    var peakProximityBars: Double?

    init(
        moveType: String,
        blendBars: Double,
        energyStep: Double? = nil,
        bands: MixWindowBands? = nil,
        vocalOverlapSeconds: Double? = nil,
        phaseErrorBeats: Double? = nil,
        gridConfidence: Double? = nil,
        keyDistance: Int? = nil,
        bpmDeltaPercent: Double? = nil,
        exitSection: String = "unknown",
        entrySection: String = "unknown",
        peakProximityBars: Double? = nil
    ) {
        self.moveType = moveType
        self.blendBars = blendBars
        self.energyStep = energyStep
        self.bands = bands
        self.vocalOverlapSeconds = vocalOverlapSeconds
        self.phaseErrorBeats = phaseErrorBeats
        self.gridConfidence = gridConfidence
        self.keyDistance = keyDistance
        self.bpmDeltaPercent = bpmDeltaPercent
        self.exitSection = exitSection
        self.entrySection = entrySection
        self.peakProximityBars = peakProximityBars
    }
}

nonisolated enum AutoMixNetFeatures {
    static let sectionGroups = ["intro", "build", "drop", "breakdown", "outro", "unknown"]
    static let moveGroups = ["blend", "cut", "loop", "drop", "echo", "tempo"]
    static let bandNames = ["low", "mid", "high"]

    static let names: [String] = {
        var names = ["energyStep"]
        for phase in ["before", "during", "after"] {
            for band in bandNames { names.append("\(band)\(phase.capitalized)") }
        }
        names += [
            "vocalOverlap", "phaseError", "gridConfidence", "keyDistance", "bpmDelta",
            "peakProximity", "maxLevelJump", "spectralFlux", "lowOverlap", "blendLength"
        ]
        names += sectionGroups.map { "exit.\($0)" }
        names += sectionGroups.map { "entry.\($0)" }
        names += moveGroups.map { "move.\($0)" }
        return names
    }()

    static var count: Int { names.count }

    static func sectionGroup(_ raw: String) -> String {
        switch raw {
        case "ambientIntro", "intro": return "intro"
        case "buildup", "build": return "build"
        case "drop": return "drop"
        case "breakdown", "bridge", "cooldown": return "breakdown"
        case "outro", "ambientOutro": return "outro"
        default: return "unknown"
        }
    }

    static func moveGroup(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("loop") { return "loop" }
        if lower.contains("echo") { return "echo" }
        if lower.contains("tempo") || lower == "bridge" { return "tempo" }
        if lower.contains("dropin") || lower.contains("fxbuild") || lower.contains("breakdownexit") { return "drop" }
        if lower.contains("cut") || lower.contains("dropontheone") || lower == "jump" { return "cut" }
        return "blend"
    }

    static func vector(_ o: AutoMixNetObservation) -> [Float] {
        func f(_ x: Double?) -> Float { x.map { $0.isFinite ? Float($0) : .nan } ?? .nan }
        var v: [Float] = [f(o.energyStep)]
        for phase in 0..<3 {
            for band in 0..<MixWindowBands.bandCount {
                let values = o.bands.map { [$0.before, $0.during, $0.after][phase] }
                v.append(f(values.flatMap { band < $0.count ? $0[band] : nil }))
            }
        }
        v.append(f(o.vocalOverlapSeconds))
        v.append(f(o.phaseErrorBeats.map(abs)))
        v.append(f(o.gridConfidence))
        v.append(f(o.keyDistance.map(Double.init)))
        v.append(f(o.bpmDeltaPercent.map(abs)))
        v.append(f(o.peakProximityBars.map { min(32, max(0, $0)) }))
        v.append(f(o.bands?.maxLevelJumpDecibels))
        v.append(f(o.bands?.spectralFlux))
        v.append(f(o.bands?.lowOverlap))
        v.append(Float(log2(1 + max(0, o.blendBars))))
        let exit = sectionGroup(o.exitSection)
        let entry = sectionGroup(o.entrySection)
        let move = moveGroup(o.moveType)
        v += sectionGroups.map { $0 == exit ? 1 : 0 }
        v += sectionGroups.map { $0 == entry ? 1 : 0 }
        v += moveGroups.map { $0 == move ? 1 : 0 }
        return v
    }

    static func energyStep(outgoingLevels: [Float], exitBar: Int, incomingLevels: [Float], entryBar: Int, blendBars: Int) -> Double? {
        func mean(_ levels: [Float], _ range: Range<Int>) -> Double? {
            let values = range.clamped(to: 0..<levels.count).map { Double(levels[$0]) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        guard let a = mean(outgoingLevels, (exitBar - 8)..<exitBar),
              let b = mean(incomingLevels, (entryBar + blendBars)..<(entryBar + blendBars + 8)) else { return nil }
        return b - a
    }

    static func peakProximity(levels: [Float], from bar: Int, horizon: Int = 32, jumpDecibels: Float = 4) -> Double? {
        guard bar >= 0, bar < levels.count else { return nil }
        for k in max(bar, 4)..<min(levels.count, bar + horizon) {
            let previous = levels[(k - 4)..<k].reduce(0, +) / 4
            if levels[k] - previous >= jumpDecibels { return Double(k - bar) }
        }
        return Double(horizon)
    }

    static func residualTempoPercent(outgoingBPM: Double, incomingBPM: Double, rate: Double) -> Double? {
        guard outgoingBPM > 0, incomingBPM > 0, rate > 0 else { return nil }
        let played = incomingBPM * rate
        return [played, played * 2, played / 2].map { abs($0 / outgoingBPM - 1) * 100 }.min()
    }

    static func phaseErrorBeats(_ seconds: TimeInterval, downbeats: [TimeInterval], beatPeriod: Double) -> Double? {
        guard beatPeriod > 0, let nearest = downbeats.min(by: { abs($0 - seconds) < abs($1 - seconds) }) else { return nil }
        let beats = (seconds - nearest) / beatPeriod
        return abs(beats - beats.rounded())
    }

    // MARK: - Mix window bands

    static func estimatedBands(
        outgoingBars: [[Double]],
        exitBar: Int,
        incomingBars: [[Double]],
        entryBar: Int,
        blendBars: Int,
        bassSwapFraction: Double,
        bassSwapBars: Double = 0.25
    ) -> MixWindowBands? {
        guard !outgoingBars.isEmpty, !incomingBars.isEmpty else { return nil }
        func bar(_ bars: [[Double]], _ i: Int) -> [Double]? {
            guard i >= 0, i < bars.count, bars[i].count >= MixWindowBands.bandCount else { return nil }
            return bars[i]
        }
        func mean(_ rows: [[Double]]) -> [Double] {
            guard !rows.isEmpty else { return [Double](repeating: .nan, count: MixWindowBands.bandCount) }
            return (0..<MixWindowBands.bandCount).map { k in rows.map { $0[k] }.reduce(0, +) / Double(rows.count) }
        }
        let length = max(1, blendBars)
        let before = mean((exitBar - 4..<exitBar).compactMap { bar(outgoingBars, $0) })
        let after = mean((entryBar + length..<entryBar + length + 4).compactMap { bar(incomingBars, $0) })
        var during: [[Double]] = []
        var doubled = 0
        var levels: [Double] = before.contains(where: { !$0.isFinite }) ? [] : [power(before)]
        let swapBar = bassSwapFraction * Double(length)
        let swapWidth = max(0.25, bassSwapBars)
        for k in 0..<length {
            let a = bar(outgoingBars, exitBar + k)
            let b = bar(incomingBars, entryBar + k)
            let fade = (Double(k) + 0.5) / Double(length)
            let t = (Double(k) + 0.5 - swapBar) / swapWidth
            let incomingLow = min(1, max(0, t + 0.5))
            var row: [Double] = []
            for band in 0..<MixWindowBands.bandCount {
                let outGain = band == 0 ? 1 - incomingLow : 1 - fade
                let inGain = band == 0 ? incomingLow : fade
                let x = (a.map { exp($0[band]) } ?? 0) * outGain + (b.map { exp($0[band]) } ?? 0) * inGain
                row.append(log(max(1e-9, x)))
            }
            if let a, let b, incomingLow > 0.05, incomingLow < 0.95, a[0] > before[0] - 1, b[0] > after[0] - 1 { doubled += 1 }
            during.append(row)
            levels.append(power(row))
        }
        if !after.contains(where: { !$0.isFinite }) { levels.append(power(after)) }
        let jump = zip(levels, levels.dropFirst()).map { abs($1 - $0) }.max()
        return MixWindowBands(
            before: before, during: mean(during), after: after,
            lowOverlap: Double(doubled) / Double(length),
            maxLevelJumpDecibels: jump.map { $0 * 10 / log(10) },
            spectralFlux: nil
        )
    }

    private static func power(_ row: [Double]) -> Double {
        log(max(1e-9, row.prefix(MixWindowBands.bandCount).map(exp).reduce(0, +)))
    }

    static func barBands(_ profile: BarProfile?) -> [[Double]] {
        guard let bands = profile?.bands, bands.count >= 4 else { return [] }
        return stride(from: 0, to: bands.count - 3, by: 4).map { i in
            let mid = log(max(1e-9, exp(Double(bands[i + 1])) + exp(Double(bands[i + 2]))))
            return [Double(bands[i]), mid, Double(bands[i + 3])]
        }
    }

    static func measuredBands(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        exitSeconds: TimeInterval,
        windowSeconds: TimeInterval,
        context: TimeInterval = 8
    ) -> MixWindowBands? {
        let count = min(left.count, right.count)
        let hop = max(1, Int(sampleRate * 0.25))
        guard count > hop * 8 else { return nil }
        let lowCoefficient = Float(1 - exp(-2 * Double.pi * 200 / sampleRate))
        let highCoefficient = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
        var low: Float = 0, belowHigh: Float = 0
        var sums = [[Double]](repeating: [0, 0, 0], count: count / hop)
        for i in 0..<(sums.count * hop) {
            let x = 0.5 * (left[i] + right[i])
            low += lowCoefficient * (x - low)
            belowHigh += highCoefficient * (x - belowHigh)
            let parts = [low, belowHigh - low, x - belowHigh]
            for k in 0..<3 { sums[i / hop][k] += Double(parts[k] * parts[k]) }
        }
        let frames = sums.map { row in row.map { 10 * log10(max(1e-12, $0 / Double(hop))) } }
        func frame(_ seconds: TimeInterval) -> Int { min(frames.count, max(0, Int(seconds * sampleRate) / hop)) }
        func mean(_ range: Range<Int>) -> [Double] {
            let rows = frames[range.clamped(to: 0..<frames.count)]
            guard !rows.isEmpty else { return [.nan, .nan, .nan] }
            return (0..<3).map { k in rows.map { $0[k] }.reduce(0, +) / Double(rows.count) }
        }
        let start = frame(exitSeconds)
        let end = max(start + 1, frame(exitSeconds + windowSeconds))
        let before = mean(frame(exitSeconds - context)..<start)
        let during = mean(start..<end)
        let after = mean(end..<frame(exitSeconds + windowSeconds + context))
        let lowLimit = max(before[0], after[0]) + 3
        let doubled = frames[start..<min(end, frames.count)].filter { $0[0] > lowLimit }.count
        let total = frames.map { row in 10 * log10(max(1e-12, row.map { pow(10, $0 / 10) }.reduce(0, +))) }
        let smoothed = (0..<total.count).map { i -> Double in
            let lo = max(0, i - 1), hi = min(total.count, i + 3)
            return total[lo..<hi].reduce(0, +) / Double(hi - lo)
        }
        let scan = frame(exitSeconds - 2)..<min(smoothed.count, frame(exitSeconds + windowSeconds + 4))
        var jump = 0.0
        var flux = 0.0
        for i in scan where i >= 4 {
            jump = max(jump, abs(smoothed[i] - smoothed[i - 4]))
            var f = 0.0
            for k in 0..<3 { f += max(0, frames[i][k] - frames[i - 1][k]) }
            flux = max(flux, f / 3)
        }
        return MixWindowBands(
            before: before, during: during, after: after,
            lowOverlap: Double(doubled) / Double(max(1, end - start)),
            maxLevelJumpDecibels: jump, spectralFlux: flux
        )
    }
}
