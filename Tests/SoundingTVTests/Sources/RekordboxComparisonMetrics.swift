import Foundation
#if os(macOS)
@testable import SoundingTV_macOS
#else
@testable import SoundingTV
#endif

struct EngineObservation: Sendable {
    let name: String
    var bpm: Double?
    var beats: [Double] = []
    var downbeats: [Double] = []
    var measuredBeats = false
    var measuredDownbeats = false
    var phraseStarts: [Double] = []
    var sections: [TrackSection] = []
    var key: CamelotKey?
    var energy: Int?
    var cueSuggestions: [Double] = []
    var seconds: Double = 0
    var producerSeconds: [String: Double] = [:]
    var failure: String?

    init(name: String, failure: String? = nil) {
        self.name = name
        self.failure = failure
    }

    init(name: String, features: TrackFeatures, duration: Double, seconds: Double, producerSeconds: [String: Double], failure: String?) {
        self.name = name
        self.seconds = seconds
        self.producerSeconds = producerSeconds
        self.failure = failure
        let provenance = features.provenance
        if let grid = features.beatGrid, grid.beatPeriod > 0 {
            bpm = grid.bpm
            measuredBeats = provenance.contains(.measuredBeatGrid)
            measuredDownbeats = provenance.contains(.measuredDownbeats)
            beats = (grid.beats?.count ?? 0) >= 2 ? grid.beats! : Self.lattice(from: grid.anchor, step: grid.beatPeriod, until: duration)
            downbeats = (grid.downbeats?.count ?? 0) >= 2 ? grid.downbeats! : Self.lattice(from: grid.firstDownbeat, step: grid.barDuration, until: duration)
        }
        phraseStarts = features.phraseBoundaries.sorted()
        sections = features.sections.sorted { $0.start < $1.start }
        key = Self.majorityKey(features.keyRegions)
        energy = features.energyLevel
        cueSuggestions = CueSuggester.suggest(CueSuggester.Input(features: features)).map(\.positionSeconds).sorted()
    }

    static func lattice(from anchor: Double, step: Double, until end: Double) -> [Double] {
        guard step > 0, anchor.isFinite, end > 0 else { return [] }
        var t = anchor - (anchor / step).rounded(.down) * step
        var out: [Double] = []
        while t <= end {
            out.append(t)
            t += step
        }
        return out
    }

    static func majorityKey(_ regions: [KeyRegion]) -> CamelotKey? {
        var weight: [CamelotKey: Double] = [:]
        for region in regions where region.end > region.start {
            weight[region.key, default: 0] += region.end - region.start
        }
        if weight.isEmpty { return regions.first?.key }
        return weight.max { $0.value < $1.value }?.key
    }

    var sectionStarts: [Double] { sections.map(\.start) }

    var introEndSeconds: Double? {
        guard let first = sections.first else { return nil }
        guard [SectionKind.intro, .ambientIntro].contains(first.kind) else { return first.start }
        var end = first.end
        for section in sections.dropFirst() {
            guard [SectionKind.intro, .ambientIntro].contains(section.kind) else { break }
            end = section.end
        }
        return end
    }

    var outroStartSeconds: Double? {
        guard let last = sections.last else { return nil }
        guard [SectionKind.outro, .ambientOutro].contains(last.kind) else { return last.end }
        var start = last.start
        for section in sections.reversed().dropFirst() {
            guard [SectionKind.outro, .ambientOutro].contains(section.kind) else { break }
            start = section.start
        }
        return start
    }
}

enum BPMClass: String, Sendable, CaseIterable {
    case exact
    case close = "within 0.5"
    case halfTime = "half-time"
    case doubleTime = "double-time"
    case other
    case missing
}

enum KeyClass: String, Sendable, CaseIterable {
    case exact
    case relative
    case adjacent = "±1 Camelot"
    case other
    case missing
}

struct BeatAlignment: Sendable {
    var medianAbsMs: Double
    var p90AbsMs: Double
    var medianSignedMs: Double
    var fMeasure70: Double
    var startOffsetMs: Double
    var endOffsetMs: Double
    var matched: Int

    var driftMs: Double { endOffsetMs - startOffsetMs }
}

struct DownbeatAgreement: Sendable {
    var firstDownbeatDeltaMs: Double?
    var firstAgrees: Bool
    var barPhaseShift: Int?
    var barPhaseAgreement: Double
}

struct TempoFollow: Sendable {
    var followFraction: Double
    var oursVariable: Bool
}

struct BoundaryScore: Sendable {
    var f: Double
    var precision: Double
    var recall: Double
}

enum ComparisonMetrics {
    static let beatToleranceSeconds = 0.07

    static func classifyBPM(ours: Double?, reference: Double) -> BPMClass {
        guard let ours, ours > 0 else { return .missing }
        let delta = abs(ours - reference)
        if delta <= 0.05 { return .exact }
        if delta <= 0.5 { return .close }
        if abs(ours * 2 - reference) <= 1.0 { return .halfTime }
        if abs(ours - reference * 2) <= 1.0 { return .doubleTime }
        return .other
    }

    static func classifyKey(ours: CamelotKey?, reference: CamelotKey) -> KeyClass {
        guard let ours else { return .missing }
        switch RekordboxKeyAgreement.relation(ours: ours.label, theirs: reference.label) ?? .other {
        case .exact: return .exact
        case .relative: return .relative
        case .neighbour: return .adjacent
        case .other: return .other
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }

    static func nearestIndex(in sorted: [Double], to value: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(sorted[low - 1] - value) <= abs(sorted[low] - value) { return low - 1 }
        return low
    }

    static func medianInterval(_ times: [Double]) -> Double? {
        median(zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 })
    }

    static func alignBeats(reference: [Double], ours: [Double]) -> BeatAlignment? {
        guard reference.count >= 8, ours.count >= 8,
              let refPeriod = medianInterval(reference), let ourPeriod = medianInterval(ours) else { return nil }
        let lower = max(reference[0], ours[0]) - beatToleranceSeconds
        let upper = min(reference[reference.count - 1], ours[ours.count - 1]) + beatToleranceSeconds
        guard upper > lower else { return nil }
        let refWindow = reference.filter { $0 >= lower && $0 <= upper }
        let ourWindow = ours.filter { $0 >= lower && $0 <= upper }
        guard refWindow.count >= 4, ourWindow.count >= 4 else { return nil }
        let oursSparser = ourPeriod > refPeriod * 1.5
        let sparse = oursSparser ? ourWindow : refWindow
        let dense = oursSparser ? reference : ours
        var signed: [Double] = []
        signed.reserveCapacity(sparse.count)
        for t in sparse {
            guard let j = nearestIndex(in: dense, to: t) else { continue }
            signed.append(oursSparser ? t - dense[j] : dense[j] - t)
        }
        guard !signed.isEmpty else { return nil }
        let absolute = signed.map(abs)
        func hits(_ from: [Double], _ to: [Double]) -> Int {
            from.reduce(0) { count, t in
                guard let j = nearestIndex(in: to, to: t) else { return count }
                return abs(to[j] - t) <= beatToleranceSeconds ? count + 1 : count
            }
        }
        let recall = Double(hits(refWindow, ours)) / Double(refWindow.count)
        let precision = Double(hits(ourWindow, reference)) / Double(ourWindow.count)
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        let edge = min(32, max(1, signed.count / 4))
        return BeatAlignment(
            medianAbsMs: (median(absolute) ?? 0) * 1000,
            p90AbsMs: (percentile(absolute, 0.9) ?? 0) * 1000,
            medianSignedMs: (median(signed) ?? 0) * 1000,
            fMeasure70: f,
            startOffsetMs: (median(Array(signed.prefix(edge))) ?? 0) * 1000,
            endOffsetMs: (median(Array(signed.suffix(edge))) ?? 0) * 1000,
            matched: absolute.filter { $0 <= beatToleranceSeconds }.count
        )
    }

    static func beatInBar(beats: [Double], downbeats: [Double], tolerance: Double) -> [Int] {
        guard !beats.isEmpty else { return [] }
        let downbeatIndices = Set(downbeats.compactMap { d -> Int? in
            guard let j = nearestIndex(in: beats, to: d), abs(beats[j] - d) <= tolerance else { return nil }
            return j
        })
        guard let first = downbeatIndices.min() else { return [] }
        var out = [Int](repeating: 0, count: beats.count)
        var counter = 0
        for j in beats.indices {
            if j < first {
                out[j] = ((j - first) % 4 + 4) % 4
                continue
            }
            if downbeatIndices.contains(j) { counter = 0 }
            out[j] = counter % 4
            counter += 1
        }
        return out
    }

    static func downbeats(reference: RekordboxReferenceTrack, ours: EngineObservation) -> DownbeatAgreement? {
        let refDownbeats = reference.downbeatTimes
        guard let refFirst = refDownbeats.first, ours.downbeats.count >= 2, ours.beats.count >= 8 else { return nil }
        let firstDelta = nearestIndex(in: ours.downbeats, to: refFirst).map { ours.downbeats[$0] - refFirst }
        let period = medianInterval(ours.beats) ?? reference.medianBeatPeriod
        let positions = beatInBar(beats: ours.beats, downbeats: ours.downbeats, tolerance: period / 3)
        guard positions.count == ours.beats.count else { return nil }
        var histogram = [0, 0, 0, 0]
        for d in refDownbeats {
            guard let j = nearestIndex(in: ours.beats, to: d), abs(ours.beats[j] - d) <= period / 2 else { continue }
            histogram[positions[j]] += 1
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else {
            return DownbeatAgreement(firstDownbeatDeltaMs: firstDelta.map { $0 * 1000 }, firstAgrees: false, barPhaseShift: nil, barPhaseAgreement: 0)
        }
        let mode = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        return DownbeatAgreement(
            firstDownbeatDeltaMs: firstDelta.map { $0 * 1000 },
            firstAgrees: firstDelta.map { abs($0) <= beatToleranceSeconds } ?? false,
            barPhaseShift: mode,
            barPhaseAgreement: Double(histogram[0]) / Double(total)
        )
    }

    static func localBPM(_ times: [Double], at t: Double, span: Int = 8) -> Double? {
        guard times.count > span * 2, let j = nearestIndex(in: times, to: t) else { return nil }
        let lower = max(0, min(j - span, times.count - 1 - 2 * span))
        let upper = lower + 2 * span
        let period = (times[upper] - times[lower]) / Double(2 * span)
        return period > 0 ? 60 / period : nil
    }

    static func tempoFollow(reference: RekordboxReferenceTrack, ours: EngineObservation) -> TempoFollow? {
        let times = reference.beatTimes
        guard times.count >= 48, ours.beats.count >= 32 else { return nil }
        var checked = 0
        var followed = 0
        var oursLocal: [Double] = []
        for i in stride(from: 16, to: times.count - 16, by: 16) {
            guard let refLocal = localBPM(times, at: times[i]), var mine = localBPM(ours.beats, at: times[i]) else { continue }
            if abs(mine * 2 - refLocal) < abs(mine - refLocal) { mine *= 2 }
            if abs(mine / 2 - refLocal) < abs(mine - refLocal) { mine /= 2 }
            oursLocal.append(mine)
            checked += 1
            if abs(mine - refLocal) / refLocal <= 0.01 { followed += 1 }
        }
        guard checked > 0 else { return nil }
        let spread = (percentile(oursLocal, 0.95) ?? 0) - (percentile(oursLocal, 0.05) ?? 0)
        return TempoFollow(followFraction: Double(followed) / Double(checked), oursVariable: spread >= 0.5)
    }

    static func boundaries(reference: [Double], estimate: [Double], tolerance: Double) -> BoundaryScore? {
        guard !reference.isEmpty else { return nil }
        guard !estimate.isEmpty else { return BoundaryScore(f: 0, precision: 0, recall: 0) }
        var pairs: [(distance: Double, r: Int, e: Int)] = []
        for (r, rt) in reference.enumerated() {
            for (e, et) in estimate.enumerated() where abs(rt - et) <= tolerance {
                pairs.append((abs(rt - et), r, e))
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedR = Set<Int>()
        var usedE = Set<Int>()
        for pair in pairs where !usedR.contains(pair.r) && !usedE.contains(pair.e) {
            usedR.insert(pair.r)
            usedE.insert(pair.e)
        }
        let hits = Double(usedR.count)
        let precision = hits / Double(estimate.count)
        let recall = hits / Double(reference.count)
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return BoundaryScore(f: f, precision: precision, recall: recall)
    }

    static func fractionNear(_ points: [Double], _ targets: [Double], tolerance: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let sorted = targets.sorted()
        let hits = points.filter { p in nearestIndex(in: sorted, to: p).map { abs(sorted[$0] - p) <= tolerance } ?? false }
        return Double(hits.count) / Double(points.count)
    }

    static func phraseWindow(_ times: [Double], reference: RekordboxReferenceTrack, tolerance: Double) -> [Double] {
        let start = (reference.beatTimes.first ?? 0) + reference.medianBeatPeriod / 2
        let end = (reference.phraseEndSeconds ?? reference.beatTimes.last ?? .greatestFiniteMagnitude) + tolerance
        return times.filter { $0 > start && $0 <= end }
    }
}

struct EngineComparison: Sendable {
    var observation: EngineObservation
    var bpmClass: BPMClass?
    var bpmError: Double?
    var beat: BeatAlignment?
    var downbeat: DownbeatAgreement?
    var tempo: TempoFollow?
    var phraseBeat: BoundaryScore?
    var phraseBar: BoundaryScore?
    var sectionBar: BoundaryScore?
    var introErrorBars: Double?
    var outroErrorBars: Double?
    var oursIntroBars: Double?
    var oursOutroBars: Double?
    var keyClass: KeyClass?
    var cueOnPhrase: Double?
    var cueOnSuggestion: Double?
    var referenceVariable: Bool

    var isOctaveError: Bool { bpmClass == .halfTime || bpmClass == .doubleTime }
    var isWithinHalfBPM: Bool { bpmClass == .exact || bpmClass == .close }

    init(reference: RekordboxReferenceTrack, observation: EngineObservation, referenceKey: CamelotKey?) {
        self.observation = observation
        referenceVariable = reference.hasVariableTempo
        if let refBPM = reference.dominantBPM, refBPM > 0 {
            bpmClass = ComparisonMetrics.classifyBPM(ours: observation.bpm, reference: refBPM)
            bpmError = observation.bpm.map { $0 - refBPM }
        }
        beat = ComparisonMetrics.alignBeats(reference: reference.beatTimes, ours: observation.beats)
        downbeat = ComparisonMetrics.downbeats(reference: reference, ours: observation)
        tempo = ComparisonMetrics.tempoFollow(reference: reference, ours: observation)
        let period = reference.medianBeatPeriod
        let bar = period * 4
        if !reference.phrases.isEmpty {
            let refBoundaries = ComparisonMetrics.phraseWindow(reference.phraseStarts, reference: reference, tolerance: bar)
            let ourPhrases = ComparisonMetrics.phraseWindow(observation.phraseStarts, reference: reference, tolerance: bar)
            let ourSections = ComparisonMetrics.phraseWindow(observation.sectionStarts, reference: reference, tolerance: bar)
            phraseBeat = ComparisonMetrics.boundaries(reference: refBoundaries, estimate: ourPhrases, tolerance: period)
            phraseBar = ComparisonMetrics.boundaries(reference: refBoundaries, estimate: ourPhrases, tolerance: bar)
            sectionBar = ComparisonMetrics.boundaries(reference: refBoundaries, estimate: ourSections, tolerance: bar)
            let origin = reference.beatTimes.first ?? 0
            let end = reference.phraseEndSeconds ?? reference.beatTimes.last ?? 0
            if let refIntro = reference.introEndSeconds, bar > 0, observation.bpm != nil || !observation.sections.isEmpty {
                let mine = observation.introEndSeconds ?? origin
                oursIntroBars = max(0, mine - origin) / bar
                introErrorBars = (mine - refIntro) / bar
            }
            if let refOutro = reference.outroStartSeconds, bar > 0, observation.bpm != nil || !observation.sections.isEmpty {
                let mine = observation.outroStartSeconds ?? end
                oursOutroBars = max(0, end - mine) / bar
                outroErrorBars = (refOutro - mine) / bar
            }
        }
        if let referenceKey {
            keyClass = ComparisonMetrics.classifyKey(ours: observation.key, reference: referenceKey)
        }
        let cues = reference.allCueSeconds
        if !cues.isEmpty, bar > 0 {
            let boundaries = observation.phraseStarts.isEmpty ? observation.sectionStarts : observation.phraseStarts
            cueOnPhrase = ComparisonMetrics.fractionNear(cues, boundaries, tolerance: bar)
            cueOnSuggestion = ComparisonMetrics.fractionNear(cues, observation.cueSuggestions, tolerance: bar)
        }
    }
}

struct TrackComparison: Sendable {
    var reference: RekordboxReferenceTrack
    var title: String
    var artist: String
    var genre: String
    var duration: Double
    var referenceKey: CamelotKey?
    var engines: [EngineComparison]
    var failure: String?

    var fileName: String { reference.fileName }
    var referenceBPM: Double? { reference.dominantBPM }

    var referenceIntroBars: Double? {
        let bar = reference.medianBeatPeriod * 4
        guard let end = reference.introEndSeconds, bar > 0 else { return nil }
        return max(0, end - (reference.beatTimes.first ?? 0)) / bar
    }

    var referenceOutroBars: Double? {
        let bar = reference.medianBeatPeriod * 4
        guard let start = reference.outroStartSeconds, bar > 0 else { return nil }
        let end = reference.phraseEndSeconds ?? reference.beatTimes.last ?? start
        return max(0, end - start) / bar
    }

    var bpmRange: String {
        guard let bpm = referenceBPM else { return "no grid" }
        switch bpm {
        case ..<100: return "< 100"
        case ..<115: return "100–115"
        case ..<125: return "115–125"
        case ..<135: return "125–135"
        case ..<150: return "135–150"
        default: return "150+"
        }
    }
}
