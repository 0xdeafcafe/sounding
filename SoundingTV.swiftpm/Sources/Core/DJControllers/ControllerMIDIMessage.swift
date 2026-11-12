import Foundation

struct ControllerMIDIMessage: Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case noteOn = "noteOn"
        case noteOff = "noteOff"
        case controlChange = "cc"
        case pitchBend = "pitchBend"
    }

    var kind: Kind
    var channel: UInt8
    var number: UInt8
    var value: UInt16

    var status: UInt8 {
        switch kind {
        case .noteOff: return 0x80 | channel
        case .noteOn: return 0x90 | channel
        case .controlChange: return 0xB0 | channel
        case .pitchBend: return 0xE0 | channel
        }
    }

    var data1: UInt8 { kind == .pitchBend ? UInt8(value & 0x7F) : number }
    var data2: UInt8 { kind == .pitchBend ? UInt8((value >> 7) & 0x7F) : UInt8(min(value, 127)) }

    var universalPacketWord: UInt32 {
        (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }

    init(kind: Kind, channel: UInt8, number: UInt8, value: UInt16) {
        self.kind = kind
        self.channel = channel & 0x0F
        self.number = number & 0x7F
        self.value = value
    }

    init?(status: UInt8, data1: UInt8, data2: UInt8) {
        let channel = status & 0x0F
        let d1 = data1 & 0x7F
        let d2 = data2 & 0x7F
        switch status & 0xF0 {
        case 0x80: self.init(kind: .noteOff, channel: channel, number: d1, value: UInt16(d2))
        case 0x90: self.init(kind: d2 == 0 ? .noteOff : .noteOn, channel: channel, number: d1, value: UInt16(d2))
        case 0xB0: self.init(kind: .controlChange, channel: channel, number: d1, value: UInt16(d2))
        case 0xE0: self.init(kind: .pitchBend, channel: channel, number: 0, value: UInt16(d1) | (UInt16(d2) << 7))
        default: return nil
        }
    }

    init?(universalPacketWord word: UInt32) {
        guard (word >> 28) & 0xF == 0x2 else { return nil }
        self.init(
            status: UInt8((word >> 16) & 0xFF),
            data1: UInt8((word >> 8) & 0xFF),
            data2: UInt8(word & 0xFF)
        )
    }

    static func parse(universalPacketWords words: [UInt32]) -> [ControllerMIDIMessage] {
        var result: [ControllerMIDIMessage] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let message = ControllerMIDIMessage(universalPacketWord: word) { result.append(message) }
            switch (word >> 28) & 0xF {
            case 0x3, 0x4: index += 2
            case 0x5: index += 4
            default: index += 1
            }
        }
        return result
    }
}
