import Foundation

enum DJMediaFormatError: Error, Equatable, Sendable {
    case truncated(offset: Int, needed: Int)
    case badMagic(String)
    case malformed(String)
    case unknownStringKind(UInt8, offset: Int)
    case stringTooLong(Int)
    case rowTooLarge(table: UInt32, bytes: Int)
    case valueOutOfRange(String)
}

struct DJByteReader: Sendable {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    var count: Int { bytes.count }

    func has(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= bytes.count && length <= bytes.count - offset
    }

    func check(_ offset: Int, _ length: Int) throws {
        guard has(offset, length) else { throw DJMediaFormatError.truncated(offset: offset, needed: length) }
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return bytes[offset]
    }

    func u16le(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32le(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    func u24le(_ offset: Int) throws -> UInt32 {
        try check(offset, 3)
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    func u16be(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func u32be(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        try check(offset, length)
        return Array(bytes[offset ..< offset + length])
    }

    func fourCC(_ offset: Int) throws -> String {
        let raw = try slice(offset, 4)
        return String(decoding: raw.map { (32 ... 126).contains($0) ? $0 : 0x3F }, as: UTF8.self)
    }
}

struct DJByteWriter: Sendable {
    var bytes: [UInt8] = []

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16le(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32le(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    mutating func u16be(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    mutating func u32be(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }
    mutating func zeros(_ n: Int) { if n > 0 { bytes.append(contentsOf: repeatElement(0, count: n)) } }
    mutating func pad(to length: Int) { zeros(length - bytes.count) }
    mutating func fourCC(_ code: String) {
        let raw = Array(code.utf8.prefix(4))
        bytes.append(contentsOf: raw)
        zeros(4 - raw.count)
    }

    mutating func setU16le(_ v: UInt16, at offset: Int) {
        bytes[offset] = UInt8(v & 0xFF)
        bytes[offset + 1] = UInt8(v >> 8)
    }

    mutating func setU32le(_ v: UInt32, at offset: Int) {
        for i in 0 ..< 4 { bytes[offset + i] = UInt8((v >> UInt32(8 * i)) & 0xFF) }
    }

    mutating func setU32be(_ v: UInt32, at offset: Int) {
        for i in 0 ..< 4 { bytes[offset + i] = UInt8((v >> UInt32(24 - 8 * i)) & 0xFF) }
    }
}

enum DJAlign {
    static func four(_ n: Int) -> Int { (n + 3) & ~3 }
}

// MARK: - DeviceSQL strings

enum DeviceSQLString {
    static let shortASCIILimit = 126

    static func encode(_ text: String) throws -> [UInt8] {
        let isASCII = text.utf8.allSatisfy { $0 < 0x80 }
        if isASCII {
            let raw = Array(text.utf8)
            if raw.count <= shortASCIILimit {
                return [UInt8((raw.count + 1) * 2 + 1)] + raw
            }
            guard raw.count + 4 <= 0x7FFF else { throw DJMediaFormatError.stringTooLong(raw.count) }
            var w = DJByteWriter(capacity: raw.count + 4)
            w.u8(0x40)
            w.u16le(UInt16(raw.count + 4))
            w.u8(0)
            w.append(raw)
            return w.bytes
        }
        var payload: [UInt8] = []
        payload.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            payload.append(UInt8(unit & 0xFF))
            payload.append(UInt8(unit >> 8))
        }
        guard payload.count + 4 <= 0x7FFF else { throw DJMediaFormatError.stringTooLong(payload.count) }
        var w = DJByteWriter(capacity: payload.count + 4)
        w.u8(0x90)
        w.u16le(UInt16(payload.count + 4))
        w.u8(0)
        w.append(payload)
        return w.bytes
    }

    static func encodeISRC(_ isrc: String) throws -> [UInt8] {
        guard !isrc.isEmpty else { return try encode("") }
        let raw = Array(isrc.utf8.filter { $0 < 0x80 })
        guard raw.count + 6 <= 0x7FFF else { throw DJMediaFormatError.stringTooLong(raw.count) }
        var w = DJByteWriter(capacity: raw.count + 6)
        w.u8(0x90)
        w.u16le(UInt16(raw.count + 6))
        w.u8(0)
        w.u8(0x03)
        w.append(raw)
        w.u8(0)
        return w.bytes
    }

    static func decode(_ reader: DJByteReader, at offset: Int) throws -> String {
        let kind = try reader.u8(offset)
        if kind & 1 == 1 {
            let length = Int(kind >> 1) - 1
            guard length >= 0 else { return "" }
            return String(decoding: try reader.slice(offset + 1, length), as: UTF8.self)
        }
        let total = Int(try reader.u16le(offset + 1))
        guard total >= 4 else { throw DJMediaFormatError.malformed("string length \(total) at \(offset)") }
        let payload = try reader.slice(offset + 4, total - 4)
        switch kind {
        case 0x40:
            return String(decoding: payload, as: UTF8.self)
        case 0x20:
            return String(decoding: payload, as: UTF8.self)
        case 0x90:
            if payload.first == 0x03 {
                return String(decoding: payload.dropFirst().prefix { $0 != 0 }, as: UTF8.self)
            }
            return utf16(payload, littleEndian: true)
        case 0x10:
            return utf16(payload, littleEndian: false)
        default:
            throw DJMediaFormatError.unknownStringKind(kind, offset: offset)
        }
    }

    static func utf16(_ payload: [UInt8], littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(payload.count / 2)
        var i = 0
        while i + 1 < payload.count {
            let a = UInt16(payload[i]), b = UInt16(payload[i + 1])
            units.append(littleEndian ? (a | b << 8) : (a << 8 | b))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func utf16BigEndianTerminated(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf16.count * 2 + 2)
        for unit in text.utf16 {
            out.append(UInt8(unit >> 8))
            out.append(UInt8(unit & 0xFF))
        }
        out.append(0)
        out.append(0)
        return out
    }

    static func decodeUTF16BigEndianTerminated(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < bytes.count {
            let unit = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
