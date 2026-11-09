import Foundation

struct PDBPageSummary: Equatable, Sendable {
    var index: UInt32
    var type: UInt32
    var nextPage: UInt32
    var isIndexPage: Bool
    var flags: UInt8
    var slotCount: Int
    var presentCount: Int
    var freeSize: Int
    var usedSize: Int
    var rowOffsets: [Int]
}

struct PDBReadResult: Sendable {
    var database: PDBDatabase
    var pages: [UInt32: [PDBPageSummary]]
    var issues: [String]
}

struct PDBExtReadResult: Sendable {
    var database: PDBExtDatabase
    var issues: [String]
}

enum PDBReader {
    static let pageHeaderSize = 0x28
    static let rowGroupSize = 0x24
    static let maxTables = 64

    static func read(_ data: Data) throws -> PDBReadResult {
        try read(DJByteReader(data))
    }

    static func read(_ reader: DJByteReader) throws -> PDBReadResult {
        let header = try readHeader(reader)
        var db = PDBDatabase()
        db.pageSize = header.pageSize
        db.tables = header.tables
        db.sequence = header.sequence
        var issues: [String] = []
        var pages: [UInt32: [PDBPageSummary]] = [:]

        for table in header.tables {
            let walked = walk(reader, pageSize: header.pageSize, table: table, issues: &issues)
            pages[table.type] = walked.map(\.summary)
            for page in walked {
                for offset in page.summary.rowOffsets {
                    do {
                        try decodeRow(type: table.type, page: page.reader, offset: offset, into: &db)
                    } catch {
                        issues.append("table \(table.type) page \(page.summary.index) row at \(offset): \(error)")
                    }
                }
            }
        }
        return PDBReadResult(database: db, pages: pages, issues: issues)
    }

    static func readExt(_ data: Data) throws -> PDBExtReadResult {
        let reader = DJByteReader(data)
        let header = try readHeader(reader)
        var db = PDBExtDatabase()
        db.pageSize = header.pageSize
        db.tables = header.tables
        var issues: [String] = []
        for table in header.tables {
            for page in walk(reader, pageSize: header.pageSize, table: table, issues: &issues) {
                for offset in page.summary.rowOffsets {
                    do {
                        if table.type == PDBExtTableType.tags.rawValue {
                            db.tags.append(try decodeTag(page.reader, offset))
                        } else {
                            let end = nextRowBoundary(page.summary, after: offset)
                            db.rawRows[table.type, default: []].append(try page.reader.slice(offset, end - offset))
                        }
                    } catch {
                        issues.append("ext table \(table.type) row at \(offset): \(error)")
                    }
                }
            }
        }
        return PDBExtReadResult(database: db, issues: issues)
    }

    // MARK: - Header and page walking

    struct Header {
        var pageSize: Int
        var tables: [PDBTableInfo]
        var nextUnusedPage: UInt32
        var sequence: UInt32
    }

    static func readHeader(_ reader: DJByteReader) throws -> Header {
        guard try reader.u32le(0) == 0 else { throw DJMediaFormatError.badMagic("export.pdb header") }
        let pageSize = Int(try reader.u32le(4))
        guard pageSize >= 0x200, pageSize <= 0x10000, pageSize & (pageSize - 1) == 0 else {
            throw DJMediaFormatError.malformed("page size \(pageSize)")
        }
        let tableCount = Int(try reader.u32le(8))
        guard tableCount > 0, tableCount <= maxTables, 0x1C + tableCount * 16 <= pageSize else {
            throw DJMediaFormatError.malformed("table count \(tableCount)")
        }
        var tables: [PDBTableInfo] = []
        for i in 0 ..< tableCount {
            let o = 0x1C + i * 16
            tables.append(PDBTableInfo(
                type: try reader.u32le(o),
                emptyCandidate: try reader.u32le(o + 4),
                firstPage: try reader.u32le(o + 8),
                lastPage: try reader.u32le(o + 12)
            ))
        }
        return Header(
            pageSize: pageSize,
            tables: tables,
            nextUnusedPage: try reader.u32le(0x0C),
            sequence: try reader.u32le(0x14)
        )
    }

    struct WalkedPage {
        var summary: PDBPageSummary
        var reader: DJByteReader
    }

    static func walk(_ reader: DJByteReader, pageSize: Int, table: PDBTableInfo, issues: inout [String]) -> [WalkedPage] {
        var out: [WalkedPage] = []
        var visited = Set<UInt32>()
        var index = table.firstPage
        let pageCount = reader.count / pageSize
        while true {
            guard !visited.contains(index) else {
                issues.append("table \(table.type): page chain loops at \(index)")
                break
            }
            visited.insert(index)
            guard index > 0, Int(index) < pageCount else {
                issues.append("table \(table.type): page \(index) is outside the file")
                break
            }
            let start = Int(index) * pageSize
            guard let bytes = try? reader.slice(start, pageSize) else { break }
            let page = DJByteReader(bytes)
            do {
                let summary = try summarise(page, pageSize: pageSize)
                if summary.type != table.type {
                    issues.append("table \(table.type): page \(index) has type \(summary.type)")
                    break
                }
                if summary.index != index {
                    issues.append("table \(table.type): page \(index) says it is page \(summary.index)")
                }
                out.append(WalkedPage(summary: summary, reader: page))
                if index == table.lastPage { break }
                index = summary.nextPage
            } catch {
                issues.append("table \(table.type): page \(index): \(error)")
                break
            }
        }
        return out
    }

    static func summarise(_ page: DJByteReader, pageSize: Int) throws -> PDBPageSummary {
        let flags = try page.u8(0x1B)
        let counts = try page.u24le(0x18)
        let slotCount = Int(counts & 0x1FFF)
        let presentCount = Int(counts >> 13)
        let isIndex = flags & 0x40 != 0
        var offsets: [Int] = []
        if !isIndex, slotCount > 0 {
            let groups = (slotCount + 15) / 16
            guard groups * rowGroupSize <= pageSize - pageHeaderSize else {
                throw DJMediaFormatError.malformed("row directory with \(slotCount) slots does not fit")
            }
            for group in 0 ..< groups {
                let base = pageSize - group * rowGroupSize
                let presence = try page.u16le(base - 4)
                let inGroup = min(16, slotCount - group * 16)
                for i in 0 ..< inGroup where presence & (1 << UInt16(i)) != 0 {
                    let offset = pageHeaderSize + Int(try page.u16le(base - 6 - 2 * i))
                    guard offset < pageSize else {
                        throw DJMediaFormatError.malformed("row offset \(offset) beyond page")
                    }
                    offsets.append(offset)
                }
            }
        }
        return PDBPageSummary(
            index: try page.u32le(0x04),
            type: try page.u32le(0x08),
            nextPage: try page.u32le(0x0C),
            isIndexPage: isIndex,
            flags: flags,
            slotCount: slotCount,
            presentCount: presentCount,
            freeSize: Int(try page.u16le(0x1C)),
            usedSize: Int(try page.u16le(0x1E)),
            rowOffsets: offsets
        )
    }

    static func nextRowBoundary(_ summary: PDBPageSummary, after offset: Int) -> Int {
        let later = summary.rowOffsets.filter { $0 > offset }.min()
        return later ?? max(offset, pageHeaderSize + summary.usedSize)
    }

    // MARK: - Rows

    static func decodeRow(type: UInt32, page: DJByteReader, offset o: Int, into db: inout PDBDatabase) throws {
        guard let table = PDBTableType(rawValue: type) else {
            db.rawRows[type, default: []].append(try page.slice(o, min(64, page.count - o)))
            return
        }
        switch table {
        case .tracks:
            db.tracks.append(try decodeTrack(page, o))
        case .genres:
            db.genres.append(PDBNamedRow(id: try page.u32le(o), name: try DeviceSQLString.decode(page, at: o + 4)))
        case .labels:
            db.labels.append(PDBNamedRow(id: try page.u32le(o), name: try DeviceSQLString.decode(page, at: o + 4)))
        case .historyPlaylists:
            db.historyPlaylists.append(PDBNamedRow(id: try page.u32le(o), name: try DeviceSQLString.decode(page, at: o + 4)))
        case .artists:
            let subtype = try page.u16le(o)
            let nameOffset = subtype & 0x04 != 0 ? Int(try page.u16le(o + 0x0A)) : Int(try page.u8(o + 0x09))
            db.artists.append(PDBArtist(id: try page.u32le(o + 4), name: try DeviceSQLString.decode(page, at: o + nameOffset)))
        case .albums:
            let subtype = try page.u16le(o)
            let nameOffset = subtype & 0x04 != 0 ? Int(try page.u16le(o + 0x16)) : Int(try page.u8(o + 0x15))
            db.albums.append(PDBAlbum(
                id: try page.u32le(o + 0x0C),
                name: try DeviceSQLString.decode(page, at: o + nameOffset),
                artistId: try page.u32le(o + 0x08)
            ))
        case .keys:
            db.keys.append(PDBKey(id: try page.u32le(o), name: try DeviceSQLString.decode(page, at: o + 8)))
        case .colors:
            db.colors.append(PDBColor(id: try page.u16le(o + 5), name: try DeviceSQLString.decode(page, at: o + 8)))
        case .playlistTree:
            db.playlistTree.append(PDBPlaylistNode(
                id: try page.u32le(o + 0x0C),
                parentId: try page.u32le(o),
                sortOrder: try page.u32le(o + 0x08),
                isFolder: try page.u32le(o + 0x10) != 0,
                name: try DeviceSQLString.decode(page, at: o + 0x14)
            ))
        case .playlistEntries:
            db.playlistEntries.append(PDBPlaylistEntry(
                entryIndex: try page.u32le(o), trackId: try page.u32le(o + 4), playlistId: try page.u32le(o + 8)
            ))
        case .historyEntries:
            db.historyEntries.append(PDBHistoryEntry(
                trackId: try page.u32le(o), playlistId: try page.u32le(o + 4), entryIndex: try page.u32le(o + 8)
            ))
        case .artwork:
            db.artwork.append(PDBArtwork(id: try page.u32le(o), path: try DeviceSQLString.decode(page, at: o + 4)))
        case .columns:
            db.columns.append(PDBColumn(
                id: try page.u16le(o), code: try page.u16le(o + 2), name: try DeviceSQLString.decode(page, at: o + 4)
            ))
        case .menuItems, .unknown18:
            db.rawRows[type, default: []].append(try page.slice(o, 8))
        case .history:
            db.rawRows[type, default: []].append(try page.slice(o, min(40, page.count - o)))
        case .unknown9, .unknown10, .unknown14, .unknown15:
            db.rawRows[type, default: []].append(try page.slice(o, min(16, page.count - o)))
        }
    }

    static func decodeTrack(_ page: DJByteReader, _ o: Int) throws -> PDBTrack {
        try page.check(o, PDBTrack.headerSize)
        var t = PDBTrack(id: try page.u32le(o + 0x48))
        t.subtype = try page.u16le(o)
        t.bitmask = try page.u32le(o + 0x04)
        t.sampleRate = try page.u32le(o + 0x08)
        t.composerId = try page.u32le(o + 0x0C)
        t.fileSize = try page.u32le(o + 0x10)
        t.unknown2 = try page.u32le(o + 0x14)
        t.unknown3 = try page.u16le(o + 0x18)
        t.unknown4 = try page.u16le(o + 0x1A)
        t.artworkId = try page.u32le(o + 0x1C)
        t.keyId = try page.u32le(o + 0x20)
        t.originalArtistId = try page.u32le(o + 0x24)
        t.labelId = try page.u32le(o + 0x28)
        t.remixerId = try page.u32le(o + 0x2C)
        t.bitrate = try page.u32le(o + 0x30)
        t.trackNumber = try page.u32le(o + 0x34)
        t.tempo = try page.u32le(o + 0x38)
        t.genreId = try page.u32le(o + 0x3C)
        t.albumId = try page.u32le(o + 0x40)
        t.artistId = try page.u32le(o + 0x44)
        t.discNumber = try page.u16le(o + 0x4C)
        t.playCount = try page.u16le(o + 0x4E)
        t.year = try page.u16le(o + 0x50)
        t.sampleDepth = try page.u16le(o + 0x52)
        t.duration = try page.u16le(o + 0x54)
        t.unknown5 = try page.u16le(o + 0x56)
        t.colorId = try page.u8(o + 0x58)
        t.rating = try page.u8(o + 0x59)
        t.fileType = try page.u16le(o + 0x5A)
        t.unknown7 = try page.u16le(o + 0x5C)
        var strings: [String] = []
        for i in 0 ..< PDBTrack.stringCount {
            let rel = Int(try page.u16le(o + PDBTrack.fixedSize + 2 * i))
            strings.append(try DeviceSQLString.decode(page, at: o + rel))
        }
        t.strings = strings
        return t
    }

    static func decodeTag(_ page: DJByteReader, _ o: Int) throws -> PDBTag {
        let subtype = try page.u16le(o)
        let nameOffset = subtype & 0x04 != 0 ? Int(try page.u16le(o + 0x1E)) : Int(try page.u8(o + 0x1D))
        return PDBTag(
            id: try page.u32le(o + 0x14),
            categoryId: try page.u32le(o + 0x0C),
            position: try page.u32le(o + 0x10),
            isCategory: try page.u32le(o + 0x18) != 0,
            name: try DeviceSQLString.decode(page, at: o + nameOffset)
        )
    }
}
