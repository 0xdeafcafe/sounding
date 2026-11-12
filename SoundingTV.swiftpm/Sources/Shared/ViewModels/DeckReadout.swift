import Foundation

struct DeckReadout: Equatable {
    var bpm: Double?
    var key: String?
    var energy: Double?
    var isEstimated = false
    var isAnalyzing = false
    var hasAnalysis = false

    init(_ state: AnalysisState) {
        switch state {
        case .pending, .analyzing:
            isAnalyzing = true
        case .analyzed(let analysis):
            bpm = analysis.bpm
            key = analysis.key
            energy = analysis.isEstimated ? nil : analysis.energy
            isEstimated = analysis.isEstimated && analysis.bpm != nil
            hasAnalysis = bpm != nil || key != nil || energy != nil
        case .failed:
            break
        }
    }

    var bpmText: String? { bpm.map { String(format: "%.0f", $0) } }
    var energyText: String? { energy.map { "\(Int(($0 * 100).rounded()))%" } }

    var spokenSummary: String {
        guard hasAnalysis else { return isAnalyzing ? "analysing" : "no analysis" }
        let about = isEstimated ? "about " : ""
        var parts: [String] = []
        if let bpm { parts.append("\(about)\(Int(bpm.rounded())) BPM") }
        if let key { parts.append("key \(key)") }
        if let energyText { parts.append("energy \(energyText)") }
        return parts.joined(separator: ", ")
    }
}

struct DeckTempoMatch: Equatable {
    let from: Double
    let to: Double
    let isEstimated: Bool

    init?(_ a: DeckReadout, _ b: DeckReadout) {
        guard let from = a.bpm, let to = b.bpm, from > 0 else { return nil }
        self.from = from
        self.to = to
        isEstimated = a.isEstimated || b.isEstimated
    }

    var drift: Double { (to / from - 1) * 100 }
    var isLarge: Bool { abs(drift) > 6 }
    var driftText: String { String(format: "%+.1f%%", drift) }
    var tempoText: String {
        let tilde = isEstimated ? "~" : ""
        return "\(tilde)\(String(format: "%.0f", from)) → \(tilde)\(String(format: "%.0f", to)) BPM"
    }
}

enum DeckMixStatus: Equatable {
    case off
    case planPreview
    case preparingDeck(Double)
    case arming(Double)
    case thinking
    case armed
    case cleanCutArmed
    case liveNoNext
    case cutNext
    case mixingLive
    case cutting

    @MainActor
    static func current(_ player: PlayerService) -> DeckMixStatus {
        if let window = player.mixWindow {
            return window.isLive ? .mixingLive : .cutting
        }
        guard player.isAutoMixEnabled else { return .off }
        switch player.mixEngineState {
        case .off, .unavailable:
            return .planPreview
        case .preparing(let fraction):
            return .preparingDeck(fraction)
        case .live:
            guard player.upcomingTrack != nil else { return .liveNoNext }
            if player.adaptiveMixPlan == nil { return .thinking }
            switch player.incomingDeck {
            case .ready:
                return player.adaptiveMixPlan?.templateId == DJTemplates.cutOnTheOne ? .cleanCutArmed : .armed
            case .loading(let fraction): return .arming(fraction)
            case .failed: return .cutNext
            case .idle: return .arming(0)
            }
        }
    }

    var label: String {
        switch self {
        case .off: return "Auto Mix Off"
        case .planPreview: return "Will Cut"
        case .preparingDeck(let fraction): return "Preparing \(Int((fraction * 100).rounded()))%"
        case .arming(let fraction): return "Loading \(Int((fraction * 100).rounded()))%"
        case .thinking: return "Choosing a Mix"
        case .armed: return "Ready to Mix"
        case .cleanCutArmed: return "Ready to Cut"
        case .liveNoNext: return "Nothing Queued"
        case .cutNext: return "Will Cut"
        case .mixingLive: return "Mixing"
        case .cutting: return "Cutting"
        }
    }

    var note: String {
        switch self {
        case .off: return "Tracks play one after another."
        case .planPreview: return "Tracks will cut straight into each other."
        case .preparingDeck: return "Getting this track ready to mix."
        case .arming: return "Loading the next track."
        case .thinking: return "Choosing a transition."
        case .armed: return "The next track will blend in."
        case .cleanCutArmed: return "The next track will cut in on the beat."
        case .liveNoNext: return "Add tracks to Up Next to keep mixing."
        case .cutNext: return "The next track can\u{2019}t be mixed, so it will cut in."
        case .mixingLive: return "Both decks are playing."
        case .cutting: return "Cutting to the next track."
        }
    }

    var willMix: Bool {
        switch self {
        case .arming, .armed, .cleanCutArmed, .mixingLive: return true
        default: return false
        }
    }

    var isMixing: Bool { self == .mixingLive || self == .cutting }
}
