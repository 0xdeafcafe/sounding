import Foundation

struct MixControl: Hashable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case trim
        case high
        case mid
        case low
        case filter
        case volume
        case tempo
        case echo
        case crossfader
    }

    var kind: Kind
    var deck: MixEngine.Deck?

    init(_ kind: Kind, deck: MixEngine.Deck?) {
        self.kind = kind
        self.deck = kind == .crossfader ? nil : deck
    }

    static let crossfader = MixControl(.crossfader, deck: nil)

    var id: String { "\(kind.rawValue)\(deck?.label ?? "")" }

    var parameters: [MixParameter] {
        guard let deck = deck?.rawValue else { return kind == .crossfader ? [.crossfade] : [] }
        switch kind {
        case .trim: return [.inputGain(deck)]
        case .high: return [.eqHigh(deck)]
        case .mid: return [.eqMid(deck)]
        case .low: return [.eqLow(deck)]
        case .filter: return [.lowPass(deck), .highPass(deck), .resonance(deck)]
        case .volume: return [.gain(deck)]
        case .tempo: return [.rate(deck), .pitch(deck)]
        case .echo: return [.echoSend(deck)]
        case .crossfader: return [.crossfade]
        }
    }

    var name: String {
        let base: String
        switch kind {
        case .trim: base = "Trim"
        case .high: base = "High"
        case .mid: base = "Mid"
        case .low: base = "Low"
        case .filter: base = "Filter"
        case .volume: base = "Fader"
        case .tempo: base = "Tempo"
        case .echo: base = "Echo"
        case .crossfader: return "Crossfader"
        }
        return deck.map { "\(base) \($0.label)" } ?? base
    }

    static func all(on deck: MixEngine.Deck) -> [MixControl] {
        Kind.allCases.filter { $0 != .crossfader }.map { MixControl($0, deck: deck) }
    }

    static var everything: [MixControl] {
        all(on: .a) + all(on: .b) + [.crossfader]
    }
}
