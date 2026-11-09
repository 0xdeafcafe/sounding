import Foundation

nonisolated struct SetLearningCue: Codable, Equatable, Sendable {
    var seconds: Double
    var label: String?
    var earliest: Double?
    var latest: Double?
}

nonisolated struct SetLearningSource: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var genre: String?
    var origin: String
    var durationSeconds: Double
    var cues: [SetLearningCue]
}

nonisolated struct SetLearningTransition: Codable, Equatable, Sendable {
    var index: Int
    var detection: String
    var confidence: Double
    var cueSeconds: Double?
    var outgoingLabel: String?
    var incomingLabel: String?
    var boundarySeconds: Double
    var blendStartSeconds: Double
    var blendEndSeconds: Double
    var blendBars: Int
    var outgoingPhraseOffset: Int
    var incomingPhraseOffset: Int
    var startPhrasePosition: Int
    var endPhrasePosition: Int
    var phraseGridsAligned: Bool
    var bassSwapBar: Double?
    var bassSwapMethod: String
    var bassSwapPhrasePosition: Int?
    var doubleBassBars: Int
    var bassGapBars: Int
    var filter: String
    var filterBars: Int
    var loopBars: Int
    var loopLag: Int
    var energyStepDecibels: Double?
    var vocalDuringBlendSeconds: Double
    var bpmOut: Double?
    var bpmIn: Double?
    var bpmDeltaPercent: Double?
    var tempoRamp: Bool
    var rampBars: Int
    var keyOut: String?
    var keyIn: String?
    var keyDistance: Int?
    var echoOut: Bool
    var cut: Bool
    var move: String
    var exitSection: String
    var entrySection: String
    var bandsBefore: [Double]
    var bandsDuring: [Double]
    var bandsAfter: [Double]
    var maxLevelJumpDecibels: Double?
    var outgoingPlayedBars: Int
}

nonisolated struct SetLearningReport: Codable, Equatable, Sendable {
    var source: SetLearningSource
    var analysedSeconds: Double
    var bars: Int
    var bpmMedian: Double?
    var bpmStart: Double?
    var bpmEnd: Double?
    var bpmDriftPercent: Double?
    var energyArcDecibels: [Double]
    var bpmArc: [Double]
    var gridConfidence: Double
    var transitions: [SetLearningTransition]
    var spacingSecondsMedian: Double?
    var moveCounts: [String: Int]
}

nonisolated struct SetLearningBars: Sendable {
    var starts: [Double]
    var ends: [Double]
    var level: [Double]
    var bands: [[Double]]
    var bandsDB: [[Double]]
    var chroma: [[Double]]
    var vectors: [[Double]]
    var bpm: [Double]
    var vocal: [Double]
    var gridJump: [Double]

    var count: Int { starts.count }
}

nonisolated struct SetLearningEnvelope: Sendable {
    var times: [Double]
    var low: [Double]
    var mid: [Double]
    var high: [Double]
}

nonisolated enum SetLearning {
    static let majorPositionByPitchClass = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // MARK: - Bars

    static func bars(features: BeatTrackerFeatures, result: BeatTrackerResult) -> SetLearningBars {
        var downbeats = result.downbeats
        if downbeats.count < 16 {
            let beats = result.beats
            if beats.count >= 64 {
                downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
            } else {
                let period = 60.0 / (result.bpm ?? 124) * 4
                downbeats = Array(stride(from: 0, to: features.analysedSeconds, by: period))
            }
        }
        let beats = result.beats
        var out = SetLearningBars(starts: [], ends: [], level: [], bands: [], bandsDB: [], chroma: [], vectors: [], bpm: [], vocal: [], gridJump: [])
        let vocals = result.vocalSeconds ?? []
        var beatCursor = 0
        for b in 0..<downbeats.count {
            let start = downbeats[b]
            let end = b + 1 < downbeats.count ? downbeats[b + 1] : min(features.analysedSeconds, start + (b > 0 ? start - downbeats[b - 1] : 2))
            guard end > start + 0.3 else { continue }
            let f0 = max(0, Int(features.frame(ofTime: start).rounded()))
            let f1 = min(features.frameCount, max(f0 + 1, Int(features.frame(ofTime: end).rounded())))
            var levelSum = 0.0
            var lowPattern = [Double](repeating: 0, count: 16)
            var upperPattern = [Double](repeating: 0, count: 16)
            if f1 > f0 {
                for f in f0..<f1 {
                    if f < features.level.count { levelSum += Double(features.level[f]) }
                    let step = min(15, (f - f0) * 16 / max(1, f1 - f0))
                    lowPattern[step] += Double(features.low[f])
                    upperPattern[step] += Double(features.lowMid[f] + features.mid[f] + features.high[f])
                }
            }
            let level = 10 * log10(max(1e-10, levelSum / Double(max(1, f1 - f0))))
            let s0 = max(0, Int(features.slowIndex(ofTime: start).rounded()))
            let s1 = min(features.slowCount, max(s0 + 1, Int(features.slowIndex(ofTime: end).rounded())))
            var chroma = [Double](repeating: 0, count: 12)
            var bands = [Double](repeating: 0, count: 4)
            if s1 > s0 {
                for s in s0..<s1 {
                    for k in 0..<12 { chroma[k] += Double(features.chroma[s * 12 + k]) }
                    for k in 0..<4 { bands[k] += Double(features.bandEnergy[s * 4 + k]) }
                }
                for k in 0..<4 { bands[k] /= Double(s1 - s0) }
            }
            let bandsDB = bands.map { 20 * log10(max(1e-6, expm1($0))) }
            while beatCursor < beats.count, beats[beatCursor] < start { beatCursor += 1 }
            var intervals: [Double] = []
            var k = beatCursor
            while k + 1 < beats.count, beats[k] < end {
                intervals.append(beats[k + 1] - beats[k])
                k += 1
            }
            let beatPeriod = intervals.isEmpty ? (end - start) / 4 : median(intervals)
            let bpm = 60 / max(0.2, beatPeriod)
            let expected = (end - start) / 4
            let jump = intervals.map { abs($0 / max(0.05, expected) - 1) }.max() ?? 0
            let vocalSeconds = vocals.reduce(0.0) { acc, r in acc + max(0, min(end, r.upperBound) - max(start, r.lowerBound)) }
            out.starts.append(start)
            out.ends.append(end)
            out.level.append(level)
            out.bands.append(bands)
            out.bandsDB.append(bandsDB)
            out.chroma.append(chroma)
            out.vectors.append(unit(chroma) + unit(lowPattern) + unit(upperPattern) + bands.map { $0 * 0.25 })
            out.bpm.append(bpm)
            out.vocal.append(vocalSeconds / (end - start))
            out.gridJump.append(jump)
        }
        return out
    }

    static func envelope(features: BeatTrackerFeatures, from: Double, to: Double) -> SetLearningEnvelope {
        let s0 = max(0, Int(features.slowIndex(ofTime: from)))
        let s1 = min(features.slowCount, Int(features.slowIndex(ofTime: to)) + 1)
        var env = SetLearningEnvelope(times: [], low: [], mid: [], high: [])
        guard s1 > s0 else { return env }
        let slowSeconds = Double(features.hop * features.slowStride) / features.sampleRate
        func db(_ x: Float) -> Double { 20 * log10(max(1e-6, expm1(Double(x)))) }
        for s in s0..<s1 {
            env.times.append(Double(s) * slowSeconds)
            env.low.append(db(features.bandEnergy[s * 4]))
            let mid = expm1(Double(features.bandEnergy[s * 4 + 1])) + expm1(Double(features.bandEnergy[s * 4 + 2]))
            env.mid.append(20 * log10(max(1e-6, mid)))
            env.high.append(db(features.bandEnergy[s * 4 + 3]))
        }
        return env
    }

    // MARK: - Novelty

    static func novelty(_ bars: SetLearningBars, width: Int = 16) -> [Double] {
        let n = bars.count
        var ssm = [Double](repeating: 0, count: n)
        for b in 0..<n {
            var cross = 0.0, within = 0.0, cn = 0.0, wn = 0.0
            for i in max(0, b - width)..<b {
                for j in b..<min(n, b + width) {
                    let g = exp(-pow(Double(b - i) / Double(width) * 1.5, 2)) * exp(-pow(Double(j - b) / Double(width) * 1.5, 2))
                    cross += g * cosine(bars.vectors[i], bars.vectors[j]); cn += g
                }
            }
            for side in [max(0, b - width)..<b, b..<min(n, b + width)] where side.count > 1 {
                let idx = Array(side)
                for x in stride(from: 0, to: idx.count, by: 2) {
                    for y in stride(from: x + 1, to: idx.count, by: 3) {
                        within += cosine(bars.vectors[idx[x]], bars.vectors[idx[y]]); wn += 1
                    }
                }
            }
            ssm[b] = (wn > 0 ? within / wn : 0) - (cn > 0 ? cross / cn : 0)
        }
        var key = [Double](repeating: 0, count: n)
        for b in 0..<n {
            let a = meanVector(bars.chroma, max(0, b - width)..<b)
            let c = meanVector(bars.chroma, b..<min(n, b + width))
            key[b] = a.isEmpty || c.isEmpty ? 0 : 1 - cosine(a, c)
        }
        let low = bars.bandsDB.map { $0[0] }
        var dip = [Double](repeating: 0, count: n)
        for b in 0..<n {
            let around = Array(low[max(0, b - 16)..<min(n, b + 16)])
            dip[b] = max(0, median(around) - low[b]) / 6
        }
        let grid = bars.gridJump.map { min(1, $0 / 0.25) }
        let ident = identity(bars)
        let zs = zScored(ssm), zk = zScored(key), zd = zScored(smooth(dip, 2)), zg = zScored(smooth(grid, 1)), zi = zScored(smooth(ident, 2))
        return (0..<n).map { 0.5 * max(0, zi[$0]) + 0.25 * max(0, zs[$0]) + 0.1 * max(0, zk[$0]) + 0.1 * max(0, zd[$0]) + 0.05 * max(0, zg[$0]) }
    }

    static func identityVector(_ v: [Double]) -> [Double] {
        Array(v.prefix(12)) + (v.count >= 44 ? Array(v[28..<44]) : [])
    }

    static func identity(_ bars: SetLearningBars, gap: Int = 8, span: Int = 32) -> [Double] {
        let n = bars.count
        let rows = bars.vectors.map(identityVector)
        return (0..<n).map { b in
            let a = meanVector(rows, max(0, b - gap - span)..<max(0, b - gap))
            let c = meanVector(rows, min(n, b + gap)..<min(n, b + gap + span))
            return a.isEmpty || c.isEmpty ? 0 : 1 - cosine(a, c)
        }
    }

    static func anchor(_ bars: SetLearningBars) -> [Double] {
        zScored(smooth(identity(bars, gap: 4, span: 24), 1))
    }

    static func boundaries(novelty: [Double], bars: SetLearningBars, cues: [SetLearningCue], anchor: [Double]? = nil) -> [(bar: Int, confidence: Double, cue: Int?)] {
        let n = bars.count
        let usable = cues.enumerated().filter { $0.element.seconds > 30 && $0.element.seconds < (bars.ends.last ?? 0) - 30 }
        if usable.count >= 2 {
            let score = anchor ?? novelty
            var picked: [(Int, Double, Int?)] = []
            for (i, cue) in usable {
                var centre = barIndex(cue.seconds, bars)
                let barSeconds = (bars.ends[centre] - bars.starts[centre])
                var radius = anchor == nil ? max(24, Int(50 / max(0.5, barSeconds))) : max(12, Int(36 / max(0.5, barSeconds)))
                var lo = max(4, centre - radius), hi = min(n - 4, centre + radius)
                if anchor != nil, let earliest = cue.earliest, let latest = cue.latest, latest > earliest {
                    lo = max(4, barIndex(earliest, bars))
                    hi = min(n - 4, max(lo + 1, barIndex(latest, bars)))
                    centre = min(hi - 1, max(lo, barIndex(min(latest, cue.seconds + 30), bars)))
                    radius = max(8, (hi - lo) / 2)
                }
                guard hi > lo else { continue }
                var best = centre, bestScore = -Double.infinity
                for b in lo..<hi {
                    let prior = exp(-pow(Double(b - centre) / Double(radius), 2) * (anchor == nil ? 0.7 : 1.5))
                    let s = anchor == nil ? score[b] * (0.6 + 0.4 * prior) : score[b] + 1.5 * prior
                    if s > bestScore { bestScore = s; best = b }
                }
                let windowMedian = median(Array(score[lo..<hi]))
                let confidence = min(1, max(0, (score[best] - windowMedian) / 2.5))
                if let last = picked.last, best - last.0 < 12 { continue }
                picked.append((best, confidence, i))
            }
            return picked
        }
        let smoothed = smooth(novelty, 1)
        var order = Array(32..<max(32, n - 32)).sorted { smoothed[$0] > smoothed[$1] }
        var picked: [Int] = []
        let spacing = 48
        while let b = order.first {
            order.removeFirst()
            guard smoothed[b] >= 1.0 else { break }
            if picked.contains(where: { abs($0 - b) < spacing }) { continue }
            picked.append(b)
        }
        return picked.sorted().map { ($0, min(1, max(0, (smoothed[$0] - 1) / 2)), nil) }
    }

    // MARK: - Transitions

    static func analyse(source: SetLearningSource, features: BeatTrackerFeatures, result: BeatTrackerResult) -> (report: SetLearningReport, bars: SetLearningBars) {
        let bars = bars(features: features, result: result)
        let n = bars.count
        guard n > 64 else {
            return (SetLearningReport(source: source, analysedSeconds: features.analysedSeconds, bars: n, bpmMedian: nil, bpmStart: nil, bpmEnd: nil, bpmDriftPercent: nil, energyArcDecibels: [], bpmArc: [], gridConfidence: result.confidence, transitions: [], spacingSecondsMedian: nil, moveCounts: [:]), bars)
        }
        let nov = novelty(bars)
        let found = boundaries(novelty: nov, bars: bars, cues: source.cues, anchor: source.cues.count >= 2 ? anchor(bars) : nil)
        var transitions: [SetLearningTransition] = []
        for (i, f) in found.enumerated() {
            let prev = i > 0 ? found[i - 1].bar : 0
            let next = i + 1 < found.count ? found[i + 1].bar : n
            let cue = f.cue.map { source.cues[$0] }
            let outgoingLabel = f.cue.flatMap { $0 > 0 ? source.cues[$0 - 1].label : nil }
            transitions.append(measure(bars: bars, boundary: f.bar, previous: prev, next: next, confidence: f.confidence, cue: cue, outgoingLabel: outgoingLabel, index: i))
        }
        let bpmSmoothed = bars.bpm.map { normaliseTempo($0) }
        let tenth = max(1, n / 10)
        let bpmStart = median(Array(bpmSmoothed[0..<tenth]))
        let bpmEnd = median(Array(bpmSmoothed[(n - tenth)..<n]))
        let levelMedian = median(bars.level)
        let arc = (0..<10).map { k -> Double in
            let r = (k * n / 10)..<max(k * n / 10 + 1, (k + 1) * n / 10)
            return round1(median(Array(bars.level[r])) - levelMedian)
        }
        let bpmArc = (0..<10).map { k -> Double in
            let r = (k * n / 10)..<max(k * n / 10 + 1, (k + 1) * n / 10)
            return round1(median(Array(bpmSmoothed[r])))
        }
        let spacing = zip(transitions, transitions.dropFirst()).map { $1.boundarySeconds - $0.boundarySeconds }
        var counts: [String: Int] = [:]
        for t in transitions { counts[t.move, default: 0] += 1 }
        let report = SetLearningReport(
            source: source, analysedSeconds: features.analysedSeconds, bars: n,
            bpmMedian: round1(median(bpmSmoothed)), bpmStart: round1(bpmStart), bpmEnd: round1(bpmEnd),
            bpmDriftPercent: round1((bpmEnd / bpmStart - 1) * 100),
            energyArcDecibels: arc, bpmArc: bpmArc, gridConfidence: result.confidence,
            transitions: transitions, spacingSecondsMedian: spacing.isEmpty ? nil : round1(median(spacing)), moveCounts: counts
        )
        return (report, bars)
    }

    static func measure(bars: SetLearningBars, boundary B: Int, previous: Int, next: Int, confidence: Double, cue: SetLearningCue?, outgoingLabel: String?, index: Int) -> SetLearningTransition {
        let n = bars.count
        let aMid = (previous + B) / 2, bMid = (B + next) / 2
        let aCore = max(previous, min(aMid - 8, B - 40))..<max(previous + 1, min(B - 24, aMid + 8))
        let bCore = max(B + 24, bMid - 8)..<max(B + 25, min(next, bMid + 8))
        let aCoreR = clamp(aCore, n), bCoreR = clamp(bCore, n)
        let pa = meanVector(bars.vectors, aCoreR)
        let pb = meanVector(bars.vectors, bCoreR)
        let lo = max(0, B - 40), hi = min(n - 1, B + 40)
        var w = [Double](repeating: 0.5, count: n)
        let pai = identityVector(pa), pbi = identityVector(pb)
        let diff = zip(pbi, pai).map { $0 - $1 }
        let norm2 = diff.reduce(0) { $0 + $1 * $1 }
        if norm2 > 1e-6 {
            for b in lo...hi {
                let x = identityVector(bars.vectors[b])
                var dot = 0.0
                for k in 0..<min(x.count, diff.count) { dot += (x[k] - pai[k]) * diff[k] }
                w[b] = min(1, max(0, dot / norm2))
            }
        }
        let ws = smooth(w, 1)
        var start = B
        while start > max(lo, previous + 4), ws[start - 1] > 0.15 { start -= 1 }
        var end = B
        while end < min(hi, next - 4), ws[end] < 0.85 { end += 1 }
        if end < start { end = start }
        let blendBars = end - start
        let low = bars.bandsDB.map { $0[0] }
        let mid = bars.bandsDB.map { 10 * log10(max(1e-12, pow(10, $0[1] / 10) + pow(10, $0[2] / 10))) }
        let high = bars.bandsDB.map { $0[3] }
        let offA = phraseOffset(bars, aCoreR.lowerBound == aCoreR.upperBound ? max(previous, B - 32)..<B : max(previous, B - 64)..<max(previous + 1, start))
        let offB = phraseOffset(bars, min(n - 1, end)..<min(n, max(end + 1, min(next, end + 64))))
        let startPos = mod(start - offA, 8)
        let endPos = mod(end - offB, 8)
        let preRange = clamp(max(0, start - 8)..<start, n)
        let postRange = clamp(end..<min(n, end + 8), n)
        let lowPre = median(Array(low[preRange])), lowPost = median(Array(low[postRange]))
        var gap = 0, doubled = 0
        var firstGap: Int?
        var lastDouble: Int?
        if blendBars > 0 {
            for b in start..<end {
                if low[b] < min(lowPre, lowPost) - 6 { gap += 1; if firstGap == nil { firstGap = b } }
                if low[b] > max(lowPre, lowPost) + 1.5 { doubled += 1; lastDouble = b }
            }
        }
        var swap: Double?
        var method = "none"
        if blendBars >= 2 {
            var killEnd: Int?
            if let g = firstGap {
                var e = g
                while e + 1 < end, low[e + 1] < min(lowPre, lowPost) - 6 { e += 1 }
                if e - g < 8 { killEnd = e }
            }
            if let e = killEnd {
                swap = Double(e + 1 - start); method = "kill"
            } else if let d = lastDouble {
                swap = Double(d + 1 - start); method = "doubleThenSwap"
            } else {
                var bestStep = 0.0, bestBar = start
                for b in (start + 1)..<max(start + 2, end + 1) where b < n {
                    let step = abs(low[b] - low[b - 1])
                    if step > bestStep { bestStep = step; bestBar = b }
                }
                if bestStep > 2 {
                    swap = Double(bestBar - start); method = "step"
                } else if let cross = (start..<end).first(where: { ws[$0] >= 0.5 }) {
                    swap = Double(cross - start); method = "crossfade"
                }
            }
        }
        let swapPhrase = swap.map { mod(start + Int($0) - offB, 8) }
        let window = clamp(max(0, max(start - 4, B - 24))..<min(n, min(end + 4, B + 24)), n)
        let lowSweep = sweep(low, window, falling: true)
        let highSweepDown = sweep(high, window, falling: true)
        let highSweepUp = sweep(high, window, falling: false)
        let midStable = (median(Array(mid[preRange])) - median(Array(mid[clamp(start..<max(start + 1, end), n)]))) < 4
        var filter = "none", filterBars = 0
        if lowSweep.bars >= 4, lowSweep.depth >= 9, midStable { filter = "hpf"; filterBars = lowSweep.bars }
        if max(highSweepDown.bars, highSweepUp.bars) >= 4, max(highSweepDown.depth, highSweepUp.depth) >= 9 {
            let lpfBars = max(highSweepDown.bars, highSweepUp.bars)
            filter = filter == "hpf" ? "both" : "lpf"
            filterBars = max(filterBars, lpfBars)
        }
        var loopBars = 0, loopLag = 0
        for lag in [1, 2, 4] {
            var baseline: [Double] = []
            for b in aCoreR where b - lag >= 0 { baseline.append(cosine(bars.vectors[b], bars.vectors[b - lag])) }
            let threshold = max(0.985, percentile(baseline, 0.9) + 0.004)
            var run = 0, best = 0
            for b in max(lag, start - 16)..<max(lag, min(n, end)) {
                if cosine(bars.vectors[b], bars.vectors[b - lag]) >= threshold { run += 1; best = max(best, run) } else { run = 0 }
            }
            if best >= max(8, 4 * lag), best > loopBars { loopBars = best; loopLag = lag }
        }
        let levelPre = mean(Array(bars.level[preRange]))
        let levelPost = mean(Array(bars.level[postRange]))
        let blendStartSeconds = bars.starts[min(n - 1, start)]
        let blendEndSeconds = bars.starts[min(n - 1, end)]
        let vocalSeconds = blendBars > 0 ? (start..<end).reduce(0.0) { $0 + bars.vocal[$1] * (bars.ends[$1] - bars.starts[$1]) } : 0
        let tempo = bars.bpm.map { normaliseTempo($0) }
        let bpmOut = median(Array(tempo[clamp(max(0, start - 16)..<max(1, start), n)]))
        let bpmIn = median(Array(tempo[clamp(end..<min(n, end + 16), n)]))
        let delta = (bpmIn / bpmOut - 1) * 100
        var rampBars = 0
        if abs(delta) > 0.6 {
            let span = bpmIn - bpmOut
            for b in clamp(max(0, start - 32)..<min(n, end + 32), n) {
                let t = (median(Array(tempo[clamp(max(0, b - 2)..<min(n, b + 3), n)])) - bpmOut) / span
                if t > 0.2, t < 0.8 { rampBars += 1 }
            }
        }
        let ramp = rampBars >= 4
        let keyOut = key(meanVector(bars.chroma, aCoreR))
        let keyIn = key(meanVector(bars.chroma, bCoreR))
        let keyDistance: Int? = keyOut.flatMap { a in keyIn.map { b in camelotDistance(a, b) } }
        let dipRange = clamp(max(0, B - 2)..<min(n, B + 2), n)
        let dip = levelPre - (bars.level[dipRange].min() ?? levelPre)
        let lowDrop = lowPre - (low[dipRange].min() ?? lowPre)
        let echo = blendBars <= 2 && dip >= 6 && lowDrop >= 10
        let cut = blendBars <= 1 && !echo
        let exitSection = section(lowRel: lowPre - median(Array(low[aCoreR])), midRel: median(Array(mid[preRange])) - median(Array(mid[aCoreR])), levelRel: levelPre - median(Array(bars.level[aCoreR])), outgoing: true)
        let entrySection = section(lowRel: lowPost - median(Array(low[bCoreR])), midRel: median(Array(mid[postRange])) - median(Array(mid[bCoreR])), levelRel: levelPost - median(Array(bars.level[bCoreR])), outgoing: false)
        let move: String
        if echo { move = "echoOut" }
        else if cut { move = entrySection == "drop" ? "dropOnTheOne" : "cut" }
        else if ramp { move = "tempoBlend" }
        else if loopBars >= 8 { move = "loopBlend" }
        else if filter != "none" { move = filter == "lpf" ? "filterBlend" : "hpfBlend" }
        else if blendBars <= 4, entrySection == "drop" { move = "dropIn" }
        else if method == "kill" || method == "step" { move = "bassSwap" }
        else { move = "eqBlend" }
        func bandRow(_ r: Range<Int>) -> [Double] {
            let rows = r.isEmpty ? [] : r.map { b -> [Double] in
                let bands = bars.bands[b]
                let m = log(max(1e-9, exp(bands[1]) + exp(bands[2])))
                return [bands[0], m, bands[3]]
            }
            return rows.isEmpty ? [] : (0..<3).map { k in round3(rows.map { $0[k] }.reduce(0, +) / Double(rows.count)) }
        }
        let jumpRange = clamp(max(1, start - 4)..<min(n, end + 4), n)
        let jump = jumpRange.map { abs(bars.level[$0] - bars.level[$0 - 1]) }.max()
        return SetLearningTransition(
            index: index, detection: cue == nil ? "audio" : "tracklist", confidence: round3(confidence),
            cueSeconds: cue.map { round1($0.seconds) }, outgoingLabel: outgoingLabel, incomingLabel: cue?.label,
            boundarySeconds: round1(bars.starts[B]), blendStartSeconds: round1(blendStartSeconds), blendEndSeconds: round1(blendEndSeconds),
            blendBars: blendBars, outgoingPhraseOffset: offA, incomingPhraseOffset: offB,
            startPhrasePosition: startPos, endPhrasePosition: endPos, phraseGridsAligned: offA == offB,
            bassSwapBar: swap, bassSwapMethod: method, bassSwapPhrasePosition: swapPhrase,
            doubleBassBars: doubled, bassGapBars: gap, filter: filter, filterBars: filterBars,
            loopBars: loopBars, loopLag: loopLag,
            energyStepDecibels: levelPre.isFinite && levelPost.isFinite ? round1(levelPost - levelPre) : nil,
            vocalDuringBlendSeconds: round1(vocalSeconds),
            bpmOut: round1(bpmOut), bpmIn: round1(bpmIn), bpmDeltaPercent: round1(delta), tempoRamp: ramp, rampBars: rampBars,
            keyOut: keyOut, keyIn: keyIn, keyDistance: keyDistance,
            echoOut: echo, cut: cut, move: move, exitSection: exitSection, entrySection: entrySection,
            bandsBefore: bandRow(preRange), bandsDuring: bandRow(clamp(start..<end, n)), bandsAfter: bandRow(postRange),
            maxLevelJumpDecibels: jump.map(round1), outgoingPlayedBars: max(0, start - previous)
        )
    }

    static func section(lowRel: Double, midRel: Double, levelRel: Double, outgoing: Bool) -> String {
        if lowRel < -6 { return levelRel < -6 ? (outgoing ? "outro" : "intro") : "breakdown" }
        if midRel < -3 { return outgoing ? "outro" : "intro" }
        if levelRel < -3 { return outgoing ? "outro" : "build" }
        return "drop"
    }

    static func sweep(_ series: [Double], _ range: Range<Int>, falling: Bool) -> (bars: Int, depth: Double) {
        guard range.count >= 3 else { return (0, 0) }
        let s = range.map { falling ? -series[$0] : series[$0] }
        var best = (0, 0.0)
        for i in 0..<s.count {
            var j = i
            var lastStep = 0.0
            while j + 1 < s.count, s[j + 1] >= s[j] - 0.5 { j += 1; lastStep = max(lastStep, s[j] - s[j - 1]) }
            let depth = s[j] - s[i]
            if j - i >= 3, depth > 0, lastStep < 0.6 * depth, depth > best.1 { best = (j - i, depth) }
        }
        return best
    }

    static func phraseOffset(_ bars: SetLearningBars, _ range: Range<Int>) -> Int {
        let r = clamp(range, bars.count)
        guard r.count >= 16 else { return 0 }
        var score = [Double](repeating: 0, count: 8)
        var counts = [Double](repeating: 0, count: 8)
        for b in r where b >= 1 {
            let change = (1 - cosine(bars.vectors[b], bars.vectors[b - 1])) + abs(bars.level[b] - bars.level[b - 1]) / 6
            score[mod(b, 8)] += change
            counts[mod(b, 8)] += 1
        }
        let means = (0..<8).map { counts[$0] > 0 ? score[$0] / counts[$0] : 0 }
        return means.indices.max { means[$0] < means[$1] } ?? 0
    }

    // MARK: - Key

    static func key(_ chroma: [Double]) -> String? {
        guard chroma.count == 12, chroma.reduce(0, +) > 1e-6 else { return nil }
        var best = (score: -Double.infinity, pitch: 0, minor: false)
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let r = correlation(chroma, rotated)
                if r > best.score { best = (r, tonic, minor) }
            }
        }
        let major = best.minor ? (best.pitch + 3) % 12 : best.pitch
        return "\(majorPositionByPitchClass[major])\(best.minor ? "A" : "B")"
    }

    static func camelotDistance(_ a: String, _ b: String) -> Int {
        guard let na = Int(a.dropLast()), let nb = Int(b.dropLast()) else { return 0 }
        let d = abs(na - nb) % 12
        let steps = min(d, 12 - d)
        return a.last == b.last || steps == 0 ? steps : steps + 1
    }

    // MARK: - Net lab

    static func observation(_ t: SetLearningTransition) -> AutoMixNetObservation {
        let bands = MixWindowBands(
            before: t.bandsBefore, during: t.bandsDuring, after: t.bandsAfter,
            lowOverlap: t.blendBars > 0 ? Double(t.doubleBassBars) / Double(t.blendBars) : 0,
            maxLevelJumpDecibels: t.maxLevelJumpDecibels, spectralFlux: nil
        )
        return AutoMixNetObservation(
            moveType: t.move, blendBars: Double(t.blendBars), energyStep: t.energyStepDecibels, bands: bands,
            vocalOverlapSeconds: t.vocalDuringBlendSeconds, phaseErrorBeats: nil, gridConfidence: t.confidence,
            keyDistance: t.keyDistance, bpmDeltaPercent: t.tempoRamp ? 0 : t.bpmDeltaPercent,
            exitSection: t.exitSection, entrySection: t.entrySection, peakProximityBars: nil
        )
    }

    // MARK: - Maths

    static func normaliseTempo(_ bpm: Double) -> Double {
        var x = bpm
        while x < 95 { x *= 2 }
        while x > 190 { x /= 2 }
        return x
    }

    static func barIndex(_ seconds: Double, _ bars: SetLearningBars) -> Int {
        var lo = 0, hi = bars.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if bars.starts[m] <= seconds { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    static func clamp(_ r: Range<Int>, _ n: Int) -> Range<Int> {
        let lo = min(max(0, r.lowerBound), n), hi = min(max(lo, r.upperBound), n)
        return lo..<hi
    }

    static func mod(_ a: Int, _ m: Int) -> Int { ((a % m) + m) % m }

    static func unit(_ v: [Double]) -> [Double] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 1e-9 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in 0..<min(a.count, b.count) { dot += a[k] * b[k]; na += a[k] * a[k]; nb += b[k] * b[k] }
        return na > 1e-12 && nb > 1e-12 ? dot / (na * nb).squareRoot() : 0
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for k in 0..<a.count { num += (a[k] - ma) * (b[k] - mb); da += pow(a[k] - ma, 2); db += pow(b[k] - mb, 2) }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    static func meanVector(_ rows: [[Double]], _ r: Range<Int>) -> [Double] {
        let r = clamp(r, rows.count)
        guard let first = r.first else { return [] }
        var out = [Double](repeating: 0, count: rows[first].count)
        for i in r { for k in 0..<out.count { out[k] += rows[i][k] } }
        return out.map { $0 / Double(r.count) }
    }

    static func median(_ x: [Double]) -> Double {
        let s = x.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    static func mean(_ x: [Double]) -> Double {
        let s = x.filter(\.isFinite)
        return s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count)
    }

    static func percentile(_ x: [Double], _ p: Double) -> Double {
        let s = x.sorted()
        guard !s.isEmpty else { return 0 }
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    static func smooth(_ x: [Double], _ radius: Int) -> [Double] {
        guard radius > 0 else { return x }
        return x.indices.map { i in
            let r = max(0, i - radius)..<min(x.count, i + radius + 1)
            return x[r].reduce(0, +) / Double(r.count)
        }
    }

    static func zScored(_ x: [Double]) -> [Double] {
        let m = mean(x)
        let sd = (x.reduce(0) { $0 + pow($1 - m, 2) } / Double(max(1, x.count))).squareRoot()
        return sd > 1e-9 ? x.map { ($0 - m) / sd } : x.map { _ in 0 }
    }

    static func round1(_ x: Double) -> Double { x.isFinite ? (x * 10).rounded() / 10 : 0 }
    static func round3(_ x: Double) -> Double { x.isFinite ? (x * 1000).rounded() / 1000 : 0 }
}
