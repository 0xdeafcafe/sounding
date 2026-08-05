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
    let energy: Double
    let intro: TimeInterval
    let outro: TimeInterval
    let isEstimated: Bool

    init(
        trackId: String,
        bpm: Double?,
        key: String?,
        energy: Double,
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
        energy = try c.decode(Double.self, forKey: .energy)
        intro = try c.decode(TimeInterval.self, forKey: .intro)
        outro = try c.decode(TimeInterval.self, forKey: .outro)
        isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? true
    }
}

struct TransitionKey: Hashable {
    let fromId: String
    let toId: String
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
