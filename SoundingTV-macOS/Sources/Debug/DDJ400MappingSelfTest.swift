import Foundation

#if DEBUG
enum DDJ400MappingSelfTest {
    struct Failure: CustomStringConvertible {
        let name: String
        let detail: String
        var description: String { "\(name): \(detail)" }
    }

    @MainActor
    static func run() -> [Failure] {
        var failures: [Failure] = []
        let resolver = DDJ400MappingResolver()

        func expect(_ name: String, _ message: MIDIRawMessage, _ expected: ControlEvent?) {
            let got = resolver.resolve(message)
            guard got == expected else {
                failures.append(Failure(name: name, detail: "expected \(String(describing: expected)), got \(String(describing: got))"))
                return
            }
        }
        func note(_ status: UInt8, _ number: UInt8, _ velocity: UInt8) -> MIDIRawMessage {
            let channel = status & 0x0F
            let isOn = (status & 0xF0) == 0x90
            return MIDIRawMessage(kind: (isOn && velocity > 0) ? .noteOn : .noteOff, channel: channel, number: number, value: UInt16(velocity))
        }
        func cc(_ status: UInt8, _ number: UInt8, _ value: UInt8) -> MIDIRawMessage {
            MIDIRawMessage(kind: .controlChange, channel: status & 0x0F, number: number, value: UInt16(value))
        }

        expect("deckA play down", note(0x90, 0x0B, 127),
               .button(ControlID(deck: .a, surface: .play), isDown: true, velocity: 1.0))
        expect("deckA play up", note(0x90, 0x0B, 0),
               .button(ControlID(deck: .a, surface: .play), isDown: false, velocity: 0))
        expect("deckB cue down", note(0x91, 0x0C, 127),
               .button(ControlID(deck: .b, surface: .cue), isDown: true, velocity: 1.0))
        expect("deckA loopIn", note(0x90, 0x10, 127),
               .button(ControlID(deck: .a, surface: .loopIn), isDown: true, velocity: 1.0))
        expect("deckB loopToggle", note(0x91, 0x4D, 127),
               .button(ControlID(deck: .b, surface: .loopToggle), isDown: true, velocity: 1.0))
        expect("deckA jog touch on", note(0x90, 0x36, 127),
               .touch(ControlID(deck: .a, surface: .jog), isTouching: true))
        expect("deckA jog touch off", note(0x90, 0x36, 0),
               .touch(ControlID(deck: .a, surface: .jog), isTouching: false))

        expect("deckA hotcue 3 down", note(0x97, 0x02, 100),
               .button(ControlID(deck: .a, surface: .hotCue, index: 2), isDown: true, velocity: 100.0 / 127.0))
        expect("deckB hotcue 1 down", note(0x99, 0x00, 127),
               .button(ControlID(deck: .b, surface: .hotCue, index: 0), isDown: true, velocity: 1.0))
        expect("deckA hotcue clear is unmapped", note(0x98, 0x02, 127), nil)

        expect("deckA jog +6", cc(0xB0, 0x22, 70),
               .relative(ControlID(deck: .a, surface: .jog), 6))
        expect("deckB jog -4", cc(0xB1, 0x23, 60),
               .relative(ControlID(deck: .b, surface: .jog), -4))
        expect("deckA jog centred is silent", cc(0xB0, 0x22, 64), nil)
        expect("deckA jog search unmapped", cc(0xB0, 0x29, 70), nil)

        let crossfaderId = ControlID(deck: nil, surface: .crossfader)
        _ = resolver.resolve(cc(0xB6, 0x1F, 127)) // MSB
        expect("crossfader full scale", cc(0xB6, 0x3F, 127),
               .absolute(crossfaderId, 16383.0 / 16383.0))

        let eqLowB = ControlID(deck: .b, surface: .eqLow)
        _ = resolver.resolve(cc(0xB1, 0x0F, 127))
        expect("deckB EQ low full scale", cc(0xB1, 0x2F, 127), .absolute(eqLowB, 1.0))

        let filterA = ControlID(deck: .a, surface: .filter)
        _ = resolver.resolve(cc(0xB6, 0x17, 0))
        expect("deckA filter zero scale", cc(0xB6, 0x37, 0), .absolute(filterA, 0))

        expect("channel 3 CC is unmapped", cc(0xB3, 0x22, 70), nil)

        return failures
    }
}
#endif
