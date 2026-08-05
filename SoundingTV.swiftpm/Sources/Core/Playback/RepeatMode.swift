import Foundation

enum RepeatMode: String, CaseIterable, Codable {
    case off
    case all
    case one

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var isActive: Bool {
        self != .off
    }
}
