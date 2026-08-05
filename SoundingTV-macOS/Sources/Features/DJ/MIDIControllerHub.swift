import Foundation
import CoreMIDI
import Combine

enum ControlEvent: Sendable, Equatable {
    case absolute(ControlID, Double)
    case relative(ControlID, Double)
    case button(ControlID, isDown: Bool, velocity: Double)
    case touch(ControlID, isTouching: Bool)
}

struct ControlID: Sendable, Equatable, Hashable {
    enum Surface: String, Sendable, Equatable, Hashable {
        case jog, tempo, lineFader, crossfader, trim
        case eqHigh, eqMid, eqLow, filter
        case play, cue, sync, hotCue, loopIn, loopOut, loopToggle
        case browse, load
    }

    var deck: MixEngine.Deck?
    var surface: Surface
    var index: Int = 0
}

struct MIDIControllerInfo: Identifiable, Sendable, Equatable {
    var id: MIDIUniqueID
    var name: String
    var manufacturer: String
    var model: String
    var hasMapping: Bool
}

@MainActor
final class MIDIControllerHub: ObservableObject {
    static let shared = MIDIControllerHub()

    @Published private(set) var controllers: [MIDIControllerInfo] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    let rawMessages = PassthroughSubject<MIDIRawMessage, Never>()

    let events = PassthroughSubject<ControlEvent, Never>()

    private nonisolated(unsafe) var client = MIDIClientRef()
    private nonisolated(unsafe) var inputPort = MIDIPortRef()

    private let mappingResolver = DDJ400MappingResolver()

    private init() {}

    deinit {
        disposeMIDIResources()
    }

    private nonisolated func disposeMIDIResources() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func start() {
        guard !isRunning else { return }

        let status = MIDIClientCreateWithBlock("SoundingCloud" as CFString, &client) { [weak self] notification in
            let messageID = notification.pointee.messageID
            guard messageID == .msgSetupChanged || messageID == .msgObjectAdded || messageID == .msgObjectRemoved else { return }
            Task { @MainActor [weak self] in
                self?.rescanSources()
            }
        }

        guard status == noErr else {
            lastError = "Could not open a MIDI client (OSStatus \(status))."
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "SoundingCloud Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            let parsed = MIDIRawMessage.parse(eventList)
            guard !parsed.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.ingest(parsed)
            }
        }

        guard portStatus == noErr else {
            lastError = "Could not open a MIDI input port (OSStatus \(portStatus))."
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }

        isRunning = true
        lastError = nil
        rescanSources()
    }

    func stop() {
        guard isRunning else { return }
        disposeMIDIResources()
        client = MIDIClientRef()
        inputPort = MIDIPortRef()
        controllers = []
        isRunning = false
    }

    private func rescanSources() {
        guard isRunning else { return }

        var found: [MIDIControllerInfo] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }

            let name = Self.stringProperty(source, kMIDIPropertyDisplayName)
                ?? Self.stringProperty(source, kMIDIPropertyName)
                ?? "Unknown MIDI device"
            let manufacturer = Self.stringProperty(source, kMIDIPropertyManufacturer) ?? ""
            let model = Self.stringProperty(source, kMIDIPropertyModel) ?? ""

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)

            MIDIPortConnectSource(inputPort, source, nil)

            found.append(
                MIDIControllerInfo(
                    id: uniqueID,
                    name: name,
                    manufacturer: manufacturer,
                    model: model,
                    hasMapping: MappingLibrary.hasMapping(manufacturer: manufacturer, model: model, name: name)
                )
            )
        }

        controllers = found
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private func ingest(_ messages: [MIDIRawMessage]) {
        for message in messages {
            rawMessages.send(message)
            if let event = mappingResolver.resolve(message) {
                events.send(event)
            }
        }
    }
}

struct MIDIRawMessage: Sendable, Equatable, Hashable {
    enum Kind: Sendable, Equatable, Hashable {
        case noteOn, noteOff, controlChange, pitchBend
    }

    var kind: Kind
    var channel: UInt8
    var number: UInt8
    var value: UInt16

    static func parse(_ eventList: UnsafePointer<MIDIEventList>) -> [MIDIRawMessage] {
        var result: [MIDIRawMessage] = []
        var packet = eventList.pointee.packet

        for _ in 0..<eventList.pointee.numPackets {
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < Int(packet.wordCount) && index < words.count {
                    let word = words[index]
                    let messageType = UInt8((word >> 28) & 0xF)

                    guard messageType == 0x2 else {
                        index += 1
                        continue
                    }

                    let status = UInt8((word >> 20) & 0xF)
                    let channel = UInt8((word >> 16) & 0xF)
                    let data1 = UInt8((word >> 8) & 0x7F)
                    let data2 = UInt8(word & 0x7F)

                    switch status {
                    case 0x8:
                        result.append(.init(kind: .noteOff, channel: channel, number: data1, value: UInt16(data2)))
                    case 0x9:
                        result.append(.init(
                            kind: data2 == 0 ? .noteOff : .noteOn,
                            channel: channel, number: data1, value: UInt16(data2)
                        ))
                    case 0xB:
                        result.append(.init(kind: .controlChange, channel: channel, number: data1, value: UInt16(data2)))
                    case 0xE:
                        let bend = UInt16(data1) | (UInt16(data2) << 7)
                        result.append(.init(kind: .pitchBend, channel: channel, number: 0, value: bend))
                    default:
                        break
                    }
                    index += 1
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }

        return result
    }
}

enum MappingLibrary {
    static func hasMapping(manufacturer: String, model: String, name: String) -> Bool {
        let haystack = [manufacturer, model, name].joined(separator: " ").lowercased()
        return haystack.contains("ddj-400") || haystack.contains("ddj400")
    }
}

final class DDJ400MappingResolver {
    private struct PairEntry {
        let msb: UInt8
        let lsb: UInt8
        let id: ControlID
    }

    private struct PairTable {
        var byMSB: [UInt8: (lsb: UInt8, id: ControlID)] = [:]
        var byLSB: [UInt8: (msb: UInt8, id: ControlID)] = [:]
    }

    private var latestMSB: [ControlID: UInt8] = [:]
    private var latestLSB: [ControlID: UInt8] = [:]

    private let tables: [UInt8: PairTable]

    private static let masterChannel: UInt8 = 6
    private static let deckAHotCueChannel: UInt8 = 7
    private static let deckBHotCueChannel: UInt8 = 9

    init() {
        var built: [UInt8: PairTable] = [:]
        built[0] = Self.buildTable(Self.perDeckPairs(.a))
        built[1] = Self.buildTable(Self.perDeckPairs(.b))
        built[Self.masterChannel] = Self.buildTable(Self.masterPairs)
        tables = built
    }

    private static func buildTable(_ entries: [PairEntry]) -> PairTable {
        var table = PairTable()
        for entry in entries {
            table.byMSB[entry.msb] = (entry.lsb, entry.id)
            table.byLSB[entry.lsb] = (entry.msb, entry.id)
        }
        return table
    }

    private static func perDeckPairs(_ deck: MixEngine.Deck) -> [PairEntry] {
        [
            PairEntry(msb: 0x00, lsb: 0x20, id: ControlID(deck: deck, surface: .tempo)),
            PairEntry(msb: 0x13, lsb: 0x33, id: ControlID(deck: deck, surface: .lineFader)),
            PairEntry(msb: 0x04, lsb: 0x24, id: ControlID(deck: deck, surface: .trim)),
            PairEntry(msb: 0x07, lsb: 0x27, id: ControlID(deck: deck, surface: .eqHigh)),
            PairEntry(msb: 0x0B, lsb: 0x2B, id: ControlID(deck: deck, surface: .eqMid)),
            PairEntry(msb: 0x0F, lsb: 0x2F, id: ControlID(deck: deck, surface: .eqLow)),
        ]
    }

    private static let masterPairs: [PairEntry] = [
        PairEntry(msb: 0x1F, lsb: 0x3F, id: ControlID(deck: nil, surface: .crossfader)),
        PairEntry(msb: 0x17, lsb: 0x37, id: ControlID(deck: .a, surface: .filter)),
        PairEntry(msb: 0x18, lsb: 0x38, id: ControlID(deck: .b, surface: .filter)),
    ]

    private static func deck(forChannel channel: UInt8) -> MixEngine.Deck? {
        switch channel {
        case 0: return .a
        case 1: return .b
        default: return nil
        }
    }

    func resolve(_ message: MIDIRawMessage) -> ControlEvent? {
        switch message.kind {
        case .controlChange: return resolveCC(message)
        case .noteOn, .noteOff: return resolveNote(message)
        case .pitchBend: return nil
        }
    }

    private func resolveCC(_ message: MIDIRawMessage) -> ControlEvent? {
        if let deck = Self.deck(forChannel: message.channel), [0x21, 0x22, 0x23].contains(message.number) {
            let delta = Double(message.value) - 64
            guard delta != 0 else { return nil }
            return .relative(ControlID(deck: deck, surface: .jog), delta)
        }

        guard let table = tables[message.channel] else { return nil }

        if let entry = table.byMSB[message.number] {
            latestMSB[entry.id] = message.value > 127 ? 127 : UInt8(message.value)
            return emit(entry.id)
        }
        if let entry = table.byLSB[message.number] {
            latestLSB[entry.id] = message.value > 127 ? 127 : UInt8(message.value)
            return emit(entry.id)
        }
        return nil
    }

    private func emit(_ id: ControlID) -> ControlEvent {
        let msb = UInt16(latestMSB[id] ?? 0)
        let lsb = UInt16(latestLSB[id] ?? 0)
        let combined = (msb << 7) | (lsb & 0x7F)
        return .absolute(id, Double(combined) / 16383.0)
    }

    private func resolveNote(_ message: MIDIRawMessage) -> ControlEvent? {
        let isDown = message.kind == .noteOn
        let velocity = Double(message.value) / 127.0

        if message.channel == Self.deckAHotCueChannel, message.number <= 7 {
            return .button(ControlID(deck: .a, surface: .hotCue, index: Int(message.number)), isDown: isDown, velocity: velocity)
        }
        if message.channel == Self.deckBHotCueChannel, message.number <= 7 {
            return .button(ControlID(deck: .b, surface: .hotCue, index: Int(message.number)), isDown: isDown, velocity: velocity)
        }

        guard let deck = Self.deck(forChannel: message.channel) else { return nil }
        switch message.number {
        case 0x0B: return .button(ControlID(deck: deck, surface: .play), isDown: isDown, velocity: velocity)
        case 0x0C: return .button(ControlID(deck: deck, surface: .cue), isDown: isDown, velocity: velocity)
        case 0x10: return .button(ControlID(deck: deck, surface: .loopIn), isDown: isDown, velocity: velocity)
        case 0x11: return .button(ControlID(deck: deck, surface: .loopOut), isDown: isDown, velocity: velocity)
        case 0x4D: return .button(ControlID(deck: deck, surface: .loopToggle), isDown: isDown, velocity: velocity)
        case 0x36: return .touch(ControlID(deck: deck, surface: .jog), isTouching: isDown)
        default: return nil
        }
    }
}
