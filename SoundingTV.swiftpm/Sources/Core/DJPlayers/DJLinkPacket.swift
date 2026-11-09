#if os(macOS) || DEBUG
import Foundation

enum DJLinkPort {
    static let announce: UInt16 = 50000
    static let beat: UInt16 = 50001
    static let status: UInt16 = 50002
}

struct DJLinkIPv4: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        raw = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        self.init(parts[0], parts[1], parts[2], parts[3])
    }

    var bytes: [UInt8] {
        [UInt8(raw >> 24 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
    }

    var description: String { bytes.map(String.init).joined(separator: ".") }

    var isLinkLocal: Bool { raw >> 16 == 0xA9FE }

    static let loopback = DJLinkIPv4(127, 0, 0, 1)
    static let zero = DJLinkIPv4(raw: 0)
}

struct DJLinkMAC: Hashable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = Array((bytes + [0, 0, 0, 0, 0, 0]).prefix(6))
    }

    var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }

    static let zero = DJLinkMAC([0, 0, 0, 0, 0, 0])
}

struct DJLinkPitch: Hashable, Sendable {
    static let unity: UInt32 = 0x0010_0000

    let raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init(multiplier: Double) {
        let clamped = min(2, max(0, multiplier.isFinite ? multiplier : 1))
        raw = UInt32((clamped * Double(Self.unity)).rounded())
    }

    var multiplier: Double { Double(raw) / Double(Self.unity) }
    var percent: Double { (multiplier - 1) * 100 }
}

enum DJLinkSyncCommand: UInt8, Sendable {
    case becomeMaster = 0x01
    case syncOn = 0x10
    case syncOff = 0x20
}

enum DJLinkPlayState: UInt8, Sendable {
    case noTrack = 0x00
    case loading = 0x02
    case playing = 0x03
    case looping = 0x04
    case paused = 0x05
    case cued = 0x06
    case cuePlay = 0x07
    case cueScratch = 0x08
    case searching = 0x09
    case spunDown = 0x0e
    case ended = 0x11
    case emergencyLoop = 0x12
}

struct DJLinkStatusFlags: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let playing = DJLinkStatusFlags(rawValue: 0x40)
    static let master = DJLinkStatusFlags(rawValue: 0x20)
    static let synced = DJLinkStatusFlags(rawValue: 0x10)
    static let onAir = DJLinkStatusFlags(rawValue: 0x08)
    static let bpmSync = DJLinkStatusFlags(rawValue: 0x02)
    static let fixedBits = DJLinkStatusFlags(rawValue: 0x84)
}

struct DJLinkKeepAlive: Equatable, Sendable {
    var name: String
    var device: UInt8
    var mac: DJLinkMAC
    var ip: DJLinkIPv4
    var peerCount: UInt8
    var isMixer: Bool = false
    var firstOnNetwork: Bool = false
    var cdj3000Compatible: Bool = false
}

struct DJLinkAnnounce: Equatable, Sendable {
    var name: String
    var cdj3000Compatible: Bool = false
}

struct DJLinkClaimStage1: Equatable, Sendable {
    var name: String
    var counter: UInt8
    var mac: DJLinkMAC
    var cdj3000Compatible: Bool = false
}

struct DJLinkClaimStage2: Equatable, Sendable {
    var name: String
    var ip: DJLinkIPv4
    var mac: DJLinkMAC
    var device: UInt8
    var counter: UInt8
    var autoAssign: Bool
    var cdj3000Compatible: Bool = false
    var isMixerRequest: Bool = false
}

struct DJLinkClaimStage3: Equatable, Sendable {
    var name: String
    var device: UInt8
    var counter: UInt8
    var cdj3000Compatible: Bool = false
}

struct DJLinkAssignIntention: Equatable, Sendable {
    var name: String
    var ip: DJLinkIPv4
    var mac: DJLinkMAC
}

struct DJLinkMixerAssignment: Equatable, Sendable {
    var name: String
    var device: UInt8
    var counter: UInt8
}

struct DJLinkAssignmentFinished: Equatable, Sendable {
    var name: String
    var device: UInt8
}

struct DJLinkConflict: Equatable, Sendable {
    var name: String
    var device: UInt8
    var ip: DJLinkIPv4
}

struct DJLinkBeat: Equatable, Sendable {
    static let unavailable: UInt32 = 0xffff_ffff

    var name: String
    var device: UInt8
    var nextBeat: UInt32
    var secondBeat: UInt32
    var nextBar: UInt32
    var fourthBeat: UInt32
    var secondBar: UInt32
    var eighthBeat: UInt32
    var pitch: DJLinkPitch
    var bpmHundredths: UInt16
    var beatWithinBar: UInt8

    var trackBPM: Double { Double(bpmHundredths) / 100 }
    var effectiveBPM: Double { trackBPM * pitch.multiplier }
}

struct DJLinkAbsolutePosition: Equatable, Sendable {
    var name: String
    var device: UInt8
    var trackLengthSeconds: UInt32
    var playheadMillis: UInt32
    var pitchHundredths: Int32
    var bpmTenths: UInt32

    var effectiveBPM: Double? { bpmTenths == 0xffff_ffff ? nil : Double(bpmTenths) / 10 }
}

struct DJLinkSyncControl: Equatable, Sendable {
    var name: String
    var device: UInt8
    var command: UInt8
}

struct DJLinkMasterRequest: Equatable, Sendable {
    var name: String
    var device: UInt8
}

struct DJLinkMasterResponse: Equatable, Sendable {
    var name: String
    var device: UInt8
    var accepted: Bool
}

struct DJLinkMixerStatus: Equatable, Sendable {
    var name: String
    var device: UInt8
    var flags: DJLinkStatusFlags
    var pitch: DJLinkPitch
    var bpmHundredths: UInt16
    var masterHandoff: UInt8
    var beatWithinBar: UInt8
    var subtype: UInt8 = 0x00

    var isMaster: Bool { flags.contains(.master) }
    var bpm: Double? { bpmHundredths == 0xffff ? nil : Double(bpmHundredths) / 100 }
}

struct DJLinkKey: Equatable, Sendable {
    var note: UInt8
    var isMajor: Bool
    var accidental: UInt8

    var displayName: String {
        let minorNames = ["Am", "B♭m", "Bm", "Cm", "C♯m", "Dm", "E♭m", "Em", "Fm", "F♯m", "Gm", "A♭m"]
        let majorNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let names = isMajor ? majorNames : minorNames
        return Int(note) < names.count ? names[Int(note)] : "?"
    }
}

struct DJLinkCDJStatus: Equatable, Sendable {
    static let nexusLength = 0xd4

    var name: String
    var device: UInt8
    var subtype: UInt8 = 0x03
    var length: Int = DJLinkCDJStatus.nexusLength
    var activity: UInt8 = 0
    var sourcePlayer: UInt8 = 0
    var sourceSlot: UInt8 = 0
    var trackType: UInt8 = 0
    var rekordboxId: UInt32 = 0
    var trackNumber: UInt16 = 0
    var playStateRaw: UInt8 = 0
    var firmware: String = ""
    var syncCounter: UInt32 = 0
    var flags: DJLinkStatusFlags = .fixedBits
    var playState2: UInt8 = 0x7e
    var pitch1: DJLinkPitch = DJLinkPitch(raw: DJLinkPitch.unity)
    var tempoMasterValidity: UInt16 = 0x7fff
    var bpmHundredths: UInt16 = 0xffff
    var pitch2: DJLinkPitch = DJLinkPitch(raw: DJLinkPitch.unity)
    var playState3: UInt8 = 0
    var masterMeaning: UInt8 = 0
    var masterHandoff: UInt8 = 0xff
    var beatNumber: UInt32 = 0xffff_ffff
    var cueCountdown: UInt16 = 0x01ff
    var beatWithinBar: UInt8 = 0
    var pitch3: DJLinkPitch = DJLinkPitch(raw: DJLinkPitch.unity)
    var pitch4: DJLinkPitch = DJLinkPitch(raw: DJLinkPitch.unity)
    var packetCounter: UInt32 = 0
    var nexusMarker: UInt8 = 0x0f
    var usbLocal: UInt8 = 0x04
    var sdLocal: UInt8 = 0x04
    var masterTempoEngaged: Bool?
    var key: DJLinkKey?
    var loopStartMillis: Double?
    var loopEndMillis: Double?

    var playState: DJLinkPlayState? { DJLinkPlayState(rawValue: playStateRaw) }
    var isPlaying: Bool { flags.contains(.playing) }
    var isMaster: Bool { flags.contains(.master) }
    var isSynced: Bool { flags.contains(.synced) }
    var isOnAir: Bool { flags.contains(.onAir) }
    var trackBPM: Double? { bpmHundredths == 0xffff ? nil : Double(bpmHundredths) / 100 }
    var effectiveBPM: Double? { trackBPM.map { $0 * pitch1.multiplier } }
    var beat: UInt32? { beatNumber == 0xffff_ffff ? nil : beatNumber }
    var hasTrack: Bool { trackType != 0 && sourcePlayer != 0 }
}

enum DJLinkPacket: Equatable, Sendable {
    case announce(DJLinkAnnounce)
    case claimStage1(DJLinkClaimStage1)
    case assignIntention(DJLinkAssignIntention)
    case claimStage2(DJLinkClaimStage2)
    case mixerAssignment(DJLinkMixerAssignment)
    case claimStage3(DJLinkClaimStage3)
    case assignmentFinished(DJLinkAssignmentFinished)
    case keepAlive(DJLinkKeepAlive)
    case conflict(DJLinkConflict)
    case beat(DJLinkBeat)
    case absolutePosition(DJLinkAbsolutePosition)
    case syncControl(DJLinkSyncControl)
    case masterRequest(DJLinkMasterRequest)
    case masterResponse(DJLinkMasterResponse)
    case cdjStatus(DJLinkCDJStatus)
    case mixerStatus(DJLinkMixerStatus)

    static let magic: [UInt8] = [0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c]

    var port: UInt16 {
        switch self {
        case .announce, .claimStage1, .assignIntention, .claimStage2, .mixerAssignment, .claimStage3,
             .assignmentFinished, .keepAlive, .conflict:
            return DJLinkPort.announce
        case .beat, .absolutePosition, .syncControl, .masterRequest, .masterResponse:
            return DJLinkPort.beat
        case .cdjStatus, .mixerStatus:
            return DJLinkPort.status
        }
    }

    var senderName: String {
        switch self {
        case .announce(let p): return p.name
        case .claimStage1(let p): return p.name
        case .assignIntention(let p): return p.name
        case .claimStage2(let p): return p.name
        case .mixerAssignment(let p): return p.name
        case .claimStage3(let p): return p.name
        case .assignmentFinished(let p): return p.name
        case .keepAlive(let p): return p.name
        case .conflict(let p): return p.name
        case .beat(let p): return p.name
        case .absolutePosition(let p): return p.name
        case .syncControl(let p): return p.name
        case .masterRequest(let p): return p.name
        case .masterResponse(let p): return p.name
        case .cdjStatus(let p): return p.name
        case .mixerStatus(let p): return p.name
        }
    }
}

// MARK: - Encoding

private struct DJLinkWriter {
    var bytes: [UInt8]

    init(length: Int) {
        bytes = Array(repeating: 0, count: length)
        put(DJLinkPacket.magic, at: 0)
    }

    mutating func put(_ value: UInt8, at offset: Int) {
        guard offset < bytes.count else { return }
        bytes[offset] = value
    }

    mutating func put16(_ value: UInt16, at offset: Int) {
        put(UInt8(value >> 8), at: offset)
        put(UInt8(value & 0xff), at: offset + 1)
    }

    mutating func put32(_ value: UInt32, at offset: Int) {
        put(UInt8(value >> 24 & 0xff), at: offset)
        put(UInt8(value >> 16 & 0xff), at: offset + 1)
        put(UInt8(value >> 8 & 0xff), at: offset + 2)
        put(UInt8(value & 0xff), at: offset + 3)
    }

    mutating func put(_ values: [UInt8], at offset: Int) {
        for (index, value) in values.enumerated() { put(value, at: offset + index) }
    }

    mutating func putName(_ name: String, at offset: Int) {
        let ascii = Array(name.unicodeScalars.filter(\.isASCII).map { UInt8($0.value) }.prefix(20))
        put(ascii, at: offset)
    }

    mutating func announceHeader(kind: UInt8, name: String, subtype: UInt8, secondByte: UInt8 = 0x00) {
        put(kind, at: 0x0a)
        put(secondByte, at: 0x0b)
        putName(name, at: 0x0c)
        put(0x01, at: 0x20)
        put(subtype, at: 0x21)
        put16(UInt16(bytes.count), at: 0x22)
    }

    mutating func deviceHeader(kind: UInt8, name: String, marker: UInt8 = 0x01, subtype: UInt8 = 0x00, device: UInt8) {
        put(kind, at: 0x0a)
        putName(name, at: 0x0b)
        put(marker, at: 0x1f)
        put(subtype, at: 0x20)
        put(device, at: 0x21)
        put16(UInt16(bytes.count - 0x24), at: 0x22)
    }

    var data: Data { Data(bytes) }
}

extension DJLinkPacket {
    func encode() -> Data {
        switch self {
        case .announce(let p):
            var w = DJLinkWriter(length: p.cdj3000Compatible ? 0x26 : 0x25)
            w.announceHeader(kind: 0x0a, name: p.name, subtype: p.cdj3000Compatible ? 0x04 : 0x02)
            w.put(0x01, at: 0x24)
            if p.cdj3000Compatible { w.put(0x40, at: 0x25) }
            return w.data

        case .claimStage1(let p):
            var w = DJLinkWriter(length: 0x2c)
            w.announceHeader(kind: 0x00, name: p.name, subtype: p.cdj3000Compatible ? 0x03 : 0x02)
            w.put(p.counter, at: 0x24)
            w.put(0x01, at: 0x25)
            w.put(p.mac.bytes, at: 0x26)
            return w.data

        case .assignIntention(let p):
            var w = DJLinkWriter(length: 0x2f)
            w.announceHeader(kind: 0x01, name: p.name, subtype: 0x02)
            w.put(p.ip.bytes, at: 0x24)
            w.put(p.mac.bytes, at: 0x28)
            w.put(0x01, at: 0x2e)
            return w.data

        case .claimStage2(let p):
            var w = DJLinkWriter(length: 0x32)
            w.announceHeader(
                kind: 0x02,
                name: p.name,
                subtype: p.cdj3000Compatible ? 0x03 : 0x02,
                secondByte: p.isMixerRequest ? 0x01 : 0x00
            )
            w.put(p.ip.bytes, at: 0x24)
            w.put(p.mac.bytes, at: 0x28)
            w.put(p.device, at: 0x2e)
            w.put(p.counter, at: 0x2f)
            w.put(0x01, at: 0x30)
            w.put(p.autoAssign ? 0x01 : 0x02, at: 0x31)
            return w.data

        case .mixerAssignment(let p):
            var w = DJLinkWriter(length: 0x27)
            w.announceHeader(kind: 0x03, name: p.name, subtype: 0x02, secondByte: 0x01)
            w.put(p.device, at: 0x24)
            w.put(p.counter, at: 0x25)
            return w.data

        case .claimStage3(let p):
            var w = DJLinkWriter(length: 0x26)
            w.announceHeader(kind: 0x04, name: p.name, subtype: p.cdj3000Compatible ? 0x03 : 0x02)
            w.put(p.device, at: 0x24)
            w.put(p.counter, at: 0x25)
            return w.data

        case .assignmentFinished(let p):
            var w = DJLinkWriter(length: 0x26)
            w.announceHeader(kind: 0x05, name: p.name, subtype: 0x02)
            w.put(p.device, at: 0x24)
            w.put(0x01, at: 0x25)
            return w.data

        case .keepAlive(let p):
            var w = DJLinkWriter(length: 0x36)
            w.announceHeader(kind: 0x06, name: p.name, subtype: 0x02)
            w.put(p.device, at: 0x24)
            w.put(p.firstOnNetwork ? 0x02 : 0x01, at: 0x25)
            w.put(p.mac.bytes, at: 0x26)
            w.put(p.ip.bytes, at: 0x2c)
            w.put(p.peerCount, at: 0x30)
            w.put(p.isMixer ? 0x02 : 0x01, at: 0x34)
            w.put(p.cdj3000Compatible ? 0x64 : 0x00, at: 0x35)
            return w.data

        case .conflict(let p):
            var w = DJLinkWriter(length: 0x29)
            w.announceHeader(kind: 0x08, name: p.name, subtype: 0x02)
            w.put(p.device, at: 0x24)
            w.put(p.ip.bytes, at: 0x25)
            return w.data

        case .beat(let p):
            var w = DJLinkWriter(length: 0x60)
            w.deviceHeader(kind: 0x28, name: p.name, device: p.device)
            w.put32(p.nextBeat, at: 0x24)
            w.put32(p.secondBeat, at: 0x28)
            w.put32(p.nextBar, at: 0x2c)
            w.put32(p.fourthBeat, at: 0x30)
            w.put32(p.secondBar, at: 0x34)
            w.put32(p.eighthBeat, at: 0x38)
            w.put(Array(repeating: 0xff, count: 0x18), at: 0x3c)
            w.put32(p.pitch.raw, at: 0x54)
            w.put16(p.bpmHundredths, at: 0x5a)
            w.put(p.beatWithinBar, at: 0x5c)
            w.put(p.device, at: 0x5f)
            return w.data

        case .absolutePosition(let p):
            var w = DJLinkWriter(length: 0x3c)
            w.deviceHeader(kind: 0x0b, name: p.name, marker: 0x02, device: p.device)
            w.put32(p.trackLengthSeconds, at: 0x24)
            w.put32(p.playheadMillis, at: 0x28)
            w.put32(UInt32(bitPattern: p.pitchHundredths), at: 0x2c)
            w.put32(p.bpmTenths, at: 0x38)
            return w.data

        case .syncControl(let p):
            var w = DJLinkWriter(length: 0x2c)
            w.deviceHeader(kind: 0x2a, name: p.name, device: p.device)
            w.put(p.device, at: 0x27)
            w.put(p.command, at: 0x2b)
            return w.data

        case .masterRequest(let p):
            var w = DJLinkWriter(length: 0x28)
            w.deviceHeader(kind: 0x26, name: p.name, device: p.device)
            w.put(p.device, at: 0x27)
            return w.data

        case .masterResponse(let p):
            var w = DJLinkWriter(length: 0x2c)
            w.deviceHeader(kind: 0x27, name: p.name, device: p.device)
            w.put(p.device, at: 0x27)
            w.put(p.accepted ? 0x01 : 0x00, at: 0x2b)
            return w.data

        case .mixerStatus(let p):
            var w = DJLinkWriter(length: 0x38)
            w.deviceHeader(kind: 0x29, name: p.name, subtype: p.subtype, device: p.device)
            if p.subtype == 0x01 { w.put16(0x38, at: 0x22) }
            w.put(p.device, at: 0x24)
            w.put(p.flags.rawValue, at: 0x27)
            w.put32(p.pitch.raw, at: 0x28)
            w.put16(0x8000, at: 0x2c)
            w.put16(p.bpmHundredths, at: 0x2e)
            w.put32(DJLinkPitch.unity, at: 0x30)
            w.put(0x09, at: 0x35)
            w.put(p.masterHandoff, at: 0x36)
            w.put(p.beatWithinBar, at: 0x37)
            return w.data

        case .cdjStatus(let p):
            var w = DJLinkWriter(length: max(0xd0, p.length))
            w.deviceHeader(kind: 0x0a, name: p.name, subtype: p.subtype, device: p.device)
            w.put(p.device, at: 0x24)
            w.put(0x01, at: 0x26)
            w.put(p.activity, at: 0x27)
            w.put(p.sourcePlayer, at: 0x28)
            w.put(p.sourceSlot, at: 0x29)
            w.put(p.trackType, at: 0x2a)
            w.put32(p.rekordboxId, at: 0x2c)
            w.put16(p.trackNumber, at: 0x32)
            w.put(0x01, at: 0x68)
            w.put(p.usbLocal, at: 0x6f)
            w.put(p.sdLocal, at: 0x73)
            w.put(0x01, at: 0x78)
            w.put(p.playStateRaw, at: 0x7b)
            w.putName(String(p.firmware.prefix(4)), at: 0x7c)
            w.put32(p.syncCounter, at: 0x84)
            w.put(p.flags.rawValue, at: 0x89)
            w.put(0xff, at: 0x8a)
            w.put(p.playState2, at: 0x8b)
            w.put32(p.pitch1.raw, at: 0x8c)
            w.put16(p.tempoMasterValidity, at: 0x90)
            w.put16(p.bpmHundredths, at: 0x92)
            w.put16(0x7fff, at: 0x94)
            w.put16(0xffff, at: 0x96)
            w.put32(p.pitch2.raw, at: 0x98)
            w.put(p.playState3, at: 0x9d)
            w.put(p.masterMeaning, at: 0x9e)
            w.put(p.masterHandoff, at: 0x9f)
            w.put32(p.beatNumber, at: 0xa0)
            w.put16(p.cueCountdown, at: 0xa4)
            w.put(p.beatWithinBar, at: 0xa6)
            w.put(0x01, at: 0xb6)
            w.put32(p.pitch3.raw, at: 0xc0)
            w.put32(p.pitch4.raw, at: 0xc4)
            w.put32(p.packetCounter, at: 0xc8)
            w.put(p.nexusMarker, at: 0xcc)
            if let engaged = p.masterTempoEngaged { w.put(engaged ? 0x01 : 0x00, at: 0x158) }
            if let key = p.key {
                w.put(key.note, at: 0x15c)
                w.put(key.isMajor ? 0x01 : 0x00, at: 0x15d)
                w.put(key.accidental, at: 0x15e)
            }
            if let start = p.loopStartMillis { w.put32(UInt32((start * 1000 / 65536).rounded()), at: 0x1b6) }
            if let end = p.loopEndMillis { w.put32(UInt32((end * 1000 / 65536).rounded()), at: 0x1be) }
            return w.data
        }
    }
}

// MARK: - Decoding

private struct DJLinkReader {
    let bytes: [UInt8]

    var count: Int { bytes.count }

    func u8(_ offset: Int) -> UInt8 { offset < bytes.count ? bytes[offset] : 0 }

    func u16(_ offset: Int) -> UInt16 { UInt16(u8(offset)) << 8 | UInt16(u8(offset + 1)) }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u8(offset)) << 24 | UInt32(u8(offset + 1)) << 16 | UInt32(u8(offset + 2)) << 8 | UInt32(u8(offset + 3))
    }

    func slice(_ offset: Int, _ length: Int) -> [UInt8] {
        guard offset + length <= bytes.count else { return Array(repeating: 0, count: length) }
        return Array(bytes[offset..<(offset + length)])
    }

    func ip(_ offset: Int) -> DJLinkIPv4 { DJLinkIPv4(raw: u32(offset)) }

    func mac(_ offset: Int) -> DJLinkMAC { DJLinkMAC(slice(offset, 6)) }

    func name(_ offset: Int) -> String {
        let raw = slice(offset, 20).prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

extension DJLinkPacket {
    static func decode(_ data: Data, port: UInt16) -> DJLinkPacket? {
        let r = DJLinkReader(bytes: [UInt8](data))
        guard r.count >= 0x24, r.slice(0, 10) == magic else { return nil }
        let kind = r.u8(0x0a)
        switch port {
        case DJLinkPort.announce: return decodeAnnounce(kind: kind, r)
        case DJLinkPort.beat: return decodeBeat(kind: kind, r)
        case DJLinkPort.status: return decodeStatus(kind: kind, r)
        default: return nil
        }
    }

    private static func decodeAnnounce(kind: UInt8, _ r: DJLinkReader) -> DJLinkPacket? {
        let name = r.name(0x0c)
        let subtype = r.u8(0x21)
        let compatible = subtype == 0x03 || subtype == 0x04
        switch kind {
        case 0x0a where r.count >= 0x25:
            return .announce(DJLinkAnnounce(name: name, cdj3000Compatible: subtype == 0x04))
        case 0x00 where r.count >= 0x2c:
            return .claimStage1(DJLinkClaimStage1(name: name, counter: r.u8(0x24), mac: r.mac(0x26), cdj3000Compatible: compatible))
        case 0x01 where r.count >= 0x2f:
            return .assignIntention(DJLinkAssignIntention(name: name, ip: r.ip(0x24), mac: r.mac(0x28)))
        case 0x02 where r.count >= 0x32:
            return .claimStage2(DJLinkClaimStage2(
                name: name,
                ip: r.ip(0x24),
                mac: r.mac(0x28),
                device: r.u8(0x2e),
                counter: r.u8(0x2f),
                autoAssign: r.u8(0x31) == 0x01,
                cdj3000Compatible: compatible,
                isMixerRequest: r.u8(0x0b) == 0x01
            ))
        case 0x03 where r.count >= 0x26:
            return .mixerAssignment(DJLinkMixerAssignment(name: name, device: r.u8(0x24), counter: r.u8(0x25)))
        case 0x04 where r.count >= 0x26:
            return .claimStage3(DJLinkClaimStage3(name: name, device: r.u8(0x24), counter: r.u8(0x25), cdj3000Compatible: compatible))
        case 0x05 where r.count >= 0x26:
            return .assignmentFinished(DJLinkAssignmentFinished(name: name, device: r.u8(0x24)))
        case 0x06 where r.count >= 0x36:
            return .keepAlive(DJLinkKeepAlive(
                name: name,
                device: r.u8(0x24),
                mac: r.mac(0x26),
                ip: r.ip(0x2c),
                peerCount: r.u8(0x30),
                isMixer: r.u8(0x34) == 0x02,
                firstOnNetwork: r.u8(0x25) == 0x02,
                cdj3000Compatible: r.u8(0x35) == 0x64
            ))
        case 0x08 where r.count >= 0x29:
            return .conflict(DJLinkConflict(name: name, device: r.u8(0x24), ip: r.ip(0x25)))
        default:
            return nil
        }
    }

    private static func decodeBeat(kind: UInt8, _ r: DJLinkReader) -> DJLinkPacket? {
        let name = r.name(0x0b)
        let device = r.u8(0x21)
        switch kind {
        case 0x28 where r.count >= 0x60:
            return .beat(DJLinkBeat(
                name: name,
                device: device,
                nextBeat: r.u32(0x24),
                secondBeat: r.u32(0x28),
                nextBar: r.u32(0x2c),
                fourthBeat: r.u32(0x30),
                secondBar: r.u32(0x34),
                eighthBeat: r.u32(0x38),
                pitch: DJLinkPitch(raw: r.u32(0x54)),
                bpmHundredths: r.u16(0x5a),
                beatWithinBar: r.u8(0x5c)
            ))
        case 0x0b where r.count >= 0x3c:
            return .absolutePosition(DJLinkAbsolutePosition(
                name: name,
                device: device,
                trackLengthSeconds: r.u32(0x24),
                playheadMillis: r.u32(0x28),
                pitchHundredths: Int32(bitPattern: r.u32(0x2c)),
                bpmTenths: r.u32(0x38)
            ))
        case 0x2a where r.count >= 0x2c:
            return .syncControl(DJLinkSyncControl(name: name, device: r.u8(0x27), command: r.u8(0x2b)))
        case 0x26 where r.count >= 0x28:
            return .masterRequest(DJLinkMasterRequest(name: name, device: r.u8(0x27)))
        case 0x27 where r.count >= 0x2c:
            return .masterResponse(DJLinkMasterResponse(name: name, device: r.u8(0x27), accepted: r.u8(0x2b) == 0x01))
        default:
            return nil
        }
    }

    private static func decodeStatus(kind: UInt8, _ r: DJLinkReader) -> DJLinkPacket? {
        let name = r.name(0x0b)
        switch kind {
        case 0x29 where r.count >= 0x38:
            return .mixerStatus(DJLinkMixerStatus(
                name: name,
                device: r.u8(0x24),
                flags: DJLinkStatusFlags(rawValue: r.u8(0x27)),
                pitch: DJLinkPitch(raw: r.u32(0x28)),
                bpmHundredths: r.u16(0x2e),
                masterHandoff: r.u8(0x36),
                beatWithinBar: r.u8(0x37),
                subtype: r.u8(0x20)
            ))
        case 0x0a where r.count >= 0xd0:
            var status = DJLinkCDJStatus(name: name, device: r.u8(0x24))
            status.subtype = r.u8(0x20)
            status.length = r.count
            status.activity = r.u8(0x27)
            status.sourcePlayer = r.u8(0x28)
            status.sourceSlot = r.u8(0x29)
            status.trackType = r.u8(0x2a)
            status.rekordboxId = r.u32(0x2c)
            status.trackNumber = r.u16(0x32)
            status.usbLocal = r.u8(0x6f)
            status.sdLocal = r.u8(0x73)
            status.playStateRaw = r.u8(0x7b)
            status.firmware = String(decoding: r.slice(0x7c, 4).prefix { $0 != 0 }, as: UTF8.self)
            status.syncCounter = r.u32(0x84)
            status.flags = DJLinkStatusFlags(rawValue: r.u8(0x89))
            status.playState2 = r.u8(0x8b)
            status.pitch1 = DJLinkPitch(raw: r.u32(0x8c))
            status.tempoMasterValidity = r.u16(0x90)
            status.bpmHundredths = r.u16(0x92)
            status.pitch2 = DJLinkPitch(raw: r.u32(0x98))
            status.playState3 = r.u8(0x9d)
            status.masterMeaning = r.u8(0x9e)
            status.masterHandoff = r.u8(0x9f)
            status.beatNumber = r.u32(0xa0)
            status.cueCountdown = r.u16(0xa4)
            status.beatWithinBar = r.u8(0xa6)
            status.pitch3 = DJLinkPitch(raw: r.u32(0xc0))
            status.pitch4 = DJLinkPitch(raw: r.u32(0xc4))
            status.packetCounter = r.u32(0xc8)
            status.nexusMarker = r.u8(0xcc)
            if r.count >= 0x15f {
                status.masterTempoEngaged = r.u8(0x158) == 0x01
                if r.u8(0x15e) != 0x64, r.u8(0x15c) < 12 {
                    status.key = DJLinkKey(note: r.u8(0x15c), isMajor: r.u8(0x15d) == 0x01, accidental: r.u8(0x15e))
                }
            }
            if r.count >= 0x1c2 {
                let start = r.u32(0x1b6)
                let end = r.u32(0x1be)
                if start != 0 { status.loopStartMillis = Double(start) * 65536 / 1000 }
                if end != 0 { status.loopEndMillis = Double(end) * 65536 / 1000 }
            }
            return .cdjStatus(status)
        default:
            return nil
        }
    }
}
#endif
