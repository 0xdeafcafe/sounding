import Foundation

enum DeckGroup: Hashable, Sendable {
    case deck(MixEngine.Deck)
    case mixer

    init?(name: String) {
        switch name {
        case "deckA": self = .deck(.a)
        case "deckB": self = .deck(.b)
        case "mixer": self = .mixer
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .deck(.a): return "deckA"
        case .deck(.b): return "deckB"
        case .mixer: return "mixer"
        }
    }

    var deck: MixEngine.Deck? {
        if case .deck(let deck) = self { return deck }
        return nil
    }
}

enum DeckControl: String, CaseIterable, Codable, Sendable {
    case play, cue, sync
    case tempo, jog, jogTouch
    case hotCue
    case loopIn, loopOut, loopToggle, loopHalve, loopDouble
    case eqHigh, eqMid, eqLow, filter
    case volume, trim, crossfader
    case echo
    case headphoneCue, fxToggle, fxAmount
    case masterLevel, cueMix, phonesLevel

    enum Kind: Sendable {
        case button
        case continuous
        case relative
    }

    var kind: Kind {
        switch self {
        case .tempo, .eqHigh, .eqMid, .eqLow, .filter, .volume, .trim, .crossfader,
             .fxAmount, .masterLevel, .cueMix, .phonesLevel:
            return .continuous
        case .jog:
            return .relative
        case .play, .cue, .sync, .jogTouch, .hotCue, .loopIn, .loopOut, .loopToggle, .loopHalve, .loopDouble, .echo,
             .headphoneCue, .fxToggle:
            return .button
        }
    }

    var isMixerControl: Bool {
        switch self {
        case .crossfader, .masterLevel, .cueMix, .phonesLevel: return true
        default: return false
        }
    }

    static let hotCueCount = 8
}

struct DeckControlAddress: Hashable, Sendable {
    var group: DeckGroup
    var control: DeckControl
    var index: Int = 0

    var isValid: Bool {
        guard control.isMixerControl == (group == .mixer) else { return false }
        if control == .hotCue { return (0..<DeckControl.hotCueCount).contains(index) }
        return index == 0
    }

    static let observable: [DeckControlAddress] = {
        var result: [DeckControlAddress] = []
        for deck in MixEngine.Deck.allCases {
            for control in DeckControl.allCases where !control.isMixerControl && control != .jog {
                if control == .hotCue {
                    for index in 0..<DeckControl.hotCueCount {
                        result.append(DeckControlAddress(group: .deck(deck), control: control, index: index))
                    }
                } else {
                    result.append(DeckControlAddress(group: .deck(deck), control: control))
                }
            }
        }
        for control in DeckControl.allCases where control.isMixerControl {
            result.append(DeckControlAddress(group: .mixer, control: control))
        }
        return result
    }()
}

enum DeckControlAction: Equatable, Sendable {
    case set(DeckControlAddress, Double)
    case press(DeckControlAddress, isDown: Bool)
    case jog(DeckGroup, ticks: Double)
}

@MainActor
protocol DeckControlSurface: AnyObject {
    func value(of address: DeckControlAddress) -> Double?
    func setValue(_ value: Double, for address: DeckControlAddress)
    func press(_ address: DeckControlAddress, isDown: Bool)
    func jog(_ group: DeckGroup, ticks: Double)
}

extension DeckControlSurface {
    func perform(_ action: DeckControlAction) {
        switch action {
        case .set(let address, let value): setValue(min(max(value, 0), 1), for: address)
        case .press(let address, let isDown): press(address, isDown: isDown)
        case .jog(let group, let ticks): jog(group, ticks: ticks)
        }
    }

    func snapshot() -> [DeckControlAddress: Double] {
        var values: [DeckControlAddress: Double] = [:]
        for address in DeckControlAddress.observable {
            if let value = value(of: address) { values[address] = value }
        }
        return values
    }
}
