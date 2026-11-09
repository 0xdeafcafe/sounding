import Foundation

struct ControllerMapping: Hashable, Sendable {
    enum MessageType: Hashable, Sendable {
        case note
        case cc
        case pitchBend
    }

    enum Encoding: Hashable, Sendable {
        case offset64
        case twosComplement
    }

    struct Entry: Hashable, Sendable {
        var midi: MessageType
        var channel: UInt8
        var number: UInt8
        var lsb: UInt8?
        var address: DeckControlAddress
        var encoding: Encoding = .offset64
        var invert = false

        static func note(_ channel: UInt8, _ number: UInt8, _ group: DeckGroup, _ control: DeckControl, index: Int = 0) -> Entry {
            Entry(midi: .note, channel: channel, number: number, address: DeckControlAddress(group: group, control: control, index: index))
        }

        static func cc(_ channel: UInt8, _ number: UInt8, _ group: DeckGroup, _ control: DeckControl, encoding: Encoding = .offset64, invert: Bool = false) -> Entry {
            Entry(midi: .cc, channel: channel, number: number, address: DeckControlAddress(group: group, control: control), encoding: encoding, invert: invert)
        }

        static func cc14(_ channel: UInt8, msb: UInt8, lsb: UInt8, _ group: DeckGroup, _ control: DeckControl, invert: Bool = false) -> Entry {
            Entry(midi: .cc, channel: channel, number: msb, lsb: lsb, address: DeckControlAddress(group: group, control: control), invert: invert)
        }
    }

    var entries: [Entry]

    var problems: [String] {
        var found: [String] = []
        var seen: Set<String> = []
        for (position, entry) in entries.enumerated() {
            let label = "entry \(position + 1)"
            if entry.channel > 15 { found.append("\(label): channel") }
            if entry.number > 127 || (entry.lsb ?? 0) > 127 { found.append("\(label): number") }
            if !entry.address.isValid { found.append("\(label): target") }
            if entry.lsb != nil, entry.midi != .cc || entry.address.control.kind != .continuous {
                found.append("\(label): 14-bit pairs need a continuous CC")
            }
            for number in [entry.number] + (entry.lsb.map { [$0] } ?? []) {
                let key = "\(entry.midi)-\(entry.channel)-\(entry.midi == .pitchBend ? 0 : number)"
                if !seen.insert(key).inserted { found.append("\(label): duplicate \(key)") }
            }
        }
        return found
    }
}

final class ControllerMappingResolver {
    private struct Key: Hashable {
        var type: ControllerMapping.MessageType
        var channel: UInt8
        var number: UInt8
    }

    private enum Slot {
        case whole(ControllerMapping.Entry)
        case msb(ControllerMapping.Entry)
        case lsb(ControllerMapping.Entry)
    }

    private var slots: [Key: Slot] = [:]
    private var highBits: [Key: UInt16] = [:]
    private var lowBits: [Key: UInt16] = [:]

    init(_ mapping: ControllerMapping) {
        for entry in mapping.entries {
            let key = Key(type: entry.midi, channel: entry.channel, number: entry.midi == .pitchBend ? 0 : entry.number)
            if let lsb = entry.lsb {
                slots[key] = .msb(entry)
                slots[Key(type: .cc, channel: entry.channel, number: lsb)] = .lsb(entry)
            } else {
                slots[key] = .whole(entry)
            }
        }
    }

    func resolve(_ message: ControllerMIDIMessage) -> DeckControlAction? {
        let type: ControllerMapping.MessageType
        switch message.kind {
        case .noteOn, .noteOff: type = .note
        case .controlChange: type = .cc
        case .pitchBend: type = .pitchBend
        }
        let key = Key(type: type, channel: message.channel, number: type == .pitchBend ? 0 : message.number)
        guard let slot = slots[key] else { return nil }

        switch slot {
        case .whole(let entry):
            let normalized = message.kind == .pitchBend ? Double(message.value) / 16383 : Double(min(message.value, 127)) / 127
            return action(for: entry, message: message, normalized: normalized)
        case .msb(let entry):
            let pair = Key(type: .cc, channel: entry.channel, number: entry.number)
            highBits[pair] = min(message.value, 127)
            return combined(entry, pair: pair, message: message)
        case .lsb(let entry):
            let pair = Key(type: .cc, channel: entry.channel, number: entry.number)
            lowBits[pair] = min(message.value, 127)
            return combined(entry, pair: pair, message: message)
        }
    }

    private func combined(_ entry: ControllerMapping.Entry, pair: Key, message: ControllerMIDIMessage) -> DeckControlAction? {
        let value = ((highBits[pair] ?? 0) << 7) | (lowBits[pair] ?? 0)
        return action(for: entry, message: message, normalized: Double(value) / 16383)
    }

    private func action(for entry: ControllerMapping.Entry, message: ControllerMIDIMessage, normalized: Double) -> DeckControlAction? {
        let address = entry.address
        switch address.control.kind {
        case .continuous:
            return .set(address, entry.invert ? 1 - normalized : normalized)
        case .button:
            let isDown: Bool
            switch message.kind {
            case .noteOn: isDown = true
            case .noteOff: isDown = false
            case .controlChange, .pitchBend: isDown = message.value > 0
            }
            return .press(address, isDown: isDown)
        case .relative:
            let raw = Int(min(message.value, 127))
            let ticks: Int
            switch entry.encoding {
            case .offset64: ticks = raw - 64
            case .twosComplement: ticks = raw >= 64 ? raw - 128 : raw
            }
            guard ticks != 0 else { return nil }
            return .jog(address.group, ticks: Double(entry.invert ? -ticks : ticks))
        }
    }
}
