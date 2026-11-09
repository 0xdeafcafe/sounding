import Foundation

enum ControllerDeckContent: Hashable, Sendable {
    case empty
    case ownMusic
    case streaming

    init(source: TrackSource?) {
        switch source {
        case nil: self = .empty
        case .local?: self = .ownMusic
        case .soundCloud?: self = .streaming
        }
    }
}

struct ControllerDeckAccess: Sendable {
    var allowsStreaming = false

    func allows(_ content: ControllerDeckContent) -> Bool {
        switch content {
        case .empty, .ownMusic: return true
        case .streaming: return allowsStreaming
        }
    }

    func permits(_ action: DeckControlAction, content: (MixEngine.Deck) -> ControllerDeckContent) -> Bool {
        let group: DeckGroup
        switch action {
        case .set(let address, _): group = address.group
        case .press(let address, _): group = address.group
        case .jog(let target, _): group = target
        }
        switch group {
        case .deck(let deck):
            return allows(content(deck))
        case .mixer:
            return MixEngine.Deck.allCases.allSatisfy { allows(content($0)) }
        }
    }
}
