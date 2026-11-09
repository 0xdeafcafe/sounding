import Foundation

struct ANLZBeat: Equatable, Sendable {
    var beatNumber: UInt16
    var tempo: UInt16
    var timeMillis: UInt32

    var bpm: Double { Double(tempo) / 100 }
    var seconds: Double { Double(timeMillis) / 1000 }
}

enum ANLZCueListKind: UInt32, Sendable {
    case memory = 0
    case hotCues = 1
}

struct ANLZCue: Equatable, Sendable {
    static let noLoop: UInt32 = 0xFFFF_FFFF

    var hotCue: UInt32 = 0
    var isLoop: Bool = false
    var timeMillis: UInt32
    var loopTimeMillis: UInt32 = ANLZCue.noLoop
    var status: UInt32 = 0
    var colorId: UInt8 = 0
    var loopNumerator: UInt16 = 0
    var loopDenominator: UInt16 = 0
    var comment: String = ""
    var colorCode: UInt8 = 0
    var colorRed: UInt8 = 0
    var colorGreen: UInt8 = 0
    var colorBlue: UInt8 = 0
    var extendedUnknown: [UInt8] = [0x01, 0, 0, 0, 0, 0, 0]
    var extendedTrailer: [UInt8] = [UInt8](repeating: 0, count: 20)
}

struct ANLZCueList: Equatable, Sendable {
    var kind: ANLZCueListKind
    var cues: [ANLZCue]
    var unknown: UInt16 = 0
    var memoryCount: UInt32 = 0xFFFF_FFFF
}

struct ANLZPhrase: Equatable, Sendable {
    var index: UInt16
    var beat: UInt16
    var kind: UInt16
    var k1: UInt8 = 0
    var k2: UInt8 = 0
    var b: UInt8 = 0
    var beat2: UInt16 = 0
    var beat3: UInt16 = 0
    var beat4: UInt16 = 0
    var k3: UInt8 = 0
    var fill: UInt8 = 0
    var beatFill: UInt16 = 0
    var unknownBytes: [UInt8] = [0, 0, 0, 0, 0]
}

enum ANLZMood: UInt16, Sendable {
    case high = 1
    case mid = 2
    case low = 3
}

struct ANLZSongStructure: Equatable, Sendable {
    var version: UInt16 = 0
    var mood: UInt16
    var endBeat: UInt16
    var bank: UInt8 = 0
    var phrases: [ANLZPhrase]
    var unknown1: [UInt8] = [0, 0, 0, 0, 0, 0]
    var unknown2: UInt16 = 0x0100
    var unknown3: UInt8 = 0
    var masked: Bool = true
}

enum ANLZTag: Equatable, Sendable {
    case path(String)
    case beatGrid([ANLZBeat])
    case cueList(ANLZCueList)
    case extendedCueList(ANLZCueList)
    case waveformPreview([UInt8])
    case tinyWaveformPreview([UInt8])
    case waveformDetail([UInt8])
    case colorWaveformPreview([UInt8])
    case colorWaveformDetail([UInt16])
    case songStructure(ANLZSongStructure)
    case threeBandPreview([UInt8])
    case threeBandDetail([UInt8])
    case threeBandScale(unknown: UInt16, values: [UInt16])
    case unknown(fourCC: String, header: [UInt8], body: [UInt8])

    var fourCC: String {
        switch self {
        case .path: return "PPTH"
        case .beatGrid: return "PQTZ"
        case .cueList: return "PCOB"
        case .extendedCueList: return "PCO2"
        case .waveformPreview: return "PWAV"
        case .tinyWaveformPreview: return "PWV2"
        case .waveformDetail: return "PWV3"
        case .colorWaveformPreview: return "PWV4"
        case .colorWaveformDetail: return "PWV5"
        case .songStructure: return "PSSI"
        case .threeBandPreview: return "PWV6"
        case .threeBandDetail: return "PWV7"
        case .threeBandScale: return "PWVC"
        case .unknown(let code, _, _): return code
        }
    }

    static func vbr(totalSamples: UInt32) -> ANLZTag {
        var body = DJByteWriter(capacity: 1604)
        body.zeros(400 * 4)
        body.u32be(totalSamples)
        return .unknown(fourCC: "PVBR", header: [0, 0, 0, 0], body: body.bytes)
    }
}

struct ANLZFile: Equatable, Sendable {
    static let defaultHeaderTail: [UInt8] = [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]

    var headerTail: [UInt8] = ANLZFile.defaultHeaderTail
    var tags: [ANLZTag] = []

    var path: String? {
        for case .path(let p) in tags { return p }
        return nil
    }

    var beatGrid: [ANLZBeat]? {
        for case .beatGrid(let beats) in tags { return beats }
        return nil
    }

    func cueList(_ kind: ANLZCueListKind, extended: Bool) -> ANLZCueList? {
        for tag in tags {
            switch tag {
            case .cueList(let list) where !extended && list.kind == kind: return list
            case .extendedCueList(let list) where extended && list.kind == kind: return list
            default: continue
            }
        }
        return nil
    }

    var songStructure: ANLZSongStructure? {
        for case .songStructure(let s) in tags { return s }
        return nil
    }

    var threeBandPreview: [UInt8]? {
        for case .threeBandPreview(let d) in tags { return d }
        return nil
    }

    var threeBandDetail: [UInt8]? {
        for case .threeBandDetail(let d) in tags { return d }
        return nil
    }

    func tag(_ fourCC: String) -> ANLZTag? { tags.first { $0.fourCC == fourCC } }
}

// MARK: - Reader

struct ANLZReadResult: Sendable {
    var file: ANLZFile
    var issues: [String]
}

enum ANLZCodec {
    static let songStructureMask: [UInt8] = [
        0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2, 0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1,
    ]

    static func read(_ data: Data) throws -> ANLZReadResult {
        let r = DJByteReader(data)
        guard try r.fourCC(0) == "PMAI" else { throw DJMediaFormatError.badMagic("PMAI") }
        let headerLength = Int(try r.u32be(4))
        let fileLength = Int(try r.u32be(8))
        guard headerLength >= 12, headerLength <= r.count else {
            throw DJMediaFormatError.malformed("ANLZ header length \(headerLength)")
        }
        var issues: [String] = []
        if fileLength != r.count { issues.append("len_file \(fileLength) but file has \(r.count) bytes") }
        var file = ANLZFile(headerTail: try r.slice(12, headerLength - 12), tags: [])
        let end = min(fileLength, r.count)
        var o = headerLength
        while o + 12 <= end {
            let code = try r.fourCC(o)
            let tagHeader = Int(try r.u32be(o + 4))
            let tagLength = Int(try r.u32be(o + 8))
            guard tagHeader >= 12, tagLength >= tagHeader, r.has(o, tagLength), o + tagLength <= end else {
                issues.append("\(code) at \(o): bad lengths \(tagHeader)/\(tagLength)")
                break
            }
            let tag = DJByteReader(try r.slice(o, tagLength))
            do {
                file.tags.append(try decodeTag(code, tag, headerLength: tagHeader))
            } catch {
                issues.append("\(code) at \(o): \(error)")
                file.tags.append(.unknown(
                    fourCC: code,
                    header: try r.slice(o + 12, tagHeader - 12),
                    body: try r.slice(o + tagHeader, tagLength - tagHeader)
                ))
            }
            o += tagLength
        }
        if o < end { issues.append("\(end - o) trailing bytes") }
        return ANLZReadResult(file: file, issues: issues)
    }

    static func decodeTag(_ code: String, _ t: DJByteReader, headerLength: Int) throws -> ANLZTag {
        switch code {
        case "PPTH":
            let length = Int(try t.u32be(12))
            return .path(DeviceSQLString.decodeUTF16BigEndianTerminated(try t.slice(headerLength, length)))
        case "PQTZ":
            let count = Int(try t.u32be(20))
            try t.check(headerLength, count * 8)
            var beats: [ANLZBeat] = []
            beats.reserveCapacity(count)
            for i in 0 ..< count {
                let b = headerLength + 8 * i
                beats.append(ANLZBeat(beatNumber: try t.u16be(b), tempo: try t.u16be(b + 2), timeMillis: try t.u32be(b + 4)))
            }
            return .beatGrid(beats)
        case "PCOB":
            return .cueList(try decodeCueList(t, headerLength: headerLength, extended: false))
        case "PCO2":
            return .extendedCueList(try decodeCueList(t, headerLength: headerLength, extended: true))
        case "PWAV", "PWV2":
            let count = Int(try t.u32be(12))
            let data = try t.slice(headerLength, count)
            return code == "PWAV" ? .waveformPreview(data) : .tinyWaveformPreview(data)
        case "PWV3", "PWV4", "PWV5":
            let entryBytes = Int(try t.u32be(12))
            let count = Int(try t.u32be(16))
            guard entryBytes == (code == "PWV3" ? 1 : code == "PWV4" ? 6 : 2) else {
                throw DJMediaFormatError.malformed("\(code) entry size \(entryBytes)")
            }
            let data = try t.slice(headerLength, entryBytes * count)
            if code == "PWV3" { return .waveformDetail(data) }
            if code == "PWV4" { return .colorWaveformPreview(data) }
            var words: [UInt16] = []
            words.reserveCapacity(count)
            for i in 0 ..< count { words.append(UInt16(data[2 * i]) << 8 | UInt16(data[2 * i + 1])) }
            return .colorWaveformDetail(words)
        case "PSSI":
            return .songStructure(try decodeSongStructure(t, headerLength: headerLength))
        case "PWV6", "PWV7":
            let entryBytes = Int(try t.u32be(12))
            let count = Int(try t.u32be(16))
            guard entryBytes == 3 else { throw DJMediaFormatError.malformed("\(code) entry size \(entryBytes)") }
            guard headerLength == (code == "PWV6" ? 0x14 : 0x18) else {
                throw DJMediaFormatError.malformed("\(code) header length \(headerLength)")
            }
            let data = try t.slice(headerLength, entryBytes * count)
            return code == "PWV6" ? .threeBandPreview(data) : .threeBandDetail(data)
        case "PWVC":
            guard headerLength == 0x0E, t.count >= 0x14 else { throw DJMediaFormatError.malformed("PWVC length \(t.count)") }
            return .threeBandScale(unknown: try t.u16be(12), values: [try t.u16be(14), try t.u16be(16), try t.u16be(18)])
        default:
            return .unknown(fourCC: code, header: try t.slice(12, headerLength - 12), body: try t.slice(headerLength, t.count - headerLength))
        }
    }

    static func decodeCueList(_ t: DJByteReader, headerLength: Int, extended: Bool) throws -> ANLZCueList {
        let rawKind = try t.u32be(12)
        guard let kind = ANLZCueListKind(rawValue: rawKind) else { throw DJMediaFormatError.malformed("cue list type \(rawKind)") }
        var list: ANLZCueList
        let count: Int
        if extended {
            count = Int(try t.u16be(16))
            list = ANLZCueList(kind: kind, cues: [], unknown: try t.u16be(18))
        } else {
            count = Int(try t.u16be(18))
            list = ANLZCueList(kind: kind, cues: [], unknown: try t.u16be(16), memoryCount: try t.u32be(20))
        }
        var o = headerLength
        for _ in 0 ..< count {
            let entryLength = Int(try t.u32be(o + 8))
            guard entryLength >= 12, t.has(o, entryLength) else { throw DJMediaFormatError.malformed("cue entry length \(entryLength)") }
            let e = DJByteReader(try t.slice(o, entryLength))
            list.cues.append(extended ? try decodeExtendedCue(e) : try decodeCue(e))
            o += entryLength
        }
        return list
    }

    static func decodeCue(_ e: DJByteReader) throws -> ANLZCue {
        guard try e.fourCC(0) == "PCPT" else { throw DJMediaFormatError.badMagic("PCPT") }
        return ANLZCue(
            hotCue: try e.u32be(12),
            isLoop: try e.u8(0x1C) == 2,
            timeMillis: try e.u32be(0x20),
            loopTimeMillis: try e.u32be(0x24),
            status: try e.u32be(16)
        )
    }

    static func decodeExtendedCue(_ e: DJByteReader) throws -> ANLZCue {
        guard try e.fourCC(0) == "PCP2" else { throw DJMediaFormatError.badMagic("PCP2") }
        var cue = ANLZCue(
            hotCue: try e.u32be(12),
            isLoop: try e.u8(0x10) == 2,
            timeMillis: try e.u32be(0x14),
            loopTimeMillis: try e.u32be(0x18)
        )
        cue.extendedUnknown = []
        cue.extendedTrailer = []
        guard e.has(0x1C, 1) else { return cue }
        cue.colorId = try e.u8(0x1C)
        if e.has(0x1D, 7) { cue.extendedUnknown = try e.slice(0x1D, 7) }
        guard e.has(0x24, 8) else { return cue }
        cue.loopNumerator = try e.u16be(0x24)
        cue.loopDenominator = try e.u16be(0x26)
        let commentLength = Int(try e.u32be(0x28))
        guard e.has(0x2C, commentLength) else { return cue }
        cue.comment = DeviceSQLString.decodeUTF16BigEndianTerminated(try e.slice(0x2C, commentLength))
        let colorAt = 0x2C + commentLength
        guard e.has(colorAt, 4) else { return cue }
        cue.colorCode = try e.u8(colorAt)
        cue.colorRed = try e.u8(colorAt + 1)
        cue.colorGreen = try e.u8(colorAt + 2)
        cue.colorBlue = try e.u8(colorAt + 3)
        cue.extendedTrailer = try e.slice(colorAt + 4, e.count - colorAt - 4)
        return cue
    }

    static func applySongStructureMask(_ bytes: inout [UInt8], version: UInt16, entryCount: UInt16) {
        let start = Int(version) % songStructureMask.count
        let offset = UInt8(truncatingIfNeeded: entryCount)
        guard bytes.count > 18 else { return }
        for x in 0 ..< bytes.count - 18 {
            bytes[18 + x] ^= songStructureMask[(x + start) % songStructureMask.count] &+ offset
        }
    }

    static func decodeSongStructure(_ t: DJByteReader, headerLength: Int) throws -> ANLZSongStructure {
        var bytes = t.bytes
        let version = try t.u16be(12)
        let entryBytes = Int(try t.u16be(14))
        let count = try t.u16be(16)
        guard entryBytes == 24 else { throw DJMediaFormatError.malformed("PSSI entry size \(entryBytes)") }
        var masked = false
        if !(1 ... 3).contains(try t.u16be(18)) {
            applySongStructureMask(&bytes, version: version, entryCount: count)
            masked = true
        }
        let u = DJByteReader(bytes)
        var s = ANLZSongStructure(
            version: version,
            mood: try u.u16be(18),
            endBeat: try u.u16be(26),
            bank: try u.u8(30),
            phrases: [],
            unknown1: try u.slice(20, 6),
            unknown2: try u.u16be(28),
            unknown3: try u.u8(31),
            masked: masked
        )
        try u.check(headerLength, Int(count) * 24)
        for i in 0 ..< Int(count) {
            let p = headerLength + 24 * i
            s.phrases.append(ANLZPhrase(
                index: try u.u16be(p),
                beat: try u.u16be(p + 2),
                kind: try u.u16be(p + 4),
                k1: try u.u8(p + 7),
                k2: try u.u8(p + 9),
                b: try u.u8(p + 11),
                beat2: try u.u16be(p + 12),
                beat3: try u.u16be(p + 14),
                beat4: try u.u16be(p + 16),
                k3: try u.u8(p + 19),
                fill: try u.u8(p + 21),
                beatFill: try u.u16be(p + 22),
                unknownBytes: [try u.u8(p + 6), try u.u8(p + 8), try u.u8(p + 10), try u.u8(p + 18), try u.u8(p + 20)]
            ))
        }
        return s
    }

    // MARK: - Writer

    static func write(_ file: ANLZFile) -> Data {
        var w = DJByteWriter(capacity: 4096)
        w.fourCC("PMAI")
        w.u32be(UInt32(12 + file.headerTail.count))
        w.u32be(0)
        w.append(file.headerTail)
        for tag in file.tags { encode(tag, into: &w) }
        w.setU32be(UInt32(w.count), at: 8)
        return Data(w.bytes)
    }

    static func encode(_ tag: ANLZTag, into out: inout DJByteWriter) {
        var header = DJByteWriter()
        var body = DJByteWriter()
        switch tag {
        case .path(let path):
            let raw = DeviceSQLString.utf16BigEndianTerminated(path)
            header.u32be(UInt32(raw.count))
            body.append(raw)
        case .beatGrid(let beats):
            header.u32be(0)
            header.u32be(0x0008_0000)
            header.u32be(UInt32(beats.count))
            for b in beats {
                body.u16be(b.beatNumber)
                body.u16be(b.tempo)
                body.u32be(b.timeMillis)
            }
        case .cueList(let list):
            header.u32be(list.kind.rawValue)
            header.u16be(list.unknown)
            header.u16be(UInt16(clamping: list.cues.count))
            header.u32be(list.memoryCount)
            for (i, cue) in list.cues.prefix(Int(UInt16.max)).enumerated() {
                encodeCue(cue, index: i, total: list.cues.count, into: &body)
            }
        case .extendedCueList(let list):
            header.u32be(list.kind.rawValue)
            header.u16be(UInt16(clamping: list.cues.count))
            header.u16be(list.unknown)
            for cue in list.cues.prefix(Int(UInt16.max)) { encodeExtendedCue(cue, into: &body) }
        case .waveformPreview(let data), .tinyWaveformPreview(let data):
            header.u32be(UInt32(data.count))
            header.u32be(0x0001_0000)
            body.append(data)
        case .waveformDetail(let data):
            header.u32be(1)
            header.u32be(UInt32(data.count))
            header.u32be(0x0096_0000)
            body.append(data)
        case .colorWaveformPreview(let data):
            header.u32be(6)
            header.u32be(UInt32(data.count / 6))
            header.u32be(0)
            body.append(Array(data.prefix(data.count / 6 * 6)))
        case .colorWaveformDetail(let words):
            header.u32be(2)
            header.u32be(UInt32(words.count))
            header.u32be(0x0096_0305)
            for word in words { body.u16be(word) }
        case .songStructure(let s):
            encodeSongStructure(s, into: &out)
            return
        case .threeBandPreview(let data):
            header.u32be(3)
            header.u32be(UInt32(data.count / 3))
            body.append(Array(data.prefix(data.count / 3 * 3)))
        case .threeBandDetail(let data):
            header.u32be(3)
            header.u32be(UInt32(data.count / 3))
            header.u32be(0x0096_0000)
            body.append(Array(data.prefix(data.count / 3 * 3)))
        case .threeBandScale(let unknown, let values):
            header.u16be(unknown)
            for value in (values + [0, 0, 0]).prefix(3) { body.u16be(value) }
        case .unknown(_, let h, let b):
            header.append(h)
            body.append(b)
        }
        out.fourCC(tag.fourCC)
        out.u32be(UInt32(12 + header.count))
        out.u32be(UInt32(12 + header.count + body.count))
        out.append(header.bytes)
        out.append(body.bytes)
    }

    static func encodeCue(_ cue: ANLZCue, index: Int, total: Int, into w: inout DJByteWriter) {
        w.fourCC("PCPT")
        w.u32be(0x1C)
        w.u32be(0x38)
        w.u32be(cue.hotCue)
        w.u32be(cue.status)
        w.u32be(0x0001_0000)
        w.u16be(index == 0 ? 0xFFFF : UInt16(clamping: index - 1))
        w.u16be(index == total - 1 ? 0xFFFF : UInt16(clamping: index + 1))
        w.u8(cue.isLoop ? 2 : 1)
        w.u8(0)
        w.u16be(1000)
        w.u32be(cue.timeMillis)
        w.u32be(cue.isLoop ? cue.loopTimeMillis : ANLZCue.noLoop)
        w.zeros(16)
    }

    static func encodeExtendedCue(_ cue: ANLZCue, into w: inout DJByteWriter) {
        let comment = cue.comment.isEmpty ? [] : DeviceSQLString.utf16BigEndianTerminated(cue.comment)
        let unknown = Array((cue.extendedUnknown + [UInt8](repeating: 0, count: 7)).prefix(7))
        let length = 0x2C + comment.count + 4 + cue.extendedTrailer.count
        w.fourCC("PCP2")
        w.u32be(0x10)
        w.u32be(UInt32(length))
        w.u32be(cue.hotCue)
        w.u8(cue.isLoop ? 2 : 1)
        w.u8(0x00)
        w.u8(0x03)
        w.u8(0xE8)
        w.u32be(cue.timeMillis)
        w.u32be(cue.isLoop ? cue.loopTimeMillis : ANLZCue.noLoop)
        w.u8(cue.colorId)
        w.append(unknown)
        w.u16be(cue.loopNumerator)
        w.u16be(cue.loopDenominator)
        w.u32be(UInt32(comment.count))
        w.append(comment)
        w.u8(cue.colorCode)
        w.u8(cue.colorRed)
        w.u8(cue.colorGreen)
        w.u8(cue.colorBlue)
        w.append(cue.extendedTrailer)
    }

    static func encodeSongStructure(_ s: ANLZSongStructure, into out: inout DJByteWriter) {
        var t = DJByteWriter()
        t.fourCC("PSSI")
        t.u32be(32)
        t.u32be(UInt32(32 + 24 * s.phrases.count))
        t.u16be(s.version)
        t.u16be(24)
        t.u16be(UInt16(clamping: s.phrases.count))
        t.u16be(s.mood)
        t.append(Array((s.unknown1 + [UInt8](repeating: 0, count: 6)).prefix(6)))
        t.u16be(s.endBeat)
        t.u16be(s.unknown2)
        t.u8(s.bank)
        t.u8(s.unknown3)
        for p in s.phrases {
            let u = (p.unknownBytes + [UInt8](repeating: 0, count: 5)).prefix(5).map { $0 }
            t.u16be(p.index)
            t.u16be(p.beat)
            t.u16be(p.kind)
            t.u8(u[0]); t.u8(p.k1)
            t.u8(u[1]); t.u8(p.k2)
            t.u8(u[2]); t.u8(p.b)
            t.u16be(p.beat2)
            t.u16be(p.beat3)
            t.u16be(p.beat4)
            t.u8(u[3]); t.u8(p.k3)
            t.u8(u[4]); t.u8(p.fill)
            t.u16be(p.beatFill)
        }
        if s.masked {
            applySongStructureMask(&t.bytes, version: s.version, entryCount: UInt16(clamping: s.phrases.count))
        }
        out.append(t.bytes)
    }
}
