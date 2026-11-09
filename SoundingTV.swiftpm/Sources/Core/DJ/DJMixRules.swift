import Foundation

enum DJMixRules {
    static let maximumLoopRepeatBars = 16
    static let keyClashOverlapBars = 4.05
    static let unmeasuredVocalOverlapBars = 8.05
    static let phraseBeatTolerance = 0.15
    static let phraseBarTolerance = 0.5
    static let maxLevelStepDecibels: Double = 6

    static func vocalOverlapSeconds(
        outgoing: [ClosedRange<TimeInterval>],
        from outStart: TimeInterval,
        length: TimeInterval,
        incoming: [ClosedRange<TimeInterval>],
        entry inStart: TimeInterval
    ) -> TimeInterval {
        var overlap = 0.0
        for o in outgoing {
            let oLo = max(o.lowerBound, outStart)
            let oHi = min(o.upperBound, outStart + length)
            guard oHi > oLo else { continue }
            for i in incoming {
                let iLo = i.lowerBound - inStart + outStart
                let iHi = i.upperBound - inStart + outStart
                overlap += max(0, min(oHi, iHi) - max(oLo, iLo))
            }
        }
        return overlap
    }

    static func keySteps(_ a: CamelotKey, _ b: CamelotKey) -> Int {
        let steps = a.wheelSteps(to: b)
        return a.mode == b.mode || steps == 0 ? steps : steps + 1
    }

    static func phraseOffsets(exitBeats: Double, entryBeats: Double) -> (bar: Double, phrase: Double) {
        func fold(_ beats: Double, modulo m: Double) -> Double {
            let r = beats.truncatingRemainder(dividingBy: m)
            return min(abs(r), m - abs(r))
        }
        let exit = abs(exitBeats)
        let entry = abs(entryBeats)
        return ((fold(exit, modulo: 4) + fold(entry, modulo: 4)) / 2, (fold(exit, modulo: 32) + fold(entry, modulo: 32)) / 2)
    }

    static func phrasesLineUp(exitBeats: Double, entryBeats: Double) -> Bool {
        let offsets = phraseOffsets(exitBeats: exitBeats, entryBeats: entryBeats)
        return offsets.bar < phraseBeatTolerance && offsets.phrase < phraseBarTolerance
    }
}

protocol MixLevelTrimming: Sendable {
    func trimDecibels(outgoing: TrackFeatures, incoming: TrackFeatures) -> (outgoing: Float, incoming: Float)
}

struct BodyLevelTrim: MixLevelTrimming {
    static let maximumCutDecibels: Float = 9.1

    func trimDecibels(outgoing: TrackFeatures, incoming: TrackFeatures) -> (outgoing: Float, incoming: Float) {
        guard let a = Self.body(outgoing), let b = Self.body(incoming) else { return (0, 0) }
        let target = min(a, b)
        return (max(-Self.maximumCutDecibels, target - a), max(-Self.maximumCutDecibels, target - b))
    }

    static func body(_ track: TrackFeatures) -> Float? {
        guard let levels = track.barProfile?.level.filter({ $0 > -89 }), levels.count >= 8 else { return nil }
        let sorted = levels.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
    }
}

extension DJMixRules {
    static let levelTrim: any MixLevelTrimming = BodyLevelTrim()

    static func residualLevelStep(outgoing: TrackFeatures, outgoingLevel: Float, incoming: TrackFeatures, incomingLevel: Float) -> Float {
        let trim = levelTrim.trimDecibels(outgoing: outgoing, incoming: incoming)
        return abs((outgoingLevel + trim.outgoing) - (incomingLevel + trim.incoming))
    }

    static let percussiveTonality: Float = 1.45
    static let percussiveMidDropDecibels: Float = 6
    static let bandDecibelsPerUnit: Float = 4.343

    static func percussiveOnly(_ track: TrackFeatures, sourceRanges: [ClosedRange<TimeInterval>]) -> Bool? {
        let starts = track.barStarts
        guard !starts.isEmpty, !sourceRanges.isEmpty else { return nil }
        var bars = Set<Int>()
        for range in sourceRanges {
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : track.duration
                if end > range.lowerBound + 0.05, start < range.upperBound - 0.05 { bars.insert(index) }
            }
        }
        guard !bars.isEmpty else { return nil }
        if let arrangement = track.arrangement, bars.allSatisfy({ b in track.barStarts.indices.contains(b) && arrangement.role(at: track.barStarts[b]) == .introDrums }) {
            return true
        }
        guard let profile = track.barProfile, let tonality = profile.tonality, tonality.count == starts.count,
              let bands = profile.bands, bands.count == starts.count * 4 else { return nil }
        let mids = (0..<starts.count).map { bands[$0 * 4 + 2] * bandDecibelsPerUnit }.sorted()
        let typicalMid = mids[mids.count / 2]
        let vocalsKnown = track.provenance.contains(.measuredVocals)
        for bar in bars {
            let lo = starts[bar], hi = bar + 1 < starts.count ? starts[bar + 1] : track.duration
            if vocalsKnown, DJMoveSupport.vocalSeconds(track, lo...hi) > 0.05 { return false }
            if !vocalsKnown { return nil }
            guard tonality[bar] <= percussiveTonality, bands[bar * 4 + 2] * bandDecibelsPerUnit <= typicalMid - percussiveMidDropDecibels else { return false }
        }
        return true
    }
}

extension DJMixRules {
    static let busyDensity: Float = 0.6
    static let busyHighPassHertz = 400.0

    static func density(_ track: TrackFeatures, sourceRanges: [ClosedRange<TimeInterval>]) -> Float? {
        let bars = DJPlanValidator.barIndices(track, in: sourceRanges)
        guard !bars.isEmpty else { return nil }
        let values: [Float]
        if let arrangement = track.arrangement, arrangement.density.count == track.barStarts.count {
            values = bars.filter { $0 < arrangement.density.count }.map { arrangement.density[$0] }
        } else if let profile = track.barProfile, profile.density.count == track.barStarts.count {
            values = bars.filter { $0 < profile.density.count }.map { profile.density[$0] }
        } else {
            return nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func incomingIsBusy(_ incoming: TrackFeatures, from entry: TimeInterval, to arrival: TimeInterval) -> Bool {
        guard arrival > entry + 0.05 else { return false }
        if let arrangement = incoming.arrangement, let first = arrangement.bar(at: entry), let last = arrangement.bar(at: arrival - 0.05),
           (first...last).allSatisfy({ arrangement.role(atBar: $0) == .introDrums }) {
            return false
        }
        return (density(incoming, sourceRanges: [entry...arrival]) ?? 0) >= busyDensity
    }

}

extension DJMixRules {
    static let shortBlendBars = 16
    static let shortBlendRatePercent = 6.0
}
