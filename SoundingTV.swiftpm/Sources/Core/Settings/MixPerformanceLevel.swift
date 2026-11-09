import Foundation

enum MixPerformanceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case subtle
    case lively

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .lively: return "Lively"
        }
    }

    var maximumMoves: Int {
        switch self {
        case .off: return 0
        case .subtle: return 1
        case .lively: return 2
        }
    }

    var trackChance: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.5
        case .lively: return 0.9
        }
    }

    var minimumGapBars: Int {
        switch self {
        case .off, .subtle: return 64
        case .lively: return 32
        }
    }
}
