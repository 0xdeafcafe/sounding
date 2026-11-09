import Foundation

struct BeatGrid: Equatable, Sendable, Codable {
    let anchor: TimeInterval
    let beatPeriod: Double
    let downbeatOffset: Int
    let barsPerPhrase: Int
    let confidence: Double
    let beats: [TimeInterval]?
    let downbeats: [TimeInterval]?
    let phraseOffsetBars: Int?

    init(
        anchor: TimeInterval,
        beatPeriod: Double,
        downbeatOffset: Int = 0,
        barsPerPhrase: Int = 8,
        confidence: Double,
        beats: [TimeInterval]? = nil,
        downbeats: [TimeInterval]? = nil,
        phraseOffsetBars: Int? = nil
    ) {
        self.anchor = anchor
        self.beatPeriod = beatPeriod
        self.downbeatOffset = downbeatOffset
        self.barsPerPhrase = barsPerPhrase
        self.confidence = confidence
        self.beats = beats
        self.downbeats = downbeats
        self.phraseOffsetBars = phraseOffsetBars
    }

    static func fromDisplayBPM(
        _ bpm: Double,
        anchor: TimeInterval = 0,
        barsPerPhrase: Int = 8,
        confidence: Double
    ) -> BeatGrid? {
        guard bpm.isFinite, bpm > 20, bpm < 300 else { return nil }
        return BeatGrid(
            anchor: anchor,
            beatPeriod: 60.0 / bpm,
            barsPerPhrase: barsPerPhrase,
            confidence: confidence
        )
    }

    static func tempoOnly(_ bpm: Double, barsPerPhrase: Int = 8) -> BeatGrid? {
        fromDisplayBPM(bpm, barsPerPhrase: barsPerPhrase, confidence: DJEngineConstants.tempoOnlyGridConfidence)
    }

    var bpm: Double { beatPeriod > 0 ? 60.0 / beatPeriod : 0 }
    var barDuration: Double { beatPeriod * 4 }
    var phraseDuration: Double { barDuration * Double(barsPerPhrase) }
    var firstDownbeat: TimeInterval {
        if let first = downbeats?.first { return first }
        return anchor + Double(downbeatOffset) * beatPeriod
    }

    var isPhaseVerified: Bool { (downbeats?.count ?? 0) >= 2 }

    var firstPhraseBar: Int {
        guard barsPerPhrase > 0 else { return 0 }
        return ((phraseOffsetBars ?? 0) % barsPerPhrase + barsPerPhrase) % barsPerPhrase
    }

    func nearestDownbeat(to seconds: TimeInterval) -> TimeInterval {
        if let downbeats, !downbeats.isEmpty {
            return downbeats.min { abs($0 - seconds) < abs($1 - seconds) } ?? seconds
        }
        guard barDuration > 0 else { return seconds }
        return firstDownbeat + ((seconds - firstDownbeat) / barDuration).rounded() * barDuration
    }

    func phraseStarts(from lower: TimeInterval, through upper: TimeInterval) -> [TimeInterval] {
        guard barsPerPhrase > 0 else { return [] }
        if let downbeats, downbeats.count >= 2 {
            return stride(from: firstPhraseBar, to: downbeats.count, by: barsPerPhrase)
                .map { downbeats[$0] }
                .filter { $0 >= lower && $0 <= upper }
        }
        guard phraseDuration > 0 else { return [] }
        var out: [TimeInterval] = []
        var t = firstDownbeat + Double(firstPhraseBar) * barDuration
        if t < lower { t += ((lower - t) / phraseDuration).rounded(.up) * phraseDuration }
        while t <= upper {
            out.append(t)
            t += phraseDuration
        }
        return out
    }

    func localBeatPeriod(at seconds: TimeInterval, spanBeats: Int = 16) -> Double {
        guard let beats, beats.count > spanBeats else { return beatPeriod }
        let index = beats.firstIndex { $0 >= seconds } ?? beats.count - 1
        let lower = max(0, min(index - spanBeats / 2, beats.count - 1 - spanBeats))
        let upper = lower + spanBeats
        let period = (beats[upper] - beats[lower]) / Double(spanBeats)
        return period.isFinite && period > 0 ? period : beatPeriod
    }

    func meanBeatPeriod(from start: TimeInterval, to end: TimeInterval) -> Double {
        guard let beats, beats.count >= 8, end > start else { return beatPeriod }
        guard let first = beats.firstIndex(where: { $0 >= start }) else { return beatPeriod }
        let last = beats.lastIndex { $0 <= end } ?? first
        guard last - first >= 4 else { return localBeatPeriod(at: start) }
        let period = (beats[last] - beats[first]) / Double(last - first)
        return period.isFinite && period > 0 ? period : beatPeriod
    }

    func localized(from start: TimeInterval, to end: TimeInterval) -> BeatGrid {
        let period = meanBeatPeriod(from: start, to: end)
        guard abs(period - beatPeriod) > 1e-9 else { return self }
        return BeatGrid(
            anchor: anchor,
            beatPeriod: period,
            downbeatOffset: downbeatOffset,
            barsPerPhrase: barsPerPhrase,
            confidence: confidence,
            beats: beats,
            downbeats: downbeats,
            phraseOffsetBars: phraseOffsetBars
        )
    }

    func beatPhase(at time: TimeInterval) -> Double {
        guard beatPeriod > 0 else { return 0 }
        let rel = time - anchor
        let m = rel.truncatingRemainder(dividingBy: beatPeriod)
        return m < 0 ? m + beatPeriod : m
    }

    func beatsFromPhraseBoundary(at time: TimeInterval) -> Double {
        guard beatPeriod > 0, phraseDuration > 0 else { return 0 }
        let beatsIn = (time - firstDownbeat) / beatPeriod - Double(firstPhraseBar * 4)
        let phraseBeats = Double(barsPerPhrase * 4)
        var m = beatsIn.truncatingRemainder(dividingBy: phraseBeats)
        if m < 0 { m += phraseBeats }
        return m > phraseBeats / 2 ? m - phraseBeats : m
    }

    func seconds(bars: Double) -> TimeInterval { barDuration * bars }
    func bars(seconds: TimeInterval) -> Double { barDuration > 0 ? seconds / barDuration : 0 }

    func nearestBeat(to seconds: TimeInterval) -> TimeInterval {
        if let beats, !beats.isEmpty {
            return beats.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? seconds
        }
        guard beatPeriod > 0 else { return seconds }
        return anchor + ((seconds - anchor) / beatPeriod).rounded() * beatPeriod
    }

    static func fromMeasuredBars(
        bpm: Double,
        beats: [TimeInterval],
        bars: [TimeInterval],
        barsPerPhrase: Int = 8,
        confidence: Double,
        phraseOffsetBars: Int? = nil
    ) -> BeatGrid? {
        guard bpm.isFinite, bpm > 20, bpm < 300 else { return nil }
        guard let anchor = beats.first ?? bars.first else { return nil }
        let beatPeriod = 60.0 / bpm

        var downbeatOffset = 0
        if let firstBar = bars.first, beatPeriod > 0 {
            let raw = Int(((firstBar - anchor) / beatPeriod).rounded())
            downbeatOffset = ((raw % 4) + 4) % 4
        }

        return BeatGrid(
            anchor: anchor,
            beatPeriod: beatPeriod,
            downbeatOffset: downbeatOffset,
            barsPerPhrase: barsPerPhrase,
            confidence: confidence,
            beats: beats.isEmpty ? nil : beats,
            downbeats: bars.isEmpty ? nil : bars,
            phraseOffsetBars: phraseOffsetBars
        )
    }
}

struct FeatureProvenance: OptionSet, Sendable, Codable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let measuredTempo     = FeatureProvenance(rawValue: 1 << 0)
    static let measuredBeatGrid  = FeatureProvenance(rawValue: 1 << 1)
    static let measuredDownbeats = FeatureProvenance(rawValue: 1 << 2)
    static let measuredKey       = FeatureProvenance(rawValue: 1 << 3)
    static let measuredStructure = FeatureProvenance(rawValue: 1 << 4)
    static let measuredLoudness  = FeatureProvenance(rawValue: 1 << 5)
    static let measuredVocals    = FeatureProvenance(rawValue: 1 << 6)
    static let envelopeOnly      = FeatureProvenance(rawValue: 1 << 7)
    static let metadataOnly      = FeatureProvenance(rawValue: 1 << 8)
    static let measuredBass      = FeatureProvenance(rawValue: 1 << 9)
    static let measuredBeatParity = FeatureProvenance(rawValue: 1 << 10)
    static let measuredStems     = FeatureProvenance(rawValue: 1 << 11)
    static let guessedBarPhase   = FeatureProvenance(rawValue: 1 << 12)

    var caveats: [String] {
        var out: [String] = []
        if !contains(.measuredTempo) { out.append("tempo is estimated, not measured") }
        if !contains(.measuredDownbeats) { out.append("downbeat parity unknown") }
        if !contains(.measuredKey) { out.append("key is estimated, not measured") }
        if !contains(.measuredStructure) { out.append("structure inferred from the waveform envelope") }
        return out
    }
}

enum SectionKind: String, Codable, Sendable, CaseIterable {
    case ambientIntro, intro, buildup, drop, breakdown, bridge, cooldown, outro, ambientOutro
    case build
    case unknown

    var displayName: String {
        switch self {
        case .ambientIntro: return "ambient intro"
        case .intro:        return "intro"
        case .buildup:      return "buildup"
        case .drop:         return "drop"
        case .breakdown:    return "breakdown"
        case .bridge:       return "bridge"
        case .cooldown:     return "cooldown"
        case .outro:        return "outro"
        case .ambientOutro: return "ambient outro"
        case .build:        return "energy build"
        case .unknown:      return "unlabelled section"
        }
    }
}

struct TrackSection: Equatable, Sendable, Codable {
    let kind: SectionKind
    let start: TimeInterval
    let end: TimeInterval
}

struct CamelotKey: Codable, Hashable, Sendable {
    let wheelPosition: Int
    let mode: CamelotMode

    enum CamelotMode: Int, Codable, Sendable {
        case minor = 0
        case major = 1
    }

    init(wheelPosition: Int, mode: CamelotMode) {
        self.wheelPosition = ((wheelPosition - 1) % 12 + 12) % 12 + 1
        self.mode = mode
    }

    init(pitchClass: Int, isMinor: Bool) {
        let pc = ((pitchClass % 12) + 12) % 12
        let majorPitchClass = isMinor ? (pc + 3) % 12 : pc
        self.init(
            wheelPosition: Self.majorPositionByPitchClass[majorPitchClass],
            mode: isMinor ? .minor : .major
        )
    }

    private static let majorPositionByPitchClass = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]

    var harmonicallyCompatible: [CamelotKey] {
        [
            self,
            CamelotKey(wheelPosition: wheelPosition - 1, mode: mode),
            CamelotKey(wheelPosition: wheelPosition + 1, mode: mode),
            CamelotKey(wheelPosition: wheelPosition, mode: mode == .major ? .minor : .major),
        ]
    }

    var label: String { "\(wheelPosition)\(mode == .major ? "B" : "A")" }

    var isMinor: Bool { mode == .minor }

    func wheelSteps(to other: CamelotKey) -> Int {
        let d = abs(wheelPosition - other.wheelPosition) % 12
        return min(d, 12 - d)
    }

    static func parse(_ raw: String) -> CamelotKey? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        if let last = s.last, last == "A" || last == "B" || last == "a" || last == "b",
           let n = Int(s.dropLast()), (1...12).contains(n) {
            return CamelotKey(wheelPosition: n, mode: (last == "A" || last == "a") ? .minor : .major)
        }

        var body = s
        var minor = false
        if body.hasSuffix("m") || body.hasSuffix("min") {
            minor = true
            body = String(body.dropLast(body.hasSuffix("min") ? 3 : 1))
        } else if body.lowercased().hasSuffix("maj") {
            body = String(body.dropLast(3))
        }
        body = body.trimmingCharacters(in: .whitespaces)

        let semitone: [String: Int] = [
            "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5,
            "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11
        ]
        guard let pitch = semitone[body] else { return nil }
        return CamelotKey(pitchClass: pitch, isMinor: minor)
    }
}

struct KeyRegion: Equatable, Sendable, Codable {
    let key: CamelotKey
    let start: TimeInterval
    let end: TimeInterval
}

struct TrackFeatures: Equatable, Sendable {
    let trackId: String
    let title: String
    let artist: String
    let duration: TimeInterval

    let beatGrid: BeatGrid?
    let swingRatio: Double?

    let keyRegions: [KeyRegion]

    let sections: [TrackSection]
    let phraseBoundaries: [TimeInterval]

    let energyLevel: Int?
    let envelope: [Float]

    let genre: GenreResolution?
    let vocalRanges: [ClosedRange<TimeInterval>]
    let bassRanges: [ClosedRange<TimeInterval>]

    let preferredEntrySeconds: TimeInterval?
    let preferredExitSeconds: TimeInterval?

    let provenance: FeatureProvenance

    let cueHints: [CueHint]
    let extensionLoop: ClosedRange<TimeInterval>?
    let heat: [TimeInterval]
    let boundaries: [TimeInterval]
    let barProfile: BarProfile?
    let barStarts: [TimeInterval]

    var contentStart: TimeInterval = 0
    var earliestExitSeconds: TimeInterval = 0
    var contentFloor: Double = 0
    var latestMixStart: TimeInterval?
    var fileDuration: TimeInterval?
    var intro: DJIntro?
    var timbre: TimbreEmbedding?
    var loopRanges: [ClosedRange<TimeInterval>] = []
    var arrangement: TrackArrangement?

    init(
        trackId: String,
        title: String = "",
        artist: String = "",
        duration: TimeInterval,
        beatGrid: BeatGrid? = nil,
        swingRatio: Double? = nil,
        keyRegions: [KeyRegion] = [],
        sections: [TrackSection] = [],
        phraseBoundaries: [TimeInterval] = [],
        energyLevel: Int? = nil,
        envelope: [Float] = [],
        genre: GenreResolution? = nil,
        vocalRanges: [ClosedRange<TimeInterval>] = [],
        bassRanges: [ClosedRange<TimeInterval>] = [],
        preferredEntrySeconds: TimeInterval? = nil,
        preferredExitSeconds: TimeInterval? = nil,
        provenance: FeatureProvenance = [],
        cueHints: [CueHint] = [],
        extensionLoop: ClosedRange<TimeInterval>? = nil,
        heat: [TimeInterval] = [],
        boundaries: [TimeInterval] = [],
        barProfile: BarProfile? = nil,
        barStarts: [TimeInterval] = []
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.duration = duration
        self.beatGrid = beatGrid
        self.swingRatio = swingRatio
        self.keyRegions = keyRegions
        self.sections = sections
        self.phraseBoundaries = phraseBoundaries
        self.energyLevel = energyLevel
        self.envelope = envelope
        self.genre = genre
        self.vocalRanges = vocalRanges
        self.bassRanges = bassRanges
        self.preferredEntrySeconds = preferredEntrySeconds
        self.preferredExitSeconds = preferredExitSeconds
        self.provenance = provenance
        self.cueHints = cueHints
        self.extensionLoop = extensionLoop
        self.heat = heat
        self.boundaries = boundaries
        self.barProfile = barProfile
        self.barStarts = barStarts
    }

    func key(at seconds: TimeInterval) -> CamelotKey? {
        keyRegions.first { seconds >= $0.start && seconds < $0.end }?.key
            ?? keyRegions.first?.key
    }

    func section(at seconds: TimeInterval) -> SectionKind {
        sections.first { seconds >= $0.start && seconds < $0.end }?.kind ?? .unknown
    }

    func beatsFromPhraseBoundary(at seconds: TimeInterval) -> Double {
        guard let grid = beatGrid, grid.beatPeriod > 0 else { return 0 }
        if let nearest = phraseBoundaries.min(by: { abs($0 - seconds) < abs($1 - seconds) }) {
            return (seconds - nearest) / grid.beatPeriod
        }
        return grid.beatsFromPhraseBoundary(at: seconds)
    }

    var displayName: String {
        if title.isEmpty { return trackId }
        return artist.isEmpty ? title : "\(title)"
    }
}

struct ExitPoint: Equatable, Sendable, Codable {
    let seconds: TimeInterval
    let kind: SectionKind
    let barsRemaining: Int?
    let onPhraseBoundary: Bool
    let confidence: Double
}

struct EntryPoint: Equatable, Sendable, Codable {
    let seconds: TimeInterval
    let kind: SectionKind
    let barsUntilNextSection: Int?
    let onPhraseBoundary: Bool
    let hasBassFromHere: Bool
    let confidence: Double
}

struct ExecutorCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let crossfade         = ExecutorCapabilities(rawValue: 1 << 0)
    static let threeBandEQ       = ExecutorCapabilities(rawValue: 1 << 1)
    static let lowPassFilter     = ExecutorCapabilities(rawValue: 1 << 2)
    static let timeStretch       = ExecutorCapabilities(rawValue: 1 << 3)
    static let pitchShift        = ExecutorCapabilities(rawValue: 1 << 4)
    static let loopBuffer        = ExecutorCapabilities(rawValue: 1 << 5)
    static let entryCue          = ExecutorCapabilities(rawValue: 1 << 6)
    static let snappedBassSwap   = ExecutorCapabilities(rawValue: 1 << 7)
    static let highPassFilter    = ExecutorCapabilities(rawValue: 1 << 8)
    static let sampleAccurateCue = ExecutorCapabilities(rawValue: 1 << 9)
    static let loopResize        = ExecutorCapabilities(rawValue: 1 << 10)
    static let delayPerDeck      = ExecutorCapabilities(rawValue: 1 << 11)
    static let masterLimiter     = ExecutorCapabilities(rawValue: 1 << 12)
    static let mixTimeline       = ExecutorCapabilities(rawValue: 1 << 13)

    static let v1MixEngine: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .lowPassFilter, .timeStretch, .pitchShift,
        .loopBuffer, .entryCue, .snappedBassSwap, .sampleAccurateCue
    ]

    static let fullMixEngine: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .lowPassFilter, .highPassFilter,
        .timeStretch, .pitchShift, .loopBuffer, .loopResize, .entryCue,
        .snappedBassSwap, .sampleAccurateCue, .delayPerDeck, .masterLimiter, .mixTimeline
    ]
}

enum StageDeck: String, Equatable, Sendable, Codable {
    case outgoing, incoming
}

enum StageSnap: String, Equatable, Sendable, Codable {
    case beat, bar, phrase
    case free
}

enum StageAction: Equatable, Sendable, Codable {
    case loop(bars: Double)
    case clearLoop
    case lowPassTo(hertz: Double, over: TimeInterval)
    case highPassTo(hertz: Double, over: TimeInterval)
    case eqLow(decibels: Double, over: TimeInterval)
    case delayWet(mix: Double, feedback: Double, over: TimeInterval)
    case crossfadeTo(position: Double, over: TimeInterval)
    case rateRatio(Double, over: TimeInterval)
    case hardCut(fadeSeconds: TimeInterval)
    case echoCut(feedback: Double, release: TimeInterval)

    var requiredCapabilities: ExecutorCapabilities {
        switch self {
        case .loop:          return [.loopBuffer, .loopResize, .sampleAccurateCue]
        case .clearLoop:     return [.loopBuffer]
        case .lowPassTo:     return [.lowPassFilter]
        case .highPassTo:    return [.highPassFilter]
        case .eqLow:         return [.threeBandEQ]
        case .delayWet:      return [.delayPerDeck]
        case .crossfadeTo:   return [.crossfade]
        case .rateRatio:     return [.timeStretch]
        case .hardCut:       return [.crossfade]
        case .echoCut:       return [.delayPerDeck, .crossfade]
        }
    }

    var summary: String {
        switch self {
        case .loop(let bars):
            return bars == bars.rounded()
                ? "\(Int(bars))-bar loop"
                : String(format: "%.1f-bar loop", bars)
        case .clearLoop:                  return "release the loop"
        case .lowPassTo(let hz, _):       return "low-pass to \(Int(hz)) Hz"
        case .highPassTo(let hz, _):      return "high-pass to \(Int(hz)) Hz"
        case .eqLow(let db, _):           return db <= -40 ? "lows out" : "lows in"
        case .delayWet(let mix, _, _):    return "delay \(Int(mix * 100))% wet"
        case .crossfadeTo(let p, _):      return "fader to \(Int(p * 100))%"
        case .rateRatio(let r, _):        return String(format: "rate ×%.3f", r)
        case .hardCut:                    return "cut"
        case .echoCut:                    return "echo out"
        }
    }

    var durationSeconds: TimeInterval? {
        switch self {
        case .loop, .clearLoop:
            return nil
        case .lowPassTo(_, let duration),
             .highPassTo(_, let duration),
             .eqLow(_, let duration),
             .crossfadeTo(_, let duration),
             .rateRatio(_, let duration):
            return max(0, duration)
        case .delayWet(_, _, let duration):
            return max(0, duration)
        case .hardCut(let fadeSeconds):
            return max(0, fadeSeconds)
        case .echoCut(_, let release):
            return max(0, release)
        }
    }
}

struct TransitionStage: Equatable, Sendable, Codable {
    let atSeconds: TimeInterval
    let deck: StageDeck
    let action: StageAction
    let snap: StageSnap

    init(at atSeconds: TimeInterval, on deck: StageDeck, _ action: StageAction, snap: StageSnap = .bar) {
        self.atSeconds = atSeconds
        self.deck = deck
        self.action = action
        self.snap = snap
    }
}

enum TransitionAccent: Equatable, Sendable, Codable {
    case outgoingFilterClose
    case incomingFilterOpen
}

struct DJTransitionPlan: Equatable, Sendable {
    let templateId: TransitionTemplateID
    let profileId: DJProfileID

    let outgoingTrackId: String
    let incomingTrackId: String

    let exit: ExitPoint
    let entry: EntryPoint

    let overlapSeconds: TimeInterval

    let bassSwapAtSeconds: TimeInterval
    let bassSwapSeconds: TimeInterval

    let incomingRateRatio: Double
    let tempoFactor: Double
    let tempoLabel: String

    let accent: TransitionAccent?

    let stages: [TransitionStage]

    let profileMinimumScore: Double

    let move: MixMove?

    init(
        templateId: TransitionTemplateID,
        profileId: DJProfileID,
        outgoingTrackId: String,
        incomingTrackId: String,
        exit: ExitPoint,
        entry: EntryPoint,
        overlapSeconds: TimeInterval,
        bassSwapAtSeconds: TimeInterval,
        bassSwapSeconds: TimeInterval,
        incomingRateRatio: Double,
        tempoFactor: Double,
        tempoLabel: String,
        accent: TransitionAccent?,
        stages: [TransitionStage] = [],
        profileMinimumScore: Double,
        move: MixMove? = nil
    ) {
        self.templateId = templateId
        self.profileId = profileId
        self.outgoingTrackId = outgoingTrackId
        self.incomingTrackId = incomingTrackId
        self.exit = exit
        self.entry = entry
        self.overlapSeconds = overlapSeconds
        self.bassSwapAtSeconds = bassSwapAtSeconds
        self.bassSwapSeconds = bassSwapSeconds
        self.incomingRateRatio = incomingRateRatio
        self.tempoFactor = tempoFactor
        self.tempoLabel = tempoLabel
        self.accent = accent
        self.stages = stages
        self.profileMinimumScore = profileMinimumScore
        self.move = move
    }

    var mixEndSeconds: TimeInterval { exit.seconds + overlapSeconds }

    var stageCapabilities: ExecutorCapabilities {
        stages.reduce(into: ExecutorCapabilities()) { $0.formUnion($1.action.requiredCapabilities) }
    }

    var stageSummary: String? {
        guard !stages.isEmpty else { return nil }
        var loops: [String] = []
        var others: [String] = []
        for stage in stages.sorted(by: { $0.atSeconds < $1.atSeconds }) {
            if case .loop(let bars) = stage.action {
                loops.append(bars == bars.rounded() ? "\(Int(bars))" : String(format: "%.1f", bars))
            } else if case .clearLoop = stage.action {
                continue
            } else {
                let text = stage.action.summary
                if !others.contains(text) { others.append(text) }
            }
        }
        var parts: [String] = []
        if !loops.isEmpty { parts.append(loops.joined(separator: " → ") + "-bar loop") }
        parts.append(contentsOf: others)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    func clampingOverlap(toAtMost maxSeconds: TimeInterval) -> DJTransitionPlan {
        guard move == nil, maxSeconds > 0, overlapSeconds > maxSeconds else { return self }
        let ratio = maxSeconds / overlapSeconds
        return DJTransitionPlan(
            templateId: templateId,
            profileId: profileId,
            outgoingTrackId: outgoingTrackId,
            incomingTrackId: incomingTrackId,
            exit: exit,
            entry: entry,
            overlapSeconds: maxSeconds,
            bassSwapAtSeconds: min(bassSwapAtSeconds * ratio, max(0, maxSeconds - 0.05)),
            bassSwapSeconds: max(0.05, bassSwapSeconds * ratio),
            incomingRateRatio: incomingRateRatio,
            tempoFactor: tempoFactor,
            tempoLabel: tempoLabel,
            accent: accent,
            stages: stages.map { stage in
                TransitionStage(at: min(stage.atSeconds * ratio, maxSeconds), on: stage.deck, stage.action, snap: stage.snap)
            },
            profileMinimumScore: profileMinimumScore
        )
    }
}

struct ScoringTermID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

extension ScoringTermID {
    static let tempo: ScoringTermID = "tempo"
    static let phrase: ScoringTermID = "phrase"
    static let structure: ScoringTermID = "structure"
    static let harmonic: ScoringTermID = "harmonic"
    static let energy: ScoringTermID = "energy"
    static let spectralClash: ScoringTermID = "spectralClash"
    static let genre: ScoringTermID = "genre"
    static let groove: ScoringTermID = "groove"
    static let novelty: ScoringTermID = "novelty"
    static let feasibility: ScoringTermID = "feasibility"
}

struct TermResult: Sendable, Equatable {
    let cost: Double
    let confidence: Double
    let veto: Bool
    let explanation: String?

    init(cost: Double, confidence: Double, veto: Bool = false, explanation: String? = nil) {
        self.cost = min(1, max(0, cost))
        self.confidence = min(1, max(0, confidence))
        self.veto = veto
        self.explanation = explanation
    }

    static func unmeasured(_ note: String? = nil) -> TermResult {
        TermResult(cost: 0.5, confidence: 0, veto: false, explanation: note)
    }
}

struct ScoringContext: Sendable {
    let outgoing: TrackFeatures
    let incoming: TrackFeatures
    let plan: DJTransitionPlan
    let profile: DJProfile
    let history: SetHistory
}

protocol ScoringTerm: Sendable {
    var id: ScoringTermID { get }
    func evaluate(_ ctx: ScoringContext) -> TermResult
}

struct SetHistory: Sendable, Equatable {
    let recentTemplates: [TransitionTemplateID]
    let recentArtists: [String]
    let recentTrackIds: [String]
    let energyTrace: [Int]
    let arc: SetArc
    let recentMoves: [MixMove.Kind]
    let loopsThisHour: Int
    let energyTarget: Int?
    var learned: DJLearnedPriors = .neutral
    var style: AutoMixStyle = .standard
    var transitionNet: AutoMixNetModel?
    var setPriors: LearnedSetPriors?
    var intent: SetIntent?
    var setMinute: Double = 0

    init(
        recentTemplates: [TransitionTemplateID] = [],
        recentArtists: [String] = [],
        recentTrackIds: [String] = [],
        energyTrace: [Int] = [],
        arc: SetArc = .rising,
        recentMoves: [MixMove.Kind] = [],
        loopsThisHour: Int = 0,
        energyTarget: Int? = nil
    ) {
        self.recentTemplates = recentTemplates
        self.recentArtists = recentArtists
        self.recentTrackIds = recentTrackIds
        self.energyTrace = energyTrace
        self.arc = arc
        self.recentMoves = recentMoves
        self.loopsThisHour = loopsThisHour
        self.energyTarget = energyTarget
    }

    static let empty = SetHistory()
}

struct TransitionTemplateID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

enum TemplateAdmission: Equatable, Sendable {
    case admitted
    case rejected(reason: String)

    var isAdmitted: Bool { if case .admitted = self { return true }; return false }
    var reason: String? { if case .rejected(let r) = self { return r }; return nil }
}

protocol TransitionTemplate: Sendable {
    var id: TransitionTemplateID { get }
    var displayName: String { get }
    var requiredCapabilities: ExecutorCapabilities { get }
    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission
    func propose(
        outgoing: TrackFeatures,
        incoming: TrackFeatures,
        exits: [ExitPoint],
        entries: [EntryPoint],
        profile: DJProfile,
        rng: inout SeededGenerator
    ) -> [DJTransitionPlan]
}

struct TransitionRegistry: Sendable {
    private(set) var templates: [TransitionTemplateID: any TransitionTemplate] = [:]

    init() {}
    init(_ templates: [any TransitionTemplate]) {
        for t in templates { self.templates[t.id] = t }
    }

    mutating func register(_ t: any TransitionTemplate) { templates[t.id] = t }

    func admissible(for profile: DJProfile, capabilities: ExecutorCapabilities) -> [any TransitionTemplate] {
        profile.admissibleTemplates
            .compactMap { templates[$0] }
            .filter { capabilities.isSuperset(of: $0.requiredCapabilities) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

struct ScoringRegistry: Sendable {
    private(set) var terms: [ScoringTermID: any ScoringTerm] = [:]

    init() {}
    init(_ terms: [any ScoringTerm]) {
        for t in terms { self.terms[t.id] = t }
    }

    mutating func register(_ t: any ScoringTerm) { terms[t.id] = t }

    var ordered: [any ScoringTerm] { terms.values.sorted { $0.id.rawValue < $1.id.rawValue } }
}

struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    init(_ components: [String]) {
        var h: UInt64 = 0xcbf29ce484222325
        for c in components {
            for b in c.utf8 {
                h = (h ^ UInt64(b)) &* 0x100000001b3
            }
            h = (h ^ 0x2f) &* 0x100000001b3
        }
        self.init(seed: h)
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct PlanRationale: Sendable, Equatable {
    struct Contribution: Sendable, Equatable {
        let termId: ScoringTermID
        let explanation: String
        let weightedCost: Double
    }

    let templateName: String
    let headline: String
    let contributions: [Contribution]
    let concerns: [Contribution]
    let provenanceCaveats: [String]
    let score: Double
    let evidenceCoverage: Double
    let fires: Bool

    var reasoning: String {
        var parts: [String] = [headline]
        for c in concerns.prefix(3) { parts.append(c.explanation) }
        for c in contributions.prefix(2) { parts.append(c.explanation) }
        var text = parts.joined(separator: ". ")
        if !text.hasSuffix(".") { text += "." }
        if !provenanceCaveats.isEmpty {
            text += " " + provenanceCaveats.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "; ") + "."
        }
        return text
    }
}

struct ScoredPlan: Sendable, Equatable {
    let plan: DJTransitionPlan
    let score: Double
    let rationale: PlanRationale
    var fires: Bool { score >= plan.profileMinimumScore }
}

struct PlanRejection: Sendable, Equatable {
    let incomingTrackId: String
    let templateId: TransitionTemplateID?
    let reason: String
}

struct PlanningResult: Sendable, Equatable {
    let ranked: [ScoredPlan]
    let rejections: [PlanRejection]

    var best: ScoredPlan? { ranked.first }
    var firing: ScoredPlan? { ranked.first.flatMap { $0.fires ? $0 : nil } }
}

struct DJProfile: Sendable, Equatable, Codable, Identifiable {
    let id: DJProfileID
    let displayName: String
    let blurb: String

    let exitRegionFloor: Double
    let allowMidTrackExit: Bool
    let entryRegionCeiling: Double
    let minimumPlayFraction: Double

    let admissibleTemplates: Set<TransitionTemplateID>
    let repeatTemplateCooldown: Int

    let maxAbsRatePercent: Double
    let allowVarispeed: Bool
    let requireMeasuredBPMForRate: Bool
    let maxDriftMs: Double
    let minGridConfidence: Double

    let maxCamelotSteps: Int
    let allowEnergyBoost: Bool
    let genreCeiling: Double

    let mayReorderQueue: Bool
    let lookaheadCandidates: Int
    let analysisBudgetPerTrack: Int

    let maxLoopBars: Int
    let maxLoopHalvings: Int

    let weights: [ScoringTermID: Double]
    let minimumScoreToFire: Double
    let transitionBarsRange: ClosedRange<Int>
    let energyStepLimit: Int
    let timbreTargetDistance: Double

    let honoursUserTransitionLength: Bool
    var blendTargetBars: Int?
}

enum DJFormat {
    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bpm(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func percent(_ v: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", v)
    }

    static func signedPercent(_ v: Double, decimals: Int = 1) -> String {
        (v >= 0 ? "+" : "") + String(format: "%.\(decimals)f%%", v)
    }
}

extension DJEngineConstants {
    static let minimumPlannableDuration: TimeInterval = 25
    static let minimumTransitionSeconds: TimeInterval = 3
    static let maximumTransitionSeconds: TimeInterval = 64
    static let tempoOnlyGridConfidence: Double = 0.3
    static let accentClosedFilterHz: Double = 320
    static let bucketSeconds: TimeInterval = 1.0
}
