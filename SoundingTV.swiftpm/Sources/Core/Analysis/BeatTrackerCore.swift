import Foundation
import Accelerate

extension BeatTracker {

    struct Diagnostics: Sendable {
        var tempoClarity: Double = 0
        var salientFraction: Double = 0
        var residualMs: Double = 0
        var halfBarStrength: Double = 0
        var parityStrength: Double = 0
        var phraseMargin: Double = 0
        var shiftScores: [[Double]] = []
        var offbeat: [Double] = []
        var phaseShift = 0
        var beats: [Double] = []
    }

    static func analyze(_ features: BeatTrackerFeatures, tempoPrior: Double?) -> BeatTrackerResult {
        analyzeWithDiagnostics(features, tempoPrior: tempoPrior).result
    }

    static func analyzeWithDiagnostics(
        _ features: BeatTrackerFeatures,
        tempoPrior: Double?
    ) -> (result: BeatTrackerResult, diagnostics: Diagnostics) {
        var diagnostics = Diagnostics()
        let frames = features.frameCount
        let rate = features.frameRate
        guard frames > Int(rate * 10) else {
            return (.empty(analysedSeconds: features.analysedSeconds), diagnostics)
        }

        let low = normalisedByMean(features.low)
        let lowMid = normalisedByMean(features.lowMid)
        let mid = normalisedByMean(features.mid)
        let high = normalisedByMean(features.high)

        var odf = [Float](repeating: 0, count: frames)
        for t in 0..<frames {
            odf[t] = low[t] + 0.6 * lowMid[t] + 0.8 * mid[t] + 0.35 * high[t]
        }
        odf = highPassed(odf, radius: Int(rate * 0.25))
        normaliseByStd(&odf)

        guard let tempo = estimateTempo(odf, rate: rate, prior: tempoPrior) else {
            return (.empty(analysedSeconds: features.analysedSeconds), diagnostics)
        }
        diagnostics.tempoClarity = tempo.clarity

        let beatFrames = trackBeats(odf, periods: tempo.framePeriods)
        guard beatFrames.count >= 16 else {
            return (.empty(analysedSeconds: features.analysedSeconds), diagnostics)
        }

        var sharp = [Float](repeating: 0, count: frames)
        for t in 0..<frames { sharp[t] = low[t] + 0.5 * lowMid[t] + 0.8 * mid[t] }
        let map = buildTempoMap(
            beatFrames: beatFrames,
            sharp: sharp,
            features: features,
            periodSeconds: { frame in Double(tempo.framePeriod(at: frame)) / rate }
        )
        diagnostics.salientFraction = map.salientFraction
        diagnostics.residualMs = map.residualMs
        guard map.beats.count >= 16 else {
            return (.empty(analysedSeconds: features.analysedSeconds), diagnostics)
        }

        let evidence = offbeatEvidence(beats: map.beats, features: features, bands: [low, lowMid, mid, high])
        diagnostics.offbeat = evidence
        let offbeatProbability = offbeatProbability(evidence)
        let beats = offbeatProbability >= 0.5 ? shiftedHalfBeat(map.beats, until: features.analysedSeconds) : map.beats
        let beatPhaseConfidence = max(offbeatProbability, 1 - offbeatProbability)
        let measured = estimateDownbeats(beats: beats, features: features, low: low, mid: mid, high: high)
        let voted = barPhaseVote(measured)
        let vote = measured.confidence >= keepMeasuredPhaseConfidence ? PhaseVote(shift: 0, probabilities: voted.probabilities) : voted
        let bar = measured.shifted(by: vote.shift, beatCount: beats.count)
        diagnostics.beats = beats
        diagnostics.halfBarStrength = measured.halfBarStrength
        diagnostics.parityStrength = measured.parityStrength
        diagnostics.phaseShift = vote.shift
        diagnostics.shiftScores = measured.shiftScores

        let phrase = estimatePhrases(beats: beats, downbeatIndices: bar.downbeatIndices, features: features, high: high)
        diagnostics.phraseMargin = phrase.margin

        let n = Double(beats.count - 1)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (i, t) in beats.enumerated() {
            let x = Double(i)
            sx += x; sy += t; sxx += x * x; sxy += x * t
        }
        let count = n + 1
        let slope = (count * sxy - sx * sy) / max(1e-12, count * sxx - sx * sx)
        let bpm = slope > 0 ? (60 / slope * 100).rounded() / 100 : nil

        var segments: [BeatTrackerResult.TempoSegment] = []
        var index = 0
        while index + 32 < beats.count {
            let span = beats[index + 32] - beats[index]
            if span > 0 {
                segments.append(.init(start: round4(beats[index]), bpm: (60 * 32 / span * 100).rounded() / 100))
            }
            index += 32
        }

        let clarityScore = smoothstep(0.25, 0.6, tempo.clarity)
        let supportScore = smoothstep(0.35, 0.75, map.salientFraction)
        let precisionScore = 1 - smoothstep(5, 20, map.residualMs)
        let beatConfidence = pow(clarityScore * supportScore * precisionScore, 1.0 / 3.0)
        let downbeatConfidence = vote.shift == 0 ? max(vote.confidence, measured.confidence) : vote.confidence
        let confidence = 0.92 * min(beatConfidence, downbeatConfidence)

        let downbeats = bar.downbeatIndices.map { round4(beats[$0]) }
        let phraseStarts = phrase.phraseBarIndices.compactMap { $0 < downbeats.count ? downbeats[$0] : nil }
        let sectionStarts = phrase.sectionBarIndices.compactMap { $0 < downbeats.count ? downbeats[$0] : nil }

        var result = BeatTrackerResult(
            version: BeatTracker.version,
            bpm: bpm,
            beats: beats.map(round4),
            downbeats: downbeats,
            phraseOffsetBars: phrase.offset,
            phraseStarts: phraseStarts,
            sectionStarts: sectionStarts,
            tempoSegments: segments,
            confidence: (confidence * 1000).rounded() / 1000,
            beatConfidence: (beatConfidence * 1000).rounded() / 1000,
            downbeatConfidence: (downbeatConfidence * 1000).rounded() / 1000,
            tempoClarity: (tempo.clarity * 1000).rounded() / 1000,
            analysedSeconds: features.analysedSeconds,
            vocalRanges: features.vocalRanges
        )
        result.vocalCurve = features.vocalCurve
        result.parityConfidence = ((vote.shift == 0 ? max(vote.parityConfidence, measured.parityConfidence) : vote.parityConfidence) * 1000).rounded() / 1000
        result.phaseConfidence = (downbeatConfidence * 1000).rounded() / 1000
        result.beatPhaseConfidence = (beatPhaseConfidence * 1000).rounded() / 1000
        result.sectionStrengths = phrase.sectionStrengths.map { ($0 * 1000).rounded() / 1000 }
        result.parityEvidence = [bar.parityStrength, bar.parityAgreement, bar.changeParityStrength, bar.changeParityAgreement, bar.halfBarStrength, bar.halfBarAgreement].map { ($0 * 1000).rounded() / 1000 }
        result.bars = BarProfile.measure(features, downbeats: downbeats)
        return (result, diagnostics)
    }

    // MARK: - Tempo

    struct TempoEstimate {
        let bpm: Double
        let clarity: Double
        let framePeriods: [Float]
        let windowCentres: [Double]
        let windowPeriods: [Double]

        func framePeriod(at frame: Double) -> Float {
            guard !framePeriods.isEmpty else { return 1 }
            let i = min(framePeriods.count - 1, max(0, Int(frame)))
            return framePeriods[i]
        }
    }

    static func estimateTempo(_ odf: [Float], rate: Double, prior: Double?) -> TempoEstimate? {
        let decimate = rate > 120 ? 2 : 1
        let rate2 = rate / Double(decimate)
        var signal = [Float](repeating: 0, count: odf.count / decimate)
        for i in signal.indices {
            var v = odf[i * decimate]
            if decimate == 2 { v = max(v, odf[i * 2 + 1]) }
            signal[i] = v
        }
        let maxLag = Int((4 * 60 / minBPM * rate2).rounded(.up)) + 3
        let windowLength = min(signal.count, Int(8 * rate2))
        guard windowLength > maxLag + 8 else { return nil }
        let windowHop = Int(4 * rate2)
        var starts: [Int] = []
        var s = 0
        while s + windowLength <= signal.count {
            starts.append(s)
            s += windowHop
        }
        if starts.isEmpty { starts = [0] }

        var acfs = [[Float]]()
        var weights = [Float]()
        var segment = [Float](repeating: 0, count: windowLength)
        for start in starts {
            signal.withUnsafeBufferPointer { src in
                segment.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress! + start, count: windowLength)
                }
            }
            var mean: Float = 0
            vDSP_meanv(segment, 1, &mean, vDSP_Length(windowLength))
            var negative = -mean
            vDSP_vsadd(segment, 1, &negative, &segment, 1, vDSP_Length(windowLength))
            var acf = [Float](repeating: 0, count: maxLag + 1)
            segment.withUnsafeBufferPointer { b in
                for lag in 0...maxLag where lag < windowLength {
                    var dot: Float = 0
                    vDSP_dotpr(b.baseAddress!, 1, b.baseAddress! + lag, 1, &dot, vDSP_Length(windowLength - lag))
                    acf[lag] = dot / Float(windowLength - lag)
                }
            }
            let energy = acf[0]
            if energy > 1e-6 {
                var inv = 1 / energy
                vDSP_vsmul(acf, 1, &inv, &acf, 1, vDSP_Length(acf.count))
            }
            acfs.append(acf)
            weights.append(energy > 1e-6 ? 1 : 0)
        }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }
        var global = [Float](repeating: 0, count: maxLag + 1)
        for (acf, w) in zip(acfs, weights) where w > 0 {
            vDSP_vadd(global, 1, acf, 1, &global, 1, vDSP_Length(global.count))
        }
        var invTotal = 1 / totalWeight
        vDSP_vsmul(global, 1, &invTotal, &global, 1, vDSP_Length(global.count))

        func value(_ acf: [Float], _ lag: Double) -> Double {
            guard lag >= 0 else { return 0 }
            let i = Int(lag)
            guard i + 1 < acf.count else { return 0 }
            let f = Float(lag - Double(i))
            return Double(acf[i] * (1 - f) + acf[i + 1] * f)
        }
        func salience(_ acf: [Float], _ lag: Double) -> Double {
            value(acf, lag) + 0.5 * value(acf, 2 * lag) + 0.25 * value(acf, 4 * lag)
        }

        let centre = prior ?? 120
        var candidates: [(bpm: Double, score: Double)] = []
        var bpm = minBPM
        while bpm <= maxBPM {
            candidates.append((bpm, salience(global, 60 * rate2 / bpm)))
            bpm += 0.25
        }
        let scores = candidates.map(\.score)
        let maxScore = scores.max() ?? 0
        let medianScore = median(scores)
        let spread = max(1e-6, maxScore - medianScore)
        var bestIndex = 0
        var bestValue = -Double.infinity
        for (i, c) in candidates.enumerated() {
            let octaves = log2(c.bpm / centre)
            let preference = exp(-0.5 * pow(octaves / 0.6, 2))
            let v = c.score + 0.12 * spread * preference
            if v > bestValue {
                bestValue = v
                bestIndex = i
            }
        }
        var bestBPM = candidates[bestIndex].bpm
        if bestIndex > 0, bestIndex + 1 < candidates.count {
            let a = candidates[bestIndex - 1].score
            let b = candidates[bestIndex].score
            let c = candidates[bestIndex + 1].score
            let curvature = a - 2 * b + c
            if curvature < 0 {
                bestBPM += max(-0.5, min(0.5, 0.5 * (a - c) / curvature)) * 0.25
            }
        }
        let peak = candidates[bestIndex].score
        let clarity = max(0, min(1, (peak - medianScore) / max(1e-6, abs(peak))))

        let globalLag = 60 * rate2 / bestBPM
        var windowPeriods = [Double](repeating: .nan, count: acfs.count)
        var windowStrength = [Double](repeating: 0, count: acfs.count)
        for (w, acf) in acfs.enumerated() where weights[w] > 0 {
            var best = -Double.infinity
            var bestLag = globalLag
            let lowest = globalLag / 1.1
            let highest = globalLag * 1.1
            var lag = lowest
            while lag <= highest {
                let v = salience(acf, lag)
                if v > best {
                    best = v
                    bestLag = lag
                }
                lag += 0.05
            }
            let pinned = bestLag < lowest * 1.01 || bestLag > highest / 1.01
            windowPeriods[w] = pinned ? .nan : bestLag
            windowStrength[w] = pinned ? 0 : best
        }
        let strengths = windowStrength.filter { $0 > 0 }
        let strengthFloor = strengths.isEmpty ? 0 : median(strengths) * 0.4
        for w in windowPeriods.indices where windowStrength[w] < strengthFloor { windowPeriods[w] = .nan }
        var smoothed = windowPeriods
        for w in windowPeriods.indices {
            let neighbours = (max(0, w - 2)...min(windowPeriods.count - 1, w + 2))
                .map { windowPeriods[$0] }.filter { $0.isFinite }
            smoothed[w] = neighbours.isEmpty ? .nan : median(neighbours)
        }
        if smoothed.allSatisfy({ !$0.isFinite }) {
            smoothed = smoothed.map { _ in globalLag }
        } else {
            var lastKnown = smoothed.first(where: { $0.isFinite }) ?? globalLag
            for w in smoothed.indices {
                if smoothed[w].isFinite { lastKnown = smoothed[w] } else { smoothed[w] = lastKnown }
            }
        }

        let centres = starts.map { (Double($0) + Double(windowLength) / 2) * Double(decimate) }
        let periodsFull = smoothed.map { $0 * Double(decimate) }
        var framePeriods = [Float](repeating: Float(globalLag * Double(decimate)), count: odf.count)
        var cursor = 0
        for t in 0..<odf.count {
            let x = Double(t)
            while cursor + 1 < centres.count, centres[cursor + 1] <= x { cursor += 1 }
            if x <= centres[0] {
                framePeriods[t] = Float(periodsFull[0])
            } else if cursor + 1 >= centres.count {
                framePeriods[t] = Float(periodsFull[periodsFull.count - 1])
            } else {
                let f = (x - centres[cursor]) / (centres[cursor + 1] - centres[cursor])
                framePeriods[t] = Float(periodsFull[cursor] * (1 - f) + periodsFull[cursor + 1] * f)
            }
        }
        return TempoEstimate(
            bpm: bestBPM, clarity: clarity, framePeriods: framePeriods,
            windowCentres: centres, windowPeriods: periodsFull
        )
    }

    // MARK: - Beats

    static func trackBeats(_ odf: [Float], periods: [Float]) -> [Int] {
        let count = odf.count
        guard count > 0 else { return [] }
        let tightness: Float = 400
        let maxPeriod = Int((periods.max() ?? 1).rounded(.up))
        let maxDistance = 2 * maxPeriod + 2
        var logs = [Float](repeating: 0, count: maxDistance + 1)
        for d in 1...maxDistance { logs[d] = log(Float(d)) }
        var score = [Float](repeating: 0, count: count)
        var back = [Int32](repeating: -1, count: count)
        score.withUnsafeMutableBufferPointer { c in
            back.withUnsafeMutableBufferPointer { b in
                logs.withUnsafeBufferPointer { lg in
                    for t in 0..<count {
                        let tau = periods[t]
                        let lower = t - Int((2 * tau).rounded())
                        let upper = t - Int((tau / 2).rounded())
                        var best = -Float.infinity
                        var bestIndex = -1
                        if upper >= 0 {
                            let logTau = log(tau)
                            for p in max(0, lower)...upper {
                                let diff = lg[t - p] - logTau
                                let candidate = c[p] - tightness * diff * diff
                                if candidate > best {
                                    best = candidate
                                    bestIndex = p
                                }
                            }
                        }
                        if bestIndex >= 0 {
                            c[t] = odf[t] + best
                            b[t] = Int32(bestIndex)
                        } else {
                            c[t] = odf[t]
                        }
                    }
                }
            }
        }
        let tail = max(1, Int(periods[count - 1].rounded()))
        var end = count - 1
        var bestEnd = -Float.infinity
        for t in max(0, count - tail)..<count where score[t] > bestEnd {
            bestEnd = score[t]
            end = t
        }
        var out: [Int] = []
        var t = end
        while t >= 0 {
            out.append(t)
            let previous = Int(back[t])
            if previous < 0 || previous >= t { break }
            t = previous
        }
        return out.reversed()
    }

    struct TempoMap {
        let beats: [Double]
        let salientFraction: Double
        let residualMs: Double
    }

    static func buildTempoMap(
        beatFrames: [Int],
        sharp: [Float],
        features: BeatTrackerFeatures,
        periodSeconds: (Double) -> Double
    ) -> TempoMap {
        let frames = sharp.count
        let sorted = sharp.sorted()
        let medianSharp = sorted[sorted.count / 2]
        let upper = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let threshold = medianSharp + 0.35 * (upper - medianSharp)
        let radius = max(2, Int((0.035 * features.frameRate).rounded()))

        var anchors: [(time: Double, salient: Bool, strength: Float)] = []
        anchors.reserveCapacity(beatFrames.count)
        for raw in beatFrames {
            let b = max(1, min(frames - 2, raw))
            var peak = b
            var peakValue = -Float.infinity
            for f in max(1, b - radius)...min(frames - 2, b + radius) where sharp[f] > peakValue {
                peakValue = sharp[f]
                peak = f
            }
            let isPeak = peak > max(1, b - radius) && peak < min(frames - 2, b + radius)
            if peakValue > threshold, isPeak {
                let a = sharp[peak - 1], c = sharp[peak], d = sharp[peak + 1]
                let curvature = a - 2 * c + d
                let offset = curvature < 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - d) / curvature))) : 0
                anchors.append((features.time(ofFrame: Double(peak) + offset), true, peakValue))
            } else {
                anchors.append((features.time(ofFrame: Double(b)), false, 0))
            }
        }

        let candidates = anchors.filter(\.salient)
        let salient = consistentAnchors(candidates, features: features, periodSeconds: periodSeconds)
        let salientFraction = Double(salient.count) / Double(max(1, anchors.count))
        guard salient.count >= 8 else {
            return TempoMap(beats: anchors.map(\.time), salientFraction: salientFraction, residualMs: 99)
        }

        var intervals = [Double](repeating: .nan, count: salient.count)
        for j in 1..<salient.count {
            let gap = salient[j].time - salient[j - 1].time
            let period = periodSeconds(features.frame(ofTime: (salient[j].time + salient[j - 1].time) / 2))
            if gap < period * 1.5 { intervals[j] = gap }
        }
        func measuredPeriod(around j: Int, fallback: Double) -> Double {
            var nearby: [Double] = []
            var k = j - 1
            while k >= 1, nearby.count < 8 {
                if intervals[k].isFinite { nearby.append(intervals[k]) }
                k -= 1
            }
            var before = 0
            k = j + 1
            while k < salient.count, before < 8 {
                if intervals[k].isFinite {
                    nearby.append(intervals[k])
                    before += 1
                }
                k += 1
            }
            return nearby.count >= 4 ? median(nearby) : fallback
        }
        var numbers = [Int](repeating: 0, count: salient.count)
        for j in 1..<salient.count {
            let gap = salient[j].time - salient[j - 1].time
            let fallback = periodSeconds(features.frame(ofTime: (salient[j].time + salient[j - 1].time) / 2))
            let period = intervals[j].isFinite ? intervals[j] : measuredPeriod(around: j, fallback: fallback)
            numbers[j] = numbers[j - 1] + max(1, Int((gap / period).rounded()))
        }

        let halfSpan = 8
        var fitted = [Double](repeating: 0, count: salient.count)
        var slopes = [Double](repeating: 0, count: salient.count)
        var residuals: [Double] = []
        var lo = 0
        var hi = 0
        for i in salient.indices {
            while numbers[lo] < numbers[i] - halfSpan { lo += 1 }
            while hi + 1 < salient.count, numbers[hi + 1] <= numbers[i] + halfSpan { hi += 1 }
            var include = [Bool](repeating: true, count: hi - lo + 1)
            var intercept = salient[i].time
            var slope = periodSeconds(features.frame(ofTime: salient[i].time))
            for pass in 0..<2 {
                var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                for k in lo...hi where include[k - lo] {
                    let x = Double(numbers[k] - numbers[i])
                    let y = salient[k].time
                    let w = 1.0 / (1 + abs(x) / Double(halfSpan))
                    sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
                }
                let det = sw * sxx - sx * sx
                if sw > 0, det > 1e-9 {
                    slope = (sw * sxy - sx * sy) / det
                    intercept = (sy - slope * sx) / sw
                } else if sw > 0 {
                    intercept = sy / sw
                }
                if pass == 0 {
                    for k in lo...hi {
                        let x = Double(numbers[k] - numbers[i])
                        if abs(salient[k].time - (intercept + slope * x)) > 0.03 { include[k - lo] = false }
                    }
                    include[i - lo] = true
                }
            }
            fitted[i] = intercept
            slopes[i] = slope
            residuals.append(abs(salient[i].time - intercept) * 1000)
        }
        let residualMs = median(residuals)

        var beats: [Double] = []
        beats.reserveCapacity(numbers[numbers.count - 1] - numbers[0] + 64)
        let firstSlope = slopes[0] > 0 ? slopes[0] : periodSeconds(0)
        var back = 1
        var leading: [Double] = []
        while back <= 32 {
            let t = fitted[0] - Double(back) * firstSlope
            if t < 0 { break }
            leading.append(t)
            back += 1
        }
        beats.append(contentsOf: leading.reversed())
        for j in salient.indices {
            beats.append(fitted[j])
            guard j + 1 < salient.count else { break }
            let steps = numbers[j + 1] - numbers[j]
            guard steps > 1 else { continue }
            for k in 1..<steps {
                let f = Double(k) / Double(steps)
                beats.append(fitted[j] * (1 - f) + fitted[j + 1] * f)
            }
        }
        let lastSlope = slopes[slopes.count - 1] > 0 ? slopes[slopes.count - 1] : periodSeconds(Double(frames - 1))
        var forward = 1
        while forward <= 32 {
            let t = fitted[fitted.count - 1] + Double(forward) * lastSlope
            if t > features.analysedSeconds - 0.02 { break }
            beats.append(t)
            forward += 1
        }
        return TempoMap(beats: beats, salientFraction: salientFraction, residualMs: residualMs)
    }

    static func consistentAnchors(
        _ candidates: [(time: Double, salient: Bool, strength: Float)],
        features: BeatTrackerFeatures,
        periodSeconds: (Double) -> Double
    ) -> [(time: Double, salient: Bool, strength: Float)] {
        guard candidates.count > 8 else { return candidates }
        var accepted: [(time: Double, salient: Bool, strength: Float)] = []
        var steps: [Double] = []
        var pending: [(time: Double, salient: Bool, strength: Float)] = []
        let rerunLength = 48
        func period(at time: Double) -> Double {
            steps.count >= 4 ? median(Array(steps.suffix(8))) : periodSeconds(features.frame(ofTime: time))
        }
        func fitsGrid(_ time: Double, after reference: Double, period: Double) -> Bool {
            let ratio = (time - reference) / period
            return ratio > 0.5 && abs(ratio - ratio.rounded()) < 0.2
        }
        for candidate in candidates {
            guard let last = accepted.last else {
                accepted.append(candidate)
                continue
            }
            let p = period(at: candidate.time)
            if fitsGrid(candidate.time, after: last.time, period: p) {
                let gap = candidate.time - last.time
                if gap < p * 1.5 { steps.append(gap) }
                accepted.append(candidate)
                pending.removeAll()
                continue
            }
            if let previous = pending.last, !fitsGrid(candidate.time, after: previous.time, period: p) {
                pending.removeAll()
            }
            pending.append(candidate)
            if pending.count >= rerunLength {
                accepted.append(contentsOf: pending)
                pending.removeAll()
            }
        }
        return accepted
    }

    // MARK: - Downbeats

    struct BarEstimate {
        let downbeatIndices: [Int]
        let parityStrength: Double
        let parityAgreement: Double
        let halfBarStrength: Double
        let halfBarAgreement: Double
        var changeParityStrength: Double = 0
        var changeParityAgreement: Double = 0
        var shiftScores: [[Double]] = []

        static func vote(_ strength: Double, _ agreement: Double) -> Double {
            BeatTracker.smoothstep(1.5, 3.5, strength) * BeatTracker.smoothstep(0.3, 0.7, agreement)
        }

        var parityConfidence: Double {
            let drums = Self.vote(parityStrength, parityAgreement)
            guard abs(parityStrength) < 1.5, changeParityAgreement >= 0.6 else { return drums }
            return max(drums, 0.9 * Self.vote(changeParityStrength, changeParityAgreement))
        }

        var confidence: Double {
            let halfBar = Self.vote(halfBarStrength, halfBarAgreement)
            return min(parityConfidence, halfBar)
        }

        func shifted(by shift: Int, beatCount: Int) -> BarEstimate {
            guard shift != 0, let first = downbeatIndices.first else { return self }
            var indices = downbeatIndices.map { $0 + shift }.filter { $0 < beatCount }
            if first + shift - 4 >= 0 { indices.insert(first + shift - 4, at: 0) }
            var out = BarEstimate(
                downbeatIndices: indices,
                parityStrength: shift % 2 == 0 ? parityStrength : -parityStrength,
                parityAgreement: shift % 2 == 0 ? parityAgreement : -parityAgreement,
                halfBarStrength: shift == 2 ? -halfBarStrength : halfBarStrength,
                halfBarAgreement: shift == 2 ? -halfBarAgreement : halfBarAgreement
            )
            out.changeParityStrength = shift % 2 == 0 ? changeParityStrength : -changeParityStrength
            out.changeParityAgreement = shift % 2 == 0 ? changeParityAgreement : -changeParityAgreement
            out.shiftScores = shiftScores
            return out
        }
    }

    static func estimateDownbeats(
        beats: [Double],
        features: BeatTrackerFeatures,
        low: [Float],
        mid: [Float],
        high: [Float]
    ) -> BarEstimate {
        let matrix = downbeatFeatures(beats: beats, features: features, low: low, mid: mid, high: high)
        let kick = matrix[0], snare = matrix[1], crash = matrix[5]
        let count = beats.count
        var event = [Double](repeating: 0, count: count)
        for n in 0..<count {
            event[n] = 0.5 * min(3, matrix[2][n]) + min(3, matrix[3][n])
        }
        var perBeat = [[Double]](repeating: [0, 0, 0, 0], count: count)
        for n in 0..<count {
            let k = kick[n], s = snare[n], e = event[n], c = crash[n]
            perBeat[n][0] = 0.5 * k + 0.3 * e + 0.3 * c - 0.8 * s
            perBeat[n][1] = 0.8 * s - 0.2 * k
            perBeat[n][2] = 0.25 * k + 0.1 * e - 0.8 * s
            perBeat[n][3] = 0.8 * s - 0.2 * k
        }
        var phases = choosePhases(perBeat: perBeat)
        let novelty = barNovelty(beats: beats, features: features)
        let noise = max(1e-9, median(novelty.filter { $0 > 0 }))

        func peakWeight(_ i: Int) -> Double {
            guard i >= 8, i < count - 8 else { return 0 }
            let level = novelty[i] / noise
            guard level >= 3 else { return 0 }
            for j in max(0, i - 2)...min(count - 1, i + 2) where novelty[j] > novelty[i] { return 0 }
            return min(3, level * level / 16)
        }
        let change = matrix[6]
        func votes(_ phases: [Int]) -> (downbeats: [Int], parity: [Double], halfBar: [Double], change: [Double]) {
            var downbeats: [Int] = []
            var parity: [Double] = []
            var halfBar: [Double] = []
            var changes: [Double] = []
            for n in 0..<count where ((n - phases[n]) % 4 + 4) % 4 == 0 {
                downbeats.append(n)
                guard n + 3 < count else { continue }
                let s0 = snare[n], s1 = snare[n + 1], s2 = snare[n + 2], s3 = snare[n + 3]
                let k0 = kick[n], k1 = kick[n + 1], k2 = kick[n + 2], k3 = kick[n + 3]
                parity.append((s1 + s3 - s0 - s2) / 2 + 0.25 * (k0 + k2 - k1 - k3))
                changes.append((change[n] + change[n + 2] - change[n + 1] - change[n + 3]) / 2)
                let sections = peakWeight(n) - peakWeight(n + 2)
                halfBar.append(sections + 0.5 * (k0 - k2) + 0.5 * (crash[n] - crash[n + 2]))
            }
            return (downbeats, parity, halfBar, changes)
        }
        func strength(_ votes: [Double], threshold: Double) -> (strength: Double, agreement: Double) {
            let counted = votes.filter { abs($0) > threshold }
            let total = counted.reduce(0, +)
            let magnitude = counted.reduce(0) { $0 + abs($1) }
            let energy = counted.reduce(0) { $0 + $1 * $1 }
            let z = energy > 1e-12 ? total / sqrt(energy) : 0
            return (z, magnitude > 1e-12 ? total / magnitude : 0)
        }
        var tally = votes(phases)
        let drumParity = strength(tally.parity, threshold: 0.25)
        let changeParity = strength(tally.change, threshold: 0.25)
        if BarEstimate.vote(drumParity.strength, drumParity.agreement) < 0.5, abs(drumParity.strength) < 1.5,
           changeParity.strength <= -3.5, changeParity.agreement <= -0.6 {
            phases = phases.map { ($0 + 1) % 4 }
            tally = votes(phases)
        }
        var halfBar = strength(tally.halfBar, threshold: 0.5)
        if halfBar.strength < 0 {
            let flipped = phases.map { ($0 + 2) % 4 }
            let flippedTally = votes(flipped)
            let flippedHalfBar = strength(flippedTally.halfBar, threshold: 0.5)
            if flippedHalfBar.strength > halfBar.strength {
                phases = flipped
                tally = flippedTally
                halfBar = flippedHalfBar
            }
        }
        let downbeats = tally.downbeats
        let parity = strength(tally.parity, threshold: 0.25)
        let changes = strength(tally.change, threshold: 0.25)
        var estimate = BarEstimate(
            downbeatIndices: downbeats,
            parityStrength: parity.strength,
            parityAgreement: parity.agreement,
            halfBarStrength: halfBar.strength,
            halfBarAgreement: halfBar.agreement
        )
        estimate.changeParityStrength = changes.strength
        estimate.changeParityAgreement = changes.agreement
        estimate.shiftScores = shiftScores(beats: beats, features: features, matrix: matrix, phases: phases)
        return estimate
    }

    static let offbeatWeights: [Double] = [-0.38, -1.54, -1.89, 2.21, -0.58, 0.15]
    static let offbeatBias = -0.25

    static func offbeatProbability(_ evidence: [Double]) -> Double {
        guard evidence.count == offbeatWeights.count else { return 0 }
        var z = offbeatBias
        for (w, x) in zip(offbeatWeights, evidence) { z += w * x }
        return 1 / (1 + exp(-z))
    }

    static func shiftedHalfBeat(_ beats: [Double], until end: Double) -> [Double] {
        guard beats.count >= 2 else { return beats }
        var out: [Double] = []
        let first = (beats[1] - beats[0]) / 2
        if beats[0] - first >= 0 { out.append(beats[0] - first) }
        for (a, b) in zip(beats, beats.dropFirst()) { out.append((a + b) / 2) }
        let last = (beats[beats.count - 1] - beats[beats.count - 2]) / 2
        if beats[beats.count - 1] + last < end - 0.02 { out.append(beats[beats.count - 1] + last) }
        return out
    }

    struct PhaseVote {
        let shift: Int
        let probabilities: [Double]

        var confidence: Double { probabilities[shift] }
        var parityConfidence: Double { probabilities[shift] + probabilities[(shift + 2) % 4] }
    }

    static let phaseCueWeights: [Double] = [2, 0.5, 0.25, 3, 0.5, 0, 0.5, 1]
    static let phaseParityWeight = 1.0
    static let phaseHalfBarWeight = 1.0
    static let phaseSharpness = 0.1
    static let keepMeasuredPhaseConfidence = 0.65

    static func barPhaseVote(_ bar: BarEstimate) -> PhaseVote {
        guard bar.shiftScores.count == phaseCueWeights.count else { return PhaseVote(shift: 0, probabilities: [bar.confidence, 0, 0, 0]) }
        var scores = [Double](repeating: 0, count: 4)
        for d in 0..<4 {
            for (c, w) in phaseCueWeights.enumerated() { scores[d] += w * bar.shiftScores[c][d] }
            scores[d] += phaseParityWeight * bar.parityStrength * (d % 2 == 0 ? 1 : -1)
            scores[d] += phaseHalfBarWeight * bar.halfBarStrength * (d == 0 ? 1 : d == 2 ? -1 : 0)
        }
        let top = scores.max() ?? 0
        let weights = scores.map { exp(phaseSharpness * ($0 - top)) }
        let total = weights.reduce(0, +)
        let probabilities = weights.map { $0 / total }
        let shift = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        return PhaseVote(shift: shift, probabilities: probabilities)
    }

    static func offbeatEvidence(beats: [Double], features: BeatTrackerFeatures, bands: [[Float]]) -> [Double] {
        guard beats.count > 16 else { return [] }
        let frames = bands[0].count
        let radius = max(2, Int((0.03 * features.frameRate).rounded()))
        func peak(_ x: [Float], _ t: Double) -> Double {
            let f = max(0, min(frames - 1, Int(features.frame(ofTime: t).rounded())))
            var best: Float = 0
            for k in max(0, f - radius)...min(frames - 1, f + radius) { best = max(best, x[k]) }
            return Double(best)
        }
        let offbeats = zip(beats, beats.dropFirst()).map { ($0 + $1) / 2 }
        let on = Array(beats.dropLast())
        var out: [Double] = []
        for x in bands {
            let a = on.reduce(0) { $0 + peak(x, $1) } / Double(on.count)
            let b = offbeats.reduce(0) { $0 + peak(x, $1) } / Double(offbeats.count)
            out.append(max(-2, min(2, log((a + 0.05) / (b + 0.05)))))
        }
        func alternation(_ x: [Float], _ times: [Double]) -> Double {
            let v = times.map { peak(x, $0) }
            guard v.count > 2 else { return 0 }
            var d = 0.0
            for i in 1..<v.count { d += abs(v[i] - v[i - 1]) }
            let m = v.reduce(0, +) / Double(v.count)
            return d / Double(v.count - 1) / max(1e-6, m)
        }
        out.append(alternation(bands[2], on) - alternation(bands[2], offbeats))
        out.append(alternation(bands[0], on) - alternation(bands[0], offbeats))
        return out
    }

    static func shiftScores(beats: [Double], features: BeatTrackerFeatures, matrix: [[Double]], phases: [Int]) -> [[Double]] {
        let count = beats.count
        var position = [Int](repeating: 0, count: count)
        for n in 0..<count { position[n] = ((n - phases[n]) % 4 + 4) % 4 }
        func fold(_ x: [Double], dense: Bool) -> [Double] {
            let mean = dense ? x.reduce(0, +) / Double(max(1, x.count)) : 0
            var totals = [Double](repeating: 0, count: 4)
            var energy = 0.0
            var sum = 0.0
            for n in 0..<count {
                let v = x[n] - mean
                totals[position[n]] += v
                energy += v * v
                sum += v
            }
            let sd = sqrt(max(1e-12, energy * 3 / 16))
            return (0..<4).map { (totals[$0] - sum / 4) / sd }
        }
        func localPeaks(_ x: [Double], radius: Int) -> [Double] {
            var out = [Double](repeating: 0, count: x.count)
            for n in x.indices where x[n] > 0 {
                var isPeak = true
                for j in max(0, n - radius)...min(x.count - 1, n + radius) where j != n && (x[j] > x[n] || (x[j] == x[n] && j < n)) {
                    isPeak = false
                    break
                }
                if isPeak { out[n] = x[n] }
            }
            return out
        }
        let slowCount = features.slowCount
        var prefix = [[Double]](repeating: [Double](repeating: 0, count: 17), count: slowCount + 1)
        for i in 0..<slowCount {
            for c in 0..<12 { prefix[i + 1][c] = prefix[i][c] + 2 * Double(features.chroma[i * 12 + c]) }
            for b in 0..<4 { prefix[i + 1][12 + b] = prefix[i][12 + b] + Double(features.bandEnergy[i * 4 + b]) }
            prefix[i + 1][16] = prefix[i][16] + Double(features.bandEnergy[i * 4]) + Double(features.bandEnergy[i * 4 + 1])
        }
        func index(_ t: Double) -> Int { max(0, min(slowCount, Int(features.slowIndex(ofTime: t).rounded(.up)))) }
        func mean(_ a: Int, _ b: Int) -> [Double]? {
            guard b > a else { return nil }
            return (0..<17).map { (prefix[b][$0] - prefix[a][$0]) / Double(b - a) }
        }
        let span = 8
        var novelty = [Double](repeating: 0, count: count)
        var rise = [Double](repeating: 0, count: count)
        if count > 2 * span, slowCount > 0 {
            for n in span..<(count - span) {
                guard let before = mean(index(beats[n - span]), index(beats[n])),
                      let after = mean(index(beats[n]), index(beats[n + span])) else { continue }
                var s = 0.0
                for d in 0..<16 { s += (before[d] - after[d]) * (before[d] - after[d]) }
                novelty[n] = sqrt(s)
                rise[n] = max(0, after[16] - before[16])
            }
        }
        let kick = matrix[0]
        var kickReturn = [Double](repeating: 0, count: count)
        for n in 4..<max(4, count - 4) {
            let before = (n - 4..<n).reduce(0) { $0 + kick[$1] } / 4
            let after = (n..<n + 4).reduce(0) { $0 + kick[$1] } / 4
            kickReturn[n] = max(0, after - before)
        }
        return [
            fold(localPeaks(events(novelty), radius: 2), dense: false),
            fold(localPeaks(events(rise), radius: 2), dense: false),
            fold(localPeaks(events(kickReturn), radius: 2), dense: false),
            fold(matrix[6], dense: true),
            fold(matrix[5], dense: true),
            fold(matrix[0], dense: true),
            fold(matrix[2], dense: true),
            fold(matrix[3], dense: true)
        ]
    }

    static func barNovelty(beats: [Double], features: BeatTrackerFeatures) -> [Double] {
        let count = beats.count
        let slowCount = features.slowCount
        guard count > 8, slowCount > 0 else { return [Double](repeating: 0, count: count) }
        var prefix = [[Double]](repeating: [Double](repeating: 0, count: 16), count: slowCount + 1)
        for i in 0..<slowCount {
            for c in 0..<12 { prefix[i + 1][c] = prefix[i][c] + 2 * Double(features.chroma[i * 12 + c]) }
            for b in 0..<4 { prefix[i + 1][12 + b] = prefix[i][12 + b] + Double(features.bandEnergy[i * 4 + b]) }
        }
        func index(_ t: Double) -> Int { max(0, min(slowCount, Int(features.slowIndex(ofTime: t).rounded(.up)))) }
        func mean(_ a: Int, _ b: Int) -> [Double]? {
            guard b > a else { return nil }
            return (0..<16).map { (prefix[b][$0] - prefix[a][$0]) / Double(b - a) }
        }
        var out = [Double](repeating: 0, count: count)
        for n in 4..<max(4, count - 4) {
            guard let before = mean(index(beats[n - 4]), index(beats[n])),
                  let after = mean(index(beats[n]), index(beats[n + 4])) else { continue }
            var sum = 0.0
            for d in 0..<16 { sum += (before[d] - after[d]) * (before[d] - after[d]) }
            out[n] = sqrt(sum)
        }
        return out
    }

    static func downbeatFeatures(
        beats: [Double],
        features: BeatTrackerFeatures,
        low: [Float],
        mid: [Float],
        high: [Float]
    ) -> [[Double]] {
        let count = beats.count
        let frames = low.count
        let radius = max(2, Int((0.03 * features.frameRate).rounded()))
        func peak(_ x: [Float], at time: Double) -> Double {
            let f = max(0, min(frames - 1, Int(features.frame(ofTime: time).rounded())))
            var best: Float = 0
            for k in max(0, f - radius)...min(frames - 1, f + radius) { best = max(best, x[k]) }
            return Double(best)
        }

        let slowCount = features.slowCount
        func slowRange(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = max(0, min(slowCount, Int(features.slowIndex(ofTime: a).rounded(.up))))
            let hi = max(lo, min(slowCount, Int(features.slowIndex(ofTime: b).rounded(.up))))
            return lo..<hi
        }
        func meanVector(_ range: Range<Int>) -> [Double] {
            var v = [Double](repeating: 0, count: 16)
            guard !range.isEmpty else { return v }
            for s in range {
                for c in 0..<12 { v[c] += Double(features.chroma[s * 12 + c]) }
                for b in 0..<4 { v[12 + b] += Double(features.bandEnergy[s * 4 + b]) }
            }
            let inv = 1 / Double(range.count)
            return v.map { $0 * inv }
        }
        func chromaDistance(_ a: [Double], _ b: [Double]) -> Double {
            var dot = 0.0, na = 0.0, nb = 0.0
            for c in 0..<12 { dot += a[c] * b[c]; na += a[c] * a[c]; nb += b[c] * b[c] }
            guard na > 1e-12, nb > 1e-12 else { return 0 }
            return 1 - dot / sqrt(na * nb)
        }
        func energyDistance(_ a: [Double], _ b: [Double], bands: Range<Int>) -> Double {
            var s = 0.0
            for k in bands { s += (a[12 + k] - b[12 + k]) * (a[12 + k] - b[12 + k]) }
            return sqrt(s)
        }

        var kick = [Double](repeating: 0, count: count)
        var snare = [Double](repeating: 0, count: count)
        var harmonic = [Double](repeating: 0, count: count)
        var lowEnergy = [Double](repeating: 0, count: count)
        var highEnergy = [Double](repeating: 0, count: count)
        for n in 0..<count {
            kick[n] = peak(low, at: beats[n])
            snare[n] = peak(mid, at: beats[n]) + 0.5 * peak(high, at: beats[n])
            let period = n + 1 < count ? beats[n + 1] - beats[n] : beats[n] - beats[max(0, n - 1)]
            let before = meanVector(slowRange(n >= 4 ? beats[n - 4] : beats[n] - 4 * period, beats[n]))
            let after = meanVector(slowRange(beats[n], n + 4 < count ? beats[n + 4] : beats[n] + 4 * period))
            harmonic[n] = chromaDistance(before, after)
            lowEnergy[n] = energyDistance(before, after, bands: 0..<2)
            highEnergy[n] = energyDistance(before, after, bands: 2..<4)
        }
        var crash = [Double](repeating: 0, count: count)
        for n in 0..<count { crash[n] = peak(high, at: beats[n]) }
        var beatChange = [Double](repeating: 0, count: count)
        for n in 2..<max(2, count - 2) {
            let previous = meanVector(slowRange(beats[n - 1], beats[n]))
            let current = meanVector(slowRange(beats[n], beats[n + 1]))
            beatChange[n] = chromaDistance(previous, current) + energyDistance(previous, current, bands: 0..<1)
        }
        return [relative(kick), relative(snare), events(harmonic), events(lowEnergy), events(highEnergy), relative(crash), relative(beatChange)]
    }

    static func relative(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Double(x.count)
        guard mean > 1e-9 else { return x.map { _ in 0 } }
        return x.map { min(3, max(-1, $0 / mean - 1)) }
    }

    static func events(_ x: [Double], radius: Int = 8) -> [Double] {
        guard !x.isEmpty else { return x }
        var residual = [Double](repeating: 0, count: x.count)
        for n in x.indices {
            let window = Array(x[max(0, n - radius)...min(x.count - 1, n + radius)])
            residual[n] = x[n] - median(window)
        }
        let centre = median(residual)
        let mad = median(residual.map { abs($0 - centre) })
        let scale = 1.4826 * mad + 1e-9
        return residual.map { min(10, max(0, ($0 - centre) / scale - 3)) }
    }

    static func choosePhases(perBeat: [[Double]]) -> [Int] {
        let count = perBeat.count
        let windowBeats = 32
        let windows = max(1, (count + windowBeats - 1) / windowBeats)
        var windowScores = [[Double]](repeating: [0, 0, 0, 0], count: windows)
        for w in 0..<windows {
            let lo = w * windowBeats
            let hi = min(count, lo + windowBeats)
            for phase in 0..<4 {
                var total = 0.0
                for n in lo..<hi { total += perBeat[n][((n - phase) % 4 + 4) % 4] }
                windowScores[w][phase] = total / Double(max(1, hi - lo))
            }
        }

        let switchCost = 0.35
        var cost = windowScores[0]
        var backPointer = [[Int]](repeating: [0, 1, 2, 3], count: windows)
        for w in 1..<max(1, windows) {
            var next = [Double](repeating: 0, count: 4)
            for phase in 0..<4 {
                var best = -Double.infinity
                var from = phase
                for previous in 0..<4 {
                    let v = cost[previous] - (previous == phase ? 0 : switchCost)
                    if v > best {
                        best = v
                        from = previous
                    }
                }
                next[phase] = best + windowScores[w][phase]
                backPointer[w][phase] = from
            }
            cost = next
        }
        var path = [Int](repeating: 0, count: windows)
        path[windows - 1] = cost.indices.max { cost[$0] < cost[$1] } ?? 0
        if windows > 1 {
            for w in stride(from: windows - 1, to: 0, by: -1) { path[w - 1] = backPointer[w][path[w]] }
        }
        return (0..<count).map { path[min(windows - 1, $0 / windowBeats)] }
    }

    // MARK: - Phrases

    struct PhraseEstimate {
        let offset: Int
        let phraseBarIndices: [Int]
        let sectionBarIndices: [Int]
        let margin: Double
        var sectionStrengths: [Double] = []
    }

    static func estimatePhrases(
        beats: [Double],
        downbeatIndices: [Int],
        features: BeatTrackerFeatures,
        high: [Float]
    ) -> PhraseEstimate {
        let bars = downbeatIndices.map { beats[$0] }
        guard bars.count >= 16 else {
            return PhraseEstimate(offset: 0, phraseBarIndices: Array(stride(from: 0, to: bars.count, by: 8)), sectionBarIndices: [], margin: 0)
        }
        let slowCount = features.slowCount
        func vector(_ a: Double, _ b: Double) -> [Double] {
            let lo = max(0, min(slowCount, Int(features.slowIndex(ofTime: a).rounded(.up))))
            let hi = max(lo, min(slowCount, Int(features.slowIndex(ofTime: b).rounded(.up))))
            var v = [Double](repeating: 0, count: 16)
            guard hi > lo else { return v }
            for s in lo..<hi {
                for c in 0..<12 { v[c] += 2 * Double(features.chroma[s * 12 + c]) }
                for k in 0..<4 { v[12 + k] += Double(features.bandEnergy[s * 4 + k]) }
            }
            return v.map { $0 / Double(hi - lo) }
        }
        let barLength = (bars[bars.count - 1] - bars[0]) / Double(bars.count - 1)
        func barEnd(_ k: Int) -> Double { k + 1 < bars.count ? bars[k + 1] : bars[k] + barLength }
        let barVectors = bars.indices.map { vector(bars[$0], barEnd($0)) }
        let frames = high.count
        let radius = max(2, Int((0.03 * features.frameRate).rounded()))
        var novelty = [Double](repeating: 0, count: bars.count)
        for k in 2..<(bars.count - 1) {
            var before = [Double](repeating: 0, count: 16)
            var after = [Double](repeating: 0, count: 16)
            for j in max(0, k - 2)..<k { for d in 0..<16 { before[d] += barVectors[j][d] } }
            for j in k..<min(bars.count, k + 2) { for d in 0..<16 { after[d] += barVectors[j][d] } }
            let nb = Double(k - max(0, k - 2)), na = Double(min(bars.count, k + 2) - k)
            var s = 0.0
            for d in 0..<16 { s += pow(before[d] / nb - after[d] / na, 2) }
            let f = max(0, min(frames - 1, Int(features.frame(ofTime: bars[k]).rounded())))
            var hit: Float = 0
            for x in max(0, f - radius)...min(frames - 1, f + radius) { hit = max(hit, high[x]) }
            novelty[k] = sqrt(s) + 0.05 * Double(hit)
        }
        let z = zScored(novelty)

        var offsetScores = [Double](repeating: 0, count: 8)
        var offsetCounts = [Double](repeating: 0, count: 8)
        for k in bars.indices {
            offsetScores[k % 8] += z[k]
            offsetCounts[k % 8] += 1
        }
        for o in 0..<8 { offsetScores[o] /= max(1, offsetCounts[o]) }
        let ranked = offsetScores.indices.sorted { offsetScores[$0] > offsetScores[$1] }
        let best = ranked[0]
        let margin = offsetScores[best] - offsetScores[ranked[1]]
        let offset = margin > 0.25 && offsetScores[best] > 0.3 ? best : 0
        let phraseBars = Array(stride(from: offset, to: bars.count, by: 8))

        var sections: [Int] = []
        var strengths: [Int: Double] = [:]
        for k in bars.indices where z[k] > 1.5 {
            let lo = max(0, k - 4), hi = min(bars.count - 1, k + 4)
            guard (lo...hi).allSatisfy({ z[$0] <= z[k] }) else { continue }
            let nearest = phraseBars.min { abs($0 - k) < abs($1 - k) } ?? k
            let snapped = abs(nearest - k) <= 1 ? nearest : k
            if !sections.contains(snapped) { sections.append(snapped) }
            strengths[snapped] = max(strengths[snapped] ?? 0, z[k])
        }
        let sorted = sections.sorted()
        var estimate = PhraseEstimate(offset: offset, phraseBarIndices: phraseBars, sectionBarIndices: sorted, margin: margin)
        estimate.sectionStrengths = sorted.map { strengths[$0] ?? 0 }
        return estimate
    }

    // MARK: - Helpers

    static func normalisedByMean(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        guard mean > 1e-9 else { return x }
        var inv = 1 / mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsmul(x, 1, &inv, &out, 1, vDSP_Length(x.count))
        return out
    }

    static func highPassed(_ x: [Float], radius: Int) -> [Float] {
        let n = x.count
        guard n > 0, radius > 0 else { return x }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - radius), b = min(n, i + radius + 1)
            let mean = (prefix[b] - prefix[a]) / Double(b - a)
            out[i] = max(0, x[i] - Float(mean))
        }
        return out
    }

    static func normaliseByStd(_ x: inout [Float]) {
        var mean: Float = 0
        var std: Float = 0
        vDSP_normalize(x, 1, nil, 1, &mean, &std, vDSP_Length(x.count))
        guard std > 1e-9 else { return }
        var inv = 1 / std
        vDSP_vsmul(x, 1, &inv, &x, 1, vDSP_Length(x.count))
    }

    static func zScored(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Double(x.count)
        let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)
        let std = sqrt(variance)
        guard std > 1e-12 else { return x.map { _ in 0 } }
        return x.map { max(-3, min(6, ($0 - mean) / std)) }
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
}
