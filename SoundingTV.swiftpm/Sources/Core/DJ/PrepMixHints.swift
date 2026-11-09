import Foundation

struct CueHint: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case exit
        case entry
    }

    let seconds: TimeInterval
    let role: Role
    let confidence: Double
    var label: String = ""
}

struct PrepMixHints: Equatable, Sendable {
    var hints: [CueHint] = []
    var extensionLoop: ClosedRange<TimeInterval>?
    var grid: BeatGrid?

    static let cueConfidence = 0.9
    static let suggestionWeight = 0.5
    static let trustedGridConfidence = 0.95
    static let entryLabels = ["drop", "break"]

    static func derive(
        cues: [CuePoint],
        suggestions: [CueSuggestion],
        prep: TrackPrep?,
        measuredGrid: BeatGrid?,
        phraseBoundaries: [TimeInterval],
        duration: TimeInterval
    ) -> PrepMixHints {
        var out = PrepMixHints()
        if let prep, prep.hasTrustedGrid,
           let grid = prep.grid?.value.beatGrid(durationSeconds: duration, confidence: trustedGridConfidence) {
            out.grid = grid
        }
        let grid = out.grid ?? measuredGrid

        func onPhrase(_ seconds: TimeInterval) -> Bool {
            guard let grid, grid.beatPeriod > 0 else { return false }
            let tolerance = grid.beatPeriod / 2
            if phraseBoundaries.contains(where: { abs($0 - seconds) <= tolerance }) { return true }
            return abs(grid.beatsFromPhraseBoundary(at: seconds)) * grid.beatPeriod <= tolerance
        }

        func isEntryLabel(_ label: String) -> Bool {
            let lowered = label.lowercased()
            return entryLabels.contains { lowered.contains($0) }
        }

        typealias Item = (kind: CueKind, seconds: TimeInterval, end: TimeInterval?, label: String, hot: Bool, weight: Double)
        let items: [Item] = cues.filter { !$0.isDeleted }.map {
            ($0.kind, $0.positionSeconds, $0.endSeconds, $0.label, $0.hotCueIndex != nil, 1.0)
        } + suggestions.map {
            ($0.kind, $0.positionSeconds, $0.endMillis.map(CueTime.seconds(fromMillis:)), $0.label, false, suggestionWeight)
        }

        for item in items {
            switch item.kind {
            case .memory where onPhrase(item.seconds):
                out.hints.append(CueHint(seconds: item.seconds, role: .exit, confidence: cueConfidence * item.weight))
            case .hotCue where isEntryLabel(item.label):
                out.hints.append(CueHint(seconds: item.seconds, role: .entry, confidence: cueConfidence * item.weight, label: item.label))
            case .loop:
                guard let end = item.end, end > item.seconds, duration > 0, item.seconds >= duration * 2 / 3 else { continue }
                if item.weight >= 1, out.extensionLoop == nil || (out.extensionLoop?.lowerBound ?? 0) < item.seconds {
                    out.extensionLoop = item.seconds...end
                }
                out.hints.append(CueHint(seconds: item.seconds, role: .exit, confidence: cueConfidence * item.weight))
            default:
                continue
            }
        }
        return out
    }
}
