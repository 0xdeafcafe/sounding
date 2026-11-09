import Compression
import CoreFoundation
import Foundation

enum SoundingDataKind: UInt16, Sendable {
    case manifest = 1
    case analysisRecord = 2
    case journalSegment = 3
    case setlist = 4
}

enum SoundingDataFormatError: Error, Equatable {
    case notSoundingData
    case unsupportedVersion(UInt16)
    case wrongKind(UInt16)
    case corrupt
}

enum SoundingDataFormat {
    static let version: UInt16 = 1
    static let headerSize = 16
    private static let magic: [UInt8] = [0x53, 0x4E, 0x44, 0x47]
    private static let compressedFlag: UInt16 = 1

    static func wrap(_ body: Data, kind: SoundingDataKind) -> Data {
        let compressed = body.count > 64 ? lzfse(body) : nil
        let useCompressed = compressed.map { $0.count < body.count } ?? false
        var out = Data(capacity: headerSize + (useCompressed ? compressed!.count : body.count))
        out.append(contentsOf: magic)
        out.appendLittleEndian(version)
        out.appendLittleEndian(kind.rawValue)
        out.appendLittleEndian(useCompressed ? compressedFlag : 0)
        out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt32(body.count))
        out.append(useCompressed ? compressed! : body)
        return out
    }

    static func unwrap(_ data: Data, expecting kind: SoundingDataKind) throws -> Data {
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { throw SoundingDataFormatError.notSoundingData }
        let start = data.startIndex
        let fileVersion = data.readLittleEndian(UInt16.self, at: start + 4)
        let fileKind = data.readLittleEndian(UInt16.self, at: start + 6)
        let flags = data.readLittleEndian(UInt16.self, at: start + 8)
        let rawLength = Int(data.readLittleEndian(UInt32.self, at: start + 12))
        guard fileVersion >= 1, fileVersion <= version else { throw SoundingDataFormatError.unsupportedVersion(fileVersion) }
        guard fileKind == kind.rawValue else { throw SoundingDataFormatError.wrongKind(fileKind) }
        let body = data.subdata(in: (start + headerSize)..<data.endIndex)
        if flags & compressedFlag == 0 {
            guard body.count == rawLength else { throw SoundingDataFormatError.corrupt }
            return body
        }
        guard let plain = unlzfse(body, rawLength: rawLength) else { throw SoundingDataFormatError.corrupt }
        return plain
    }

    static func kind(of data: Data) -> SoundingDataKind? {
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return nil }
        return SoundingDataKind(rawValue: data.readLittleEndian(UInt16.self, at: data.startIndex + 6))
    }

    static func encode<T: Encodable>(_ value: T, kind: SoundingDataKind) throws -> Data {
        let json = try jsonEncoder.encode(value)
        return wrap(try PackedJSON.pack(json), kind: kind)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, kind: SoundingDataKind) throws -> T {
        let json = try PackedJSON.unpack(try unwrap(data, expecting: kind))
        return try jsonDecoder.decode(T.self, from: json)
    }

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()

    static func lzfse(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, srcBase, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    static func unlzfse(_ data: Data, rawLength: Int) -> Data? {
        guard rawLength > 0, !data.isEmpty else { return rawLength == 0 ? Data() : nil }
        var output = Data(count: rawLength)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, rawLength, srcBase, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        return written == rawLength ? output : nil
    }
}

// MARK: - Packed JSON

enum PackedJSON {
    static let packedArrayMinimum = 8
    static let halfPrecisionMinimum = 64
    static let halfPrecisionLimit = 2.0
    static let singlePrecisionLimit = 1_000_000.0
    static let singlePrecisionTolerance = 1e-4

    private enum Tag: UInt8 {
        case null = 0
        case falseValue = 1
        case trueValue = 2
        case integer = 3
        case double = 4
        case string = 5
        case array = 6
        case object = 7
        case bytes = 8
        case halves = 9
        case singles = 10
        case integers = 11
        case doubles = 12
    }

    static func pack(_ json: Data) throws -> Data {
        try packObject(try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]))
    }

    static func parse(_ json: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
    }

    static func packObject(_ object: Any) throws -> Data {
        var writer = Writer()
        try writer.write(object)
        return writer.data
    }

    static func unpack(_ packed: Data) throws -> Data {
        let object = try unpackObject(packed)
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func unpackObject(_ packed: Data) throws -> Any {
        var reader = Reader(data: packed)
        let object = try reader.read()
        guard reader.isAtEnd else { throw SoundingDataFormatError.corrupt }
        return object
    }

    static func serialize(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func canonical(_ json: Data) -> Data? {
        guard let packed = try? pack(json) else { return nil }
        return try? unpack(packed)
    }

    // MARK: Writer

    private struct Writer {
        var data = Data()

        mutating func write(_ value: Any) throws {
            switch value {
            case is NSNull:
                data.append(Tag.null.rawValue)
            case let number as NSNumber:
                writeScalar(number)
            case let string as String:
                data.append(Tag.string.rawValue)
                writeString(string)
            case let array as [Any]:
                if let numbers = PackedJSON.numericArray(array) {
                    writeNumbers(numbers)
                } else {
                    data.append(Tag.array.rawValue)
                    writeVarint(UInt64(array.count))
                    for element in array { try write(element) }
                }
            case let object as [String: Any]:
                data.append(Tag.object.rawValue)
                writeVarint(UInt64(object.count))
                for key in object.keys.sorted() {
                    writeString(key)
                    try write(object[key]!)
                }
            default:
                throw SoundingDataFormatError.corrupt
            }
        }

        private mutating func writeScalar(_ number: NSNumber) {
            if PackedJSON.isBoolean(number) {
                data.append(number.boolValue ? Tag.trueValue.rawValue : Tag.falseValue.rawValue)
                return
            }
            if let integer = PackedJSON.exactInteger(number) {
                data.append(Tag.integer.rawValue)
                writeVarint(zigzag(integer))
            } else {
                data.append(Tag.double.rawValue)
                data.appendLittleEndian(number.doubleValue.bitPattern)
            }
        }

        private mutating func writeNumbers(_ numbers: [NSNumber]) {
            let integers = numbers.compactMap(PackedJSON.exactInteger)
            if integers.count == numbers.count {
                if integers.allSatisfy({ $0 >= 0 && $0 <= 255 }) {
                    data.append(Tag.bytes.rawValue)
                    writeVarint(UInt64(integers.count))
                    data.append(contentsOf: integers.map { UInt8($0) })
                } else {
                    data.append(Tag.integers.rawValue)
                    writeVarint(UInt64(integers.count))
                    for integer in integers { writeVarint(zigzag(integer)) }
                }
                return
            }
            let doubles = numbers.map(\.doubleValue)
            switch PackedJSON.precision(for: doubles) {
            case .half:
                data.append(Tag.halves.rawValue)
                writeVarint(UInt64(doubles.count))
                for value in doubles { data.appendLittleEndian(HalfFloat.bits(Float(value))) }
            case .single:
                data.append(Tag.singles.rawValue)
                writeVarint(UInt64(doubles.count))
                for value in doubles { data.appendLittleEndian(Float(value).bitPattern) }
            case .double:
                data.append(Tag.doubles.rawValue)
                writeVarint(UInt64(doubles.count))
                for value in doubles { data.appendLittleEndian(value.bitPattern) }
            }
        }

        private mutating func writeString(_ string: String) {
            let bytes = Array(string.utf8)
            writeVarint(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }

        private mutating func writeVarint(_ value: UInt64) {
            var remaining = value
            while remaining >= 0x80 {
                data.append(UInt8(remaining & 0x7F) | 0x80)
                remaining >>= 7
            }
            data.append(UInt8(remaining))
        }

        private func zigzag(_ value: Int64) -> UInt64 {
            UInt64(bitPattern: (value << 1) ^ (value >> 63))
        }
    }

    // MARK: Reader

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(data: Data) {
            bytes = [UInt8](data)
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func read() throws -> Any {
            guard let tag = Tag(rawValue: try byte()) else { throw SoundingDataFormatError.corrupt }
            switch tag {
            case .null: return NSNull()
            case .falseValue: return false
            case .trueValue: return true
            case .integer: return NSNumber(value: unzigzag(try varint()))
            case .double: return NSNumber(value: Double(bitPattern: try fixed(UInt64.self)))
            case .string: return try string()
            case .array:
                let count = try count()
                var out: [Any] = []
                out.reserveCapacity(count)
                for _ in 0..<count { out.append(try read()) }
                return out
            case .object:
                let count = try count()
                var out: [String: Any] = [:]
                out.reserveCapacity(count)
                for _ in 0..<count {
                    let key = try string()
                    out[key] = try read()
                }
                return out
            case .bytes:
                let count = try count()
                guard offset + count <= bytes.count else { throw SoundingDataFormatError.corrupt }
                let slice = bytes[offset..<(offset + count)].map { NSNumber(value: Int($0)) }
                offset += count
                return slice
            case .halves:
                let count = try count()
                var out: [NSNumber] = []
                out.reserveCapacity(count)
                for _ in 0..<count { out.append(NSNumber(value: Double(HalfFloat.float(try fixed(UInt16.self))))) }
                return out
            case .singles:
                let count = try count()
                var out: [NSNumber] = []
                out.reserveCapacity(count)
                for _ in 0..<count { out.append(NSNumber(value: Double(Float(bitPattern: try fixed(UInt32.self))))) }
                return out
            case .integers:
                let count = try count()
                var out: [NSNumber] = []
                out.reserveCapacity(count)
                for _ in 0..<count { out.append(NSNumber(value: unzigzag(try varint()))) }
                return out
            case .doubles:
                let count = try count()
                var out: [NSNumber] = []
                out.reserveCapacity(count)
                for _ in 0..<count { out.append(NSNumber(value: Double(bitPattern: try fixed(UInt64.self)))) }
                return out
            }
        }

        private mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw SoundingDataFormatError.corrupt }
            defer { offset += 1 }
            return bytes[offset]
        }

        private mutating func count() throws -> Int {
            let value = try varint()
            guard value <= UInt64(bytes.count - offset) * 8 + 8 else { throw SoundingDataFormatError.corrupt }
            return Int(value)
        }

        private mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let next = try byte()
                result |= UInt64(next & 0x7F) << shift
                if next & 0x80 == 0 { return result }
                shift += 7
                guard shift < 64 else { throw SoundingDataFormatError.corrupt }
            }
        }

        private mutating func fixed<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { throw SoundingDataFormatError.corrupt }
            var value: T = 0
            for index in 0..<size { value |= T(bytes[offset + index]) << (8 * index) }
            offset += size
            return value
        }

        private mutating func string() throws -> String {
            let length = try count()
            guard offset + length <= bytes.count else { throw SoundingDataFormatError.corrupt }
            defer { offset += length }
            guard let text = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else { throw SoundingDataFormatError.corrupt }
            return text
        }

        private func unzigzag(_ value: UInt64) -> Int64 {
            Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
        }
    }

    // MARK: Number rules

    enum Precision: Equatable {
        case half
        case single
        case double
    }

    static func precision(for values: [Double]) -> Precision {
        guard values.allSatisfy(\.isFinite) else { return .double }
        if values.count >= halfPrecisionMinimum, values.allSatisfy({ abs($0) <= halfPrecisionLimit }) {
            return .half
        }
        let fitsSingle = values.allSatisfy { value in
            let rounded = Double(Float(value))
            return rounded == value || (abs(value) <= singlePrecisionLimit && abs(rounded - value) <= singlePrecisionTolerance)
        }
        return fitsSingle ? .single : .double
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func exactInteger(_ number: NSNumber) -> Int64? {
        if isBoolean(number) { return nil }
        if !CFNumberIsFloatType(number as CFNumber) { return number.int64Value }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        if value == 0, value.sign == .minus { return nil }
        return Int64(value)
    }

    fileprivate static func numericArray(_ array: [Any]) -> [NSNumber]? {
        guard array.count >= packedArrayMinimum else { return nil }
        var numbers: [NSNumber] = []
        numbers.reserveCapacity(array.count)
        for element in array {
            guard let number = element as? NSNumber, !isBoolean(number) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

// MARK: - Half precision

enum HalfFloat {
    static func bits(_ value: Float) -> UInt16 {
        let raw = value.bitPattern
        let sign = UInt16((raw >> 16) & 0x8000)
        let exponent = Int((raw >> 23) & 0xFF)
        var mantissa = raw & 0x7F_FFFF
        if exponent == 0xFF {
            return sign | 0x7C00 | (mantissa != 0 ? 0x200 : 0)
        }
        let unbiased = exponent - 127 + 15
        if unbiased >= 0x1F {
            return sign | 0x7C00
        }
        if unbiased <= 0 {
            guard unbiased >= -10 else { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - unbiased)
            var half = mantissa >> shift
            let remainder = mantissa & ((1 << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && (half & 1) == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(unbiased << 10) | (mantissa >> 13)
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && (half & 1) == 1) { half += 1 }
        return sign | UInt16(truncatingIfNeeded: half)
    }

    static func float(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            guard mantissa != 0 else { return Float(bitPattern: sign) }
            let magnitude = Float(mantissa) / 1024 / 16384
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | (mantissa << 13))
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at index: Index) -> T {
        var value: T = 0
        for offset in 0..<MemoryLayout<T>.size {
            value |= T(self[index + offset]) << (8 * offset)
        }
        return value
    }
}
