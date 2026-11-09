import Foundation

enum PDBTableType: UInt32, CaseIterable, Sendable {
    case tracks = 0
    case genres = 1
    case artists = 2
    case albums = 3
    case labels = 4
    case keys = 5
    case colors = 6
    case playlistTree = 7
    case playlistEntries = 8
    case unknown9 = 9
    case unknown10 = 10
    case historyPlaylists = 11
    case historyEntries = 12
    case artwork = 13
    case unknown14 = 14
    case unknown15 = 15
    case columns = 16
    case menuItems = 17
    case unknown18 = 18
    case history = 19
}

enum PDBExtTableType: UInt32, Sendable {
    case tags = 3
    case tagTracks = 4
}

enum PDBFileType: UInt16, Sendable, CaseIterable {
    case unknown = 0x00
    case mp3 = 0x01
    case m4a = 0x04
    case flac = 0x05
    case wav = 0x0B
    case aiff = 0x0C

    init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "mp3": self = .mp3
        case "m4a", "aac", "mp4": self = .m4a
        case "flac": self = .flac
        case "wav", "wave": self = .wav
        case "aif", "aiff": self = .aiff
        default: self = .unknown
        }
    }
}

struct PDBTableInfo: Equatable, Sendable {
    var type: UInt32
    var emptyCandidate: UInt32
    var firstPage: UInt32
    var lastPage: UInt32
}

enum PDBTrackString: Int, CaseIterable, Sendable {
    case isrc = 0
    case lyricist = 1
    case unknown2 = 2
    case unknown3 = 3
    case unknown4 = 4
    case message = 5
    case kuvoPublic = 6
    case autoloadHotCues = 7
    case unknown5 = 8
    case unknown6 = 9
    case dateAdded = 10
    case releaseDate = 11
    case mixName = 12
    case unknown7 = 13
    case analyzePath = 14
    case analyzeDate = 15
    case comment = 16
    case title = 17
    case unknown8 = 18
    case filename = 19
    case filePath = 20
}

struct PDBTrack: Equatable, Sendable {
    static let stringCount = 21
    static let fixedSize = 0x5E
    static let headerSize = 0x88

    var id: UInt32
    var subtype: UInt16 = 0x0024
    var bitmask: UInt32 = 0x000C_0700
    var sampleRate: UInt32 = 44100
    var composerId: UInt32 = 0
    var fileSize: UInt32 = 0
    var unknown2: UInt32 = 0
    var unknown3: UInt16 = 0xAE49
    var unknown4: UInt16 = 0x03DD
    var artworkId: UInt32 = 0
    var keyId: UInt32 = 0
    var originalArtistId: UInt32 = 0
    var labelId: UInt32 = 0
    var remixerId: UInt32 = 0
    var bitrate: UInt32 = 0
    var trackNumber: UInt32 = 0
    var tempo: UInt32 = 0
    var genreId: UInt32 = 0
    var albumId: UInt32 = 0
    var artistId: UInt32 = 0
    var discNumber: UInt16 = 0
    var playCount: UInt16 = 0
    var year: UInt16 = 0
    var sampleDepth: UInt16 = 16
    var duration: UInt16 = 0
    var unknown5: UInt16 = 0x0029
    var colorId: UInt8 = 0
    var rating: UInt8 = 0
    var fileType: UInt16 = PDBFileType.mp3.rawValue
    var unknown7: UInt16 = 0x0003
    var strings: [String] = PDBTrack.defaultStrings

    static let defaultStrings: [String] = {
        var s = [String](repeating: "", count: stringCount)
        s[PDBTrackString.unknown2.rawValue] = "2"
        s[PDBTrackString.unknown3.rawValue] = "2"
        s[PDBTrackString.autoloadHotCues.rawValue] = "ON"
        return s
    }()

    init(id: UInt32) { self.id = id }

    subscript(_ slot: PDBTrackString) -> String {
        get { slot.rawValue < strings.count ? strings[slot.rawValue] : "" }
        set {
            if strings.count < PDBTrack.stringCount {
                strings += [String](repeating: "", count: PDBTrack.stringCount - strings.count)
            }
            strings[slot.rawValue] = newValue
        }
    }

    var title: String { self[.title] }
    var filePath: String { self[.filePath] }
    var analyzePath: String { self[.analyzePath] }
    var bpm: Double { Double(tempo) / 100 }
}

struct PDBArtist: Equatable, Sendable {
    var id: UInt32
    var name: String
}

struct PDBAlbum: Equatable, Sendable {
    var id: UInt32
    var name: String
    var artistId: UInt32 = 0
}

struct PDBNamedRow: Equatable, Sendable {
    var id: UInt32
    var name: String
}

struct PDBKey: Equatable, Sendable {
    var id: UInt32
    var name: String
}

struct PDBColor: Equatable, Sendable {
    var id: UInt16
    var name: String
}

struct PDBArtwork: Equatable, Sendable {
    var id: UInt32
    var path: String
}

struct PDBPlaylistNode: Equatable, Sendable {
    var id: UInt32
    var parentId: UInt32
    var sortOrder: UInt32
    var isFolder: Bool
    var name: String
}

struct PDBPlaylistEntry: Equatable, Sendable {
    var entryIndex: UInt32
    var trackId: UInt32
    var playlistId: UInt32
}

struct PDBHistoryEntry: Equatable, Sendable {
    var trackId: UInt32
    var playlistId: UInt32
    var entryIndex: UInt32
}

struct PDBColumn: Equatable, Sendable {
    var id: UInt16
    var code: UInt16
    var name: String
}

struct PDBTag: Equatable, Sendable {
    var id: UInt32
    var categoryId: UInt32
    var position: UInt32
    var isCategory: Bool
    var name: String
}

struct PDBDatabase: Equatable, Sendable {
    var pageSize: Int = 4096
    var tables: [PDBTableInfo] = []
    var sequence: UInt32 = 0
    var tracks: [PDBTrack] = []
    var genres: [PDBNamedRow] = []
    var artists: [PDBArtist] = []
    var albums: [PDBAlbum] = []
    var labels: [PDBNamedRow] = []
    var keys: [PDBKey] = []
    var colors: [PDBColor] = []
    var playlistTree: [PDBPlaylistNode] = []
    var playlistEntries: [PDBPlaylistEntry] = []
    var historyPlaylists: [PDBNamedRow] = []
    var historyEntries: [PDBHistoryEntry] = []
    var artwork: [PDBArtwork] = []
    var columns: [PDBColumn] = []
    var rawRows: [UInt32: [[UInt8]]] = [:]

    func track(id: UInt32) -> PDBTrack? { tracks.first { $0.id == id } }

    func entries(ofPlaylist id: UInt32) -> [PDBPlaylistEntry] {
        playlistEntries.filter { $0.playlistId == id }.sorted { $0.entryIndex < $1.entryIndex }
    }

    static func exportDefaults() -> PDBDatabase {
        var db = PDBDatabase()
        db.colors = PDBDefaults.colors
        db.columns = PDBDefaults.columns
        db.rawRows[PDBTableType.menuItems.rawValue] = PDBDefaults.menuItemRows
        db.rawRows[PDBTableType.unknown18.rawValue] = PDBDefaults.table18Rows
        return db
    }
}

struct PDBExtDatabase: Equatable, Sendable {
    var pageSize: Int = 4096
    var tables: [PDBTableInfo] = []
    var tags: [PDBTag] = []
    var rawRows: [UInt32: [[UInt8]]] = [:]
}

// MARK: - Defaults captured from a fresh rekordbox export

enum PDBDefaults {
    static let colors: [PDBColor] = [
        PDBColor(id: 1, name: "Pink"), PDBColor(id: 2, name: "Red"), PDBColor(id: 3, name: "Orange"),
        PDBColor(id: 4, name: "Yellow"), PDBColor(id: 5, name: "Green"), PDBColor(id: 6, name: "Aqua"),
        PDBColor(id: 7, name: "Blue"), PDBColor(id: 8, name: "Purple"),
    ]

    static let colorRGB: [UInt8: (UInt8, UInt8, UInt8)] = [
        1: (0xF8, 0x70, 0xF8), 2: (0xF8, 0x20, 0x20), 3: (0xF8, 0xA0, 0x30), 4: (0xF8, 0xE3, 0x31),
        5: (0x10, 0xB1, 0x76), 6: (0x30, 0xD2, 0xE6), 7: (0x30, 0x5A, 0xFF), 8: (0xAB, 0x5A, 0xFF),
    ]

    private static let columnSeeds: [(UInt16, UInt16, String)] = [
        (1, 0x80, "GENRE"), (2, 0x81, "ARTIST"), (3, 0x82, "ALBUM"), (4, 0x83, "TRACK"), (5, 0x85, "BPM"),
        (6, 0x86, "RATING"), (7, 0x87, "YEAR"), (8, 0x88, "REMIXER"), (9, 0x89, "LABEL"),
        (10, 0x8A, "ORIGINAL ARTIST"), (11, 0x8B, "KEY"), (12, 0x8D, "CUE"), (13, 0x8E, "COLOR"),
        (14, 0x92, "TIME"), (15, 0x93, "BITRATE"), (16, 0x94, "FILE NAME"), (17, 0x84, "PLAYLIST"),
        (18, 0x98, "HOT CUE BANK"), (19, 0x95, "HISTORY"), (20, 0x91, "SEARCH"), (21, 0x96, "COMMENTS"),
        (22, 0x8C, "DATE ADDED"), (23, 0x97, "DJ PLAY COUNT"), (24, 0x90, "FOLDER"), (25, 0xA1, "DEFAULT"),
        (26, 0xA2, "ALPHABET"), (27, 0xAA, "MATCHING"),
    ]

    static let columns: [PDBColumn] = columnSeeds.map {
        PDBColumn(id: $0.0, code: $0.1, name: "\u{FFFA}\($0.2)\u{FFFB}")
    }

    private static let menuItemSeeds: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
        (0x01, 0x01, 0x63, 0x01, 0x00), (0x05, 0x06, 0x05, 0x01, 0x00), (0x06, 0x07, 0x63, 0x01, 0x00),
        (0x07, 0x08, 0x63, 0x01, 0x00), (0x08, 0x09, 0x63, 0x01, 0x00), (0x09, 0x0A, 0x63, 0x01, 0x00),
        (0x0A, 0x0B, 0x63, 0x01, 0x00), (0x0D, 0x0F, 0x63, 0x01, 0x00), (0x0E, 0x13, 0x04, 0x01, 0x00),
        (0x0F, 0x14, 0x06, 0x01, 0x00), (0x10, 0x15, 0x63, 0x01, 0x00), (0x12, 0x17, 0x63, 0x01, 0x00),
        (0x02, 0x02, 0x02, 0x00, 0x01), (0x03, 0x03, 0x03, 0x00, 0x02), (0x04, 0x04, 0x01, 0x00, 0x03),
        (0x0B, 0x0C, 0x63, 0x00, 0x04), (0x11, 0x05, 0x63, 0x00, 0x05), (0x13, 0x16, 0x63, 0x00, 0x06),
        (0x14, 0x12, 0x63, 0x00, 0x07), (0x1B, 0x1A, 0x63, 0x02, 0x08), (0x18, 0x11, 0x63, 0x00, 0x09),
        (0x16, 0x1B, 0x63, 0x00, 0x0A),
    ]

    static let menuItemRows: [[UInt8]] = menuItemSeeds.map { [$0.0, 0, $0.1, 0, $0.2, $0.3, $0.4, 0] }

    private static let table18Seeds: [(UInt8, UInt8, UInt8, UInt8)] = [
        (0x01, 0x06, 0x01, 0x00), (0x15, 0x07, 0x01, 0x00), (0x0E, 0x08, 0x01, 0x00), (0x08, 0x09, 0x01, 0x00),
        (0x09, 0x0A, 0x01, 0x00), (0x0A, 0x0B, 0x01, 0x00), (0x0F, 0x0D, 0x01, 0x00), (0x0D, 0x0F, 0x01, 0x00),
        (0x17, 0x10, 0x01, 0x00), (0x16, 0x11, 0x01, 0x00), (0x19, 0x00, 0x00, 0x01), (0x1A, 0x01, 0x00, 0x02),
        (0x02, 0x02, 0x00, 0x03), (0x03, 0x03, 0x00, 0x04), (0x05, 0x04, 0x00, 0x05), (0x06, 0x05, 0x00, 0x06),
        (0x0B, 0x0C, 0x00, 0x07),
    ]

    static let table18Rows: [[UInt8]] = table18Seeds.map { [$0.0, 0, $0.1, 0, $0.2, $0.3, 0, 0] }
}
