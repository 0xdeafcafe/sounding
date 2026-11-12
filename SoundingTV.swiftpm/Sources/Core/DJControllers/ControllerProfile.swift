import Foundation

struct ControllerDeviceInfo: Hashable, Sendable {
    var name: String
    var manufacturer: String = ""
    var model: String = ""
}

struct ControllerProfile: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var portNames: [String]
    var mapping: ControllerMapping
    var feedback: ControllerFeedbackMapping = .none

    func matches(_ device: ControllerDeviceInfo) -> Bool {
        let candidates = [device.name, device.model, "\(device.manufacturer) \(device.model)"]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return portNames.contains { pattern in
            candidates.contains { Self.glob(pattern, matches: $0) }
        }
    }

    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

enum ControllerProfiles {
    static let all: [ControllerProfile] = [pioneerDDJ400]

    static func profile(for device: ControllerDeviceInfo) -> ControllerProfile? {
        all.first { $0.matches(device) }
    }

    // MARK: Pioneer DJ DDJ-400

    static let pioneerDDJ400: ControllerProfile = {
        let a = DeckGroup.deck(.a)
        let b = DeckGroup.deck(.b)
        var entries: [ControllerMapping.Entry] = []
        for (channel, deck) in [(UInt8(0), a), (UInt8(1), b)] {
            entries += [
                .cc14(channel, msb: 0x00, lsb: 0x20, deck, .tempo),
                .cc14(channel, msb: 0x13, lsb: 0x33, deck, .volume),
                .cc14(channel, msb: 0x04, lsb: 0x24, deck, .trim),
                .cc14(channel, msb: 0x07, lsb: 0x27, deck, .eqHigh),
                .cc14(channel, msb: 0x0B, lsb: 0x2B, deck, .eqMid),
                .cc14(channel, msb: 0x0F, lsb: 0x2F, deck, .eqLow),
                .cc(channel, 0x21, deck, .jog),
                .cc(channel, 0x22, deck, .jog),
                .cc(channel, 0x23, deck, .jog),
                .note(channel, 0x0B, deck, .play),
                .note(channel, 0x0C, deck, .cue),
                .note(channel, 0x58, deck, .sync),
                .note(channel, 0x10, deck, .loopIn),
                .note(channel, 0x11, deck, .loopOut),
                .note(channel, 0x4D, deck, .loopToggle),
                .note(channel, 0x36, deck, .jogTouch),
            ]
        }
        for (channel, deck) in [(UInt8(7), a), (UInt8(9), b)] {
            for pad in 0..<8 {
                entries.append(.note(channel, UInt8(pad), deck, .hotCue, index: pad))
            }
        }
        entries += [
            .cc14(6, msb: 0x1F, lsb: 0x3F, .mixer, .crossfader),
            .cc14(6, msb: 0x17, lsb: 0x37, a, .filter),
            .cc14(6, msb: 0x18, lsb: 0x38, b, .filter),
        ]
        return ControllerProfile(
            id: "pioneer.ddj-400",
            name: "DDJ-400",
            portNames: ["*DDJ-400*", "*DDJ400*"],
            mapping: ControllerMapping(entries: entries),
            feedback: pioneerDDJ400Feedback
        )
    }()

    static let pioneerDDJ400Feedback: ControllerFeedbackMapping = {
        var outputs: [ControllerFeedbackMapping.Output] = []
        for (channel, deck) in [(UInt8(0), MixEngine.Deck.a), (UInt8(1), MixEngine.Deck.b)] {
            outputs += [
                .led(channel, 0x0B, deck, .play),
                .led(channel, 0x0C, deck, .cue),
                .led(channel, 0x58, deck, .sync),
                .led(channel, 0x10, deck, .loop),
                .led(channel, 0x11, deck, .loop),
                .led(channel, 0x4D, deck, .loop),
                .meter(channel, 0x02, deck, .level),
            ]
        }
        for (channel, deck) in [(UInt8(7), MixEngine.Deck.a), (UInt8(9), MixEngine.Deck.b)] {
            for pad in 0..<8 {
                outputs.append(.led(channel, UInt8(pad), deck, .hotCue(pad)))
            }
        }
        return ControllerFeedbackMapping(outputs: outputs)
    }()
}
