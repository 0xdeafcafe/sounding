import Foundation

struct PDBEncodedRow: Sendable {
    var bytes: [UInt8]
    var allocation: Int
    var indexShiftOffset: Int?
}

enum PDBWriter {
    static let pageSize = 4096
    static let headerSize = PDBReader.pageHeaderSize
    static let indexPageMagic: UInt16 = 0x03EC
    static let emptyIndexEntry: UInt32 = 0x1FFF_FFF8
    static let indexEntryCapacity = 1004

    static func write(_ db: PDBDatabase) throws -> Data {
        var rows: [UInt32: [PDBEncodedRow]] = [:]
        for type in PDBTableType.allCases {
            rows[type.rawValue] = try encodeRows(of: type, in: db)
        }
        return try assemble(tableTypes: PDBTableType.allCases.map(\.rawValue), rows: rows)
    }

    static func writeExt(_ db: PDBExtDatabase) throws -> Data {
        var rows: [UInt32: [PDBEncodedRow]] = [:]
        rows[PDBExtTableType.tags.rawValue] = try db.tags.map(encodeTag)
        for (type, raw) in db.rawRows where type != PDBExtTableType.tags.rawValue {
            rows[type] = raw.map { PDBEncodedRow(bytes: $0, allocation: DJAlign.four($0.count), indexShiftOffset: nil) }
        }
        return try assemble(tableTypes: Array(0 ... 8), rows: rows)
    }

    static func directoryBytes(_ slots: Int) -> Int {
        slots == 0 ? 0 : 2 * slots + 4 * ((slots + 15) / 16)
    }

    // MARK: - Page layout

    struct DataPage {
        var index: UInt32 = 0
        var heap: [UInt8] = []
        var offsets: [Int] = []
    }

    static func paginate(_ rows: [PDBEncodedRow], table: UInt32) throws -> [DataPage] {
        var pages: [DataPage] = []
        var current = DataPage()
        let capacity = pageSize - headerSize
        for row in rows {
            guard row.allocation + directoryBytes(1) <= capacity, row.bytes.count <= row.allocation else {
                throw DJMediaFormatError.rowTooLarge(table: table, bytes: row.allocation)
            }
            if current.heap.count + row.allocation + directoryBytes(current.offsets.count + 1) > capacity {
                pages.append(current)
                current = DataPage()
            }
            var bytes = row.bytes
            if let shiftAt = row.indexShiftOffset, shiftAt + 1 < bytes.count {
                let shift = UInt16(truncatingIfNeeded: 0x20 * current.offsets.count)
                bytes[shiftAt] = UInt8(shift & 0xFF)
                bytes[shiftAt + 1] = UInt8(shift >> 8)
            }
            current.offsets.append(current.heap.count)
            current.heap.append(contentsOf: bytes)
            current.heap.append(contentsOf: repeatElement(0, count: row.allocation - bytes.count))
        }
        if !current.offsets.isEmpty { pages.append(current) }
        return pages
    }

    static func assemble(tableTypes: [UInt32], rows: [UInt32: [PDBEncodedRow]]) throws -> Data {
        var layouts: [(type: UInt32, indexPage: UInt32, data: [DataPage])] = []
        var nextPage = UInt32(1 + 2 * tableTypes.count)
        for (i, type) in tableTypes.enumerated() {
            var data = try paginate(rows[type] ?? [], table: type)
            for p in data.indices {
                if p == 0 {
                    data[p].index = UInt32(2 + 2 * i)
                } else {
                    data[p].index = nextPage
                    nextPage += 1
                }
            }
            layouts.append((type, UInt32(1 + 2 * i), data))
        }
        var candidates: [UInt32] = []
        for (i, layout) in layouts.enumerated() {
            if layout.data.isEmpty {
                candidates.append(UInt32(2 + 2 * i))
            } else {
                candidates.append(nextPage)
                nextPage += 1
            }
        }
        let nextUnused = nextPage
        let writtenPages = layouts.flatMap { [$0.indexPage] + $0.data.map(\.index) }
        let lastWritten = max(writtenPages.max() ?? 0, UInt32(2 * tableTypes.count))
        var file = [UInt8](repeating: 0, count: (Int(lastWritten) + 1) * pageSize)

        var sequence: UInt32 = 1
        var header = DJByteWriter(capacity: pageSize)
        header.u32le(0)
        header.u32le(UInt32(pageSize))
        header.u32le(UInt32(tableTypes.count))
        header.u32le(nextUnused)
        header.u32le(1)
        header.u32le(0)
        header.u32le(0)
        for (i, layout) in layouts.enumerated() {
            header.u32le(layout.type)
            header.u32le(candidates[i])
            header.u32le(layout.indexPage)
            header.u32le(layout.data.last?.index ?? layout.indexPage)
        }

        for (i, layout) in layouts.enumerated() {
            let firstData = layout.data.first?.index
            let index = indexPage(
                index: layout.indexPage,
                type: layout.type,
                next: firstData ?? candidates[i],
                firstDataPage: firstData
            )
            place(index, at: layout.indexPage, in: &file)
            for (p, page) in layout.data.enumerated() {
                sequence += 1
                let next = p + 1 < layout.data.count ? layout.data[p + 1].index : candidates[i]
                place(dataPage(page, type: layout.type, next: next, generation: sequence), at: page.index, in: &file)
            }
        }
        sequence += 1
        header.setU32le(sequence, at: 0x14)
        file.replaceSubrange(0 ..< header.count, with: header.bytes)
        return Data(file)
    }

    static func place(_ page: [UInt8], at index: UInt32, in file: inout [UInt8]) {
        let start = Int(index) * pageSize
        file.replaceSubrange(start ..< start + pageSize, with: page)
    }

    static func indexPage(index: UInt32, type: UInt32, next: UInt32, firstDataPage: UInt32?) -> [UInt8] {
        var w = DJByteWriter(capacity: pageSize)
        w.u32le(0)
        w.u32le(index)
        w.u32le(type)
        w.u32le(next)
        w.u32le(1)
        w.u32le(0)
        w.u8(0); w.u8(0); w.u8(0)
        w.u8(0x64)
        w.u16le(0)
        w.u16le(0)
        w.u16le(0x1FFF)
        w.u16le(0x1FFF)
        w.u16le(indexPageMagic)
        w.u16le(0)
        w.u32le(index)
        w.u32le(firstDataPage ?? 0x03FF_FFFF)
        w.u32le(0x03FF_FFFF)
        w.u32le(0)
        w.u16le(0)
        w.u16le(0x1FFF)
        for _ in 0 ..< indexEntryCapacity { w.u32le(emptyIndexEntry) }
        w.pad(to: pageSize)
        return w.bytes
    }

    static func dataPage(_ page: DataPage, type: UInt32, next: UInt32, generation: UInt32) -> [UInt8] {
        let slots = page.offsets.count
        var w = DJByteWriter(capacity: pageSize)
        w.u32le(0)
        w.u32le(page.index)
        w.u32le(type)
        w.u32le(next)
        w.u32le(generation)
        w.u32le(0)
        let counts = UInt32(slots) | UInt32(slots) << 13
        w.u8(UInt8(counts & 0xFF))
        w.u8(UInt8((counts >> 8) & 0xFF))
        w.u8(UInt8((counts >> 16) & 0xFF))
        w.u8(0x24)
        let used = page.heap.count
        w.u16le(UInt16(pageSize - headerSize - used - directoryBytes(slots)))
        w.u16le(UInt16(used))
        w.u16le(UInt16(slots))
        w.u16le(0)
        w.u16le(0)
        w.u16le(0)
        w.append(page.heap)
        w.pad(to: pageSize)
        for group in 0 ..< (slots + 15) / 16 {
            let base = pageSize - group * PDBReader.rowGroupSize
            let inGroup = min(16, slots - group * 16)
            let mask = inGroup == 16 ? UInt16.max : UInt16((1 << inGroup) - 1)
            w.setU16le(mask, at: base - 2)
            w.setU16le(mask, at: base - 4)
            for i in 0 ..< inGroup {
                w.setU16le(UInt16(page.offsets[group * 16 + i]), at: base - 6 - 2 * i)
            }
        }
        return w.bytes
    }

    // MARK: - Row encoding

    static func encodeRows(of type: PDBTableType, in db: PDBDatabase) throws -> [PDBEncodedRow] {
        switch type {
        case .tracks: return try db.tracks.map(encodeTrack)
        case .genres: return try db.genres.map { try idNameRow($0.id, $0.name) }
        case .labels: return try db.labels.map { try idNameRow($0.id, $0.name) }
        case .historyPlaylists: return try db.historyPlaylists.map { try idNameRow($0.id, $0.name) }
        case .artwork: return try db.artwork.map { try idNameRow($0.id, $0.path) }
        case .artists: return try db.artists.map(encodeArtist)
        case .albums: return try db.albums.map(encodeAlbum)
        case .keys:
            return try db.keys.map { key in
                let s = try DeviceSQLString.encode(key.name)
                var w = DJByteWriter()
                w.u32le(key.id)
                w.u32le(key.id)
                w.append(s)
                return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(8 + s.count), indexShiftOffset: nil)
            }
        case .colors:
            return try db.colors.map { color in
                let s = try DeviceSQLString.encode(color.name)
                var w = DJByteWriter()
                w.u32le(0)
                w.u8(UInt8(truncatingIfNeeded: color.id))
                w.u16le(color.id)
                w.u8(0)
                w.append(s)
                return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(8 + s.count), indexShiftOffset: nil)
            }
        case .playlistTree:
            return try db.playlistTree.map { node in
                let s = try DeviceSQLString.encode(node.name)
                var w = DJByteWriter()
                w.u32le(node.parentId)
                w.u32le(0)
                w.u32le(node.sortOrder)
                w.u32le(node.id)
                w.u32le(node.isFolder ? 1 : 0)
                w.append(s)
                return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(20 + s.count), indexShiftOffset: nil)
            }
        case .playlistEntries:
            return db.playlistEntries.map { e in
                var w = DJByteWriter()
                w.u32le(e.entryIndex); w.u32le(e.trackId); w.u32le(e.playlistId)
                return PDBEncodedRow(bytes: w.bytes, allocation: 12, indexShiftOffset: nil)
            }
        case .historyEntries:
            return db.historyEntries.map { e in
                var w = DJByteWriter()
                w.u32le(e.trackId); w.u32le(e.playlistId); w.u32le(e.entryIndex)
                return PDBEncodedRow(bytes: w.bytes, allocation: 12, indexShiftOffset: nil)
            }
        case .columns:
            return try db.columns.map { column in
                var s = try DeviceSQLString.encode(column.name)
                if s.first.map({ $0 & 1 == 1 }) == true {
                    s = forceUTF16(column.name)
                }
                var w = DJByteWriter()
                w.u16le(column.id)
                w.u16le(column.code)
                w.append(s)
                return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(4 + s.count), indexShiftOffset: nil)
            }
        case .menuItems, .unknown18, .history, .unknown9, .unknown10, .unknown14, .unknown15:
            return (db.rawRows[type.rawValue] ?? []).map {
                PDBEncodedRow(bytes: $0, allocation: DJAlign.four($0.count), indexShiftOffset: nil)
            }
        }
    }

    static func forceUTF16(_ text: String) -> [UInt8] {
        var w = DJByteWriter()
        w.u8(0x90)
        w.u16le(UInt16(text.utf16.count * 2 + 4))
        w.u8(0)
        for unit in text.utf16 { w.u16le(unit) }
        return w.bytes
    }

    static func idNameRow(_ id: UInt32, _ name: String) throws -> PDBEncodedRow {
        let s = try DeviceSQLString.encode(name)
        var w = DJByteWriter()
        w.u32le(id)
        w.append(s)
        return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(4 + s.count), indexShiftOffset: nil)
    }

    static func encodeArtist(_ artist: PDBArtist) throws -> PDBEncodedRow {
        let s = try DeviceSQLString.encode(artist.name)
        var w = DJByteWriter()
        w.u16le(0x0060)
        w.u16le(0)
        w.u32le(artist.id)
        w.u8(0x03)
        w.u8(0x0A)
        w.append(s)
        return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(10 + DJAlign.four(s.count)) + 4, indexShiftOffset: 2)
    }

    static func encodeAlbum(_ album: PDBAlbum) throws -> PDBEncodedRow {
        let s = try DeviceSQLString.encode(album.name)
        var w = DJByteWriter()
        w.u16le(0x0080)
        w.u16le(0)
        w.u32le(0)
        w.u32le(album.artistId)
        w.u32le(album.id)
        w.u32le(0)
        w.u8(0x03)
        w.u8(0x16)
        w.append(s)
        return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(22 + DJAlign.four(s.count)) + 4, indexShiftOffset: 2)
    }

    static func encodeTag(_ tag: PDBTag) throws -> PDBEncodedRow {
        let s = try DeviceSQLString.encode(tag.name)
        guard s.count <= 0xE0 else { throw DJMediaFormatError.stringTooLong(s.count) }
        var w = DJByteWriter()
        w.u16le(0x0680)
        w.u16le(0)
        w.u32le(0)
        w.u32le(0)
        w.u32le(tag.categoryId)
        w.u32le(tag.position)
        w.u32le(tag.id)
        w.u8(0); w.u8(0); w.u8(0)
        w.u8(tag.isCategory ? 1 : 0)
        w.u8(0x03)
        w.u8(0x1F)
        w.u8(UInt8(0x1F + s.count))
        w.append(s)
        w.u8(0x03)
        return PDBEncodedRow(bytes: w.bytes, allocation: DJAlign.four(w.count), indexShiftOffset: 2)
    }

    static func encodeTrack(_ t: PDBTrack) throws -> PDBEncodedRow {
        var strings = t.strings
        if strings.count < PDBTrack.stringCount {
            strings += [String](repeating: "", count: PDBTrack.stringCount - strings.count)
        }
        let encoded: [[UInt8]] = try strings.prefix(PDBTrack.stringCount).enumerated().map { i, s in
            i == PDBTrackString.isrc.rawValue ? try DeviceSQLString.encodeISRC(s) : try DeviceSQLString.encode(s)
        }
        var w = DJByteWriter(capacity: 512)
        w.u16le(t.subtype)
        w.u16le(0)
        w.u32le(t.bitmask)
        w.u32le(t.sampleRate)
        w.u32le(t.composerId)
        w.u32le(t.fileSize)
        w.u32le(t.unknown2)
        w.u16le(t.unknown3)
        w.u16le(t.unknown4)
        w.u32le(t.artworkId)
        w.u32le(t.keyId)
        w.u32le(t.originalArtistId)
        w.u32le(t.labelId)
        w.u32le(t.remixerId)
        w.u32le(t.bitrate)
        w.u32le(t.trackNumber)
        w.u32le(t.tempo)
        w.u32le(t.genreId)
        w.u32le(t.albumId)
        w.u32le(t.artistId)
        w.u32le(t.id)
        w.u16le(t.discNumber)
        w.u16le(t.playCount)
        w.u16le(t.year)
        w.u16le(t.sampleDepth)
        w.u16le(t.duration)
        w.u16le(t.unknown5)
        w.u8(t.colorId)
        w.u8(t.rating)
        w.u16le(t.fileType)
        w.u16le(t.unknown7)
        let offsetsAt = w.count
        w.zeros(2 * PDBTrack.stringCount)
        for (i, s) in encoded.enumerated() {
            if s.first.map({ $0 & 1 == 0 }) == true { w.pad(to: DJAlign.four(w.count)) }
            guard w.count <= Int(UInt16.max) else { throw DJMediaFormatError.rowTooLarge(table: 0, bytes: w.count) }
            w.setU16le(UInt16(w.count), at: offsetsAt + 2 * i)
            w.append(s)
        }
        let allocation = PDBTrack.headerSize + encoded.reduce(0) { $0 + DJAlign.four($1.count) } + 4
        return PDBEncodedRow(bytes: w.bytes, allocation: max(allocation, DJAlign.four(w.count)), indexShiftOffset: 2)
    }
}
