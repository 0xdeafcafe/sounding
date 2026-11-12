import Foundation

enum AnalysisState: Equatable {
    case pending
    case analyzing
    case analyzed(TrackAnalysis)
    case failed
}

struct TrackAnalysis: Codable, Equatable, Sendable {
    let trackId: String
    let bpm: Double?
    let key: String?
    let energy: Double?
    let intro: TimeInterval
    let outro: TimeInterval
    let isEstimated: Bool

    init(
        trackId: String,
        bpm: Double?,
        key: String?,
        energy: Double?,
        intro: TimeInterval,
        outro: TimeInterval,
        isEstimated: Bool = false
    ) {
        self.trackId = trackId
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.intro = intro
        self.outro = outro
        self.isEstimated = isEstimated
    }

    enum CodingKeys: String, CodingKey {
        case trackId, bpm, key, energy, intro, outro, isEstimated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = try c.decode(String.self, forKey: .trackId)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        energy = try c.decodeIfPresent(Double.self, forKey: .energy)
        intro = try c.decode(TimeInterval.self, forKey: .intro)
        outro = try c.decode(TimeInterval.self, forKey: .outro)
        isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? true
    }
}

struct TransitionStep: Codable, Equatable, Hashable {
    let technique: TransitionTechnique
    let bars: Int
}

struct TransitionPlan: Codable, Equatable {
    let fromTrackId: String
    let toTrackId: String
    let primaryTechnique: TransitionTechnique
    let confidence: Double
    let totalBars: Int
    let steps: [TransitionStep]
}

extension TransitionPlan {
    /// Readout-only projection of the single plan model into the legacy
    /// bars/techniques vocabulary. No planning happens here; the answer is
    /// derived from an already-selected PhantomDJEngine.Plan so the tvOS
    /// readouts show the same transition the director will execute.
    init(projecting plan: PhantomDJEngine.Plan, fromTrackId: String, toTrackId: String) {
        let barSeconds = plan.outgoingBeatGrid?.barDuration ?? 2
        func bars(_ seconds: TimeInterval) -> Int {
            max(0, Int((seconds / max(0.01, barSeconds)).rounded()))
        }

        var steps: [TransitionStep] = plan.stages.compactMap { stage in
            switch stage.action {
            case .loop(let loopBars):
                return TransitionStep(technique: .loopOut, bars: max(1, Int(loopBars)))
            case .clearLoop:
                return nil
            case .lowPassTo(_, let over):
                return TransitionStep(technique: .lowpassSweep, bars: bars(over))
            case .highPassTo(_, let over):
                return TransitionStep(technique: .highpassSweep, bars: bars(over))
            case .eqLow(_, let over):
                return TransitionStep(technique: .bassSwap, bars: bars(over))
            case .delayWet(_, _, let over):
                return TransitionStep(technique: .echoOut, bars: bars(over))
            case .crossfadeTo(_, let over):
                return TransitionStep(technique: .phraseAlign, bars: bars(over))
            case .rateRatio(_, let over):
                return TransitionStep(technique: .beatMatch, bars: bars(over))
            case .hardCut:
                return TransitionStep(technique: .quickCut, bars: 0)
            case .echoCut(_, let release):
                return TransitionStep(technique: .echoOut, bars: bars(release))
            }
        }

        let primary: TransitionTechnique
        switch plan.templateId {
        case DJTemplates.bassSwapBlend:  primary = .bassSwap
        case DJTemplates.filterFadeOut:  primary = .lowpassSweep
        case DJTemplates.filterBloomIn:  primary = .lowpassSweep
        case DJTemplates.highPassThinOut: primary = .highpassSweep
        case DJTemplates.cutOnTheOne:    primary = .quickCut
        case DJTemplates.halfTimeBlend:  primary = .beatMatch
        case DJTemplates.loopRollDown:   primary = .loopOut
        case DJTemplates.echoOut:        primary = .echoOut
        case DJTemplates.tempoRampBlend: primary = .beatMatch
        case DJTemplates.doubleDrop:     primary = .phraseAlign
        default:
            switch plan.accent {
            case .outgoingFilterClose: primary = .lowpassSweep
            case .incomingFilterOpen:  primary = .highpassSweep
            case nil:                  primary = plan.templateId == nil ? .bassSwap : .quickCut
            }
        }

        if steps.isEmpty {
            if let accent = plan.accent {
                steps.append(TransitionStep(
                    technique: accent == .outgoingFilterClose ? .lowpassSweep : .highpassSweep,
                    bars: bars(plan.transitionSeconds)
                ))
            }
            if primary != .quickCut {
                steps.append(TransitionStep(technique: .bassSwap, bars: bars(plan.bassSwapSeconds)))
            }
        }

        self.init(
            fromTrackId: fromTrackId,
            toTrackId: toTrackId,
            primaryTechnique: primary,
            confidence: plan.rationale?.score ?? 0.5,
            totalBars: steps.reduce(0) { $0 + $1.bars },
            steps: steps
        )
    }
}

enum TransitionTechnique: String, Codable {
    case phraseAlign
    case beatMatch
    case bassSwap
    case lowpassSweep
    case highpassSweep
    case loopOut
    case echoOut
    case quickCut

    var icon: String {
        switch self {
        case .phraseAlign:   return "ruler.fill"
        case .beatMatch:     return "metronome.fill"
        case .bassSwap:      return "arrow.left.arrow.right.circle.fill"
        case .lowpassSweep:  return "arrow.down.right.circle.fill"
        case .highpassSweep: return "arrow.up.right.circle.fill"
        case .loopOut:       return "arrow.triangle.2.circlepath"
        case .echoOut:       return "wave.3.right"
        case .quickCut:      return "scissors"
        }
    }

    var label: String {
        switch self {
        case .phraseAlign:   return "Phrase"
        case .beatMatch:     return "Beat Match"
        case .bassSwap:      return "Bass Swap"
        case .lowpassSweep:  return "Lowpass"
        case .highpassSweep: return "Highpass"
        case .loopOut:       return "Loop Out"
        case .echoOut:       return "Echo Out"
        case .quickCut:      return "Cut"
        }
    }
}

@MainActor
protocol DJTransitionServiceDelegate: AnyObject {
    func djTransitionServiceDidChangeEnabled(_ enabled: Bool)
    var queue: [Track] { get }
    var currentIndex: Int { get }
}
