import Darwin
import Foundation

struct DJStickFileStamp: Equatable, Sendable {
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
}

enum DJStickError: Error, Equatable, Sendable {
    case notAStick
    case unreadable(String)
    case tooLarge(String)
    case malformed(String)
}

protocol DJStickIO: Sendable {
    func readFile(atPath path: String, maxBytes: Int) throws -> Data
    func stamp(atPath path: String) -> DJStickFileStamp?
}

struct DJStickPOSIXIO: DJStickIO {
    static let openFlags: Int32 = O_RDONLY | O_CLOEXEC

    init() {}

    func readFile(atPath path: String, maxBytes: Int) throws -> Data {
        let descriptor = open(path, Self.openFlags)
        guard descriptor >= 0 else { throw DJStickError.unreadable("open \(errno)") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw DJStickError.unreadable("not a regular file")
        }
        guard info.st_size >= 0, info.st_size <= Int64(maxBytes) else { throw DJStickError.tooLarge(path) }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        let total = data.count
        while offset < total {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return read(descriptor, base + offset, total - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw DJStickError.unreadable("read \(errno)")
            }
            if count == 0 { throw DJStickError.unreadable("short read") }
            offset += count
        }
        return data
    }

    func stamp(atPath path: String) -> DJStickFileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return DJStickFileStamp(
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

enum DJStickLayout {
    static let dataFolders = ["PIONEER", ".PIONEER"]
    static let maxDatabaseBytes = 512 * 1024 * 1024
    static let maxAnalysisBytes = 64 * 1024 * 1024

    static func databasePath(root: String, io: DJStickIO) -> String? {
        for folder in dataFolders {
            let path = join(root, "/\(folder)/rekordbox/export.pdb")
            if io.stamp(atPath: path) != nil { return path }
        }
        return nil
    }

    static func isStick(root: String, io: DJStickIO = DJStickPOSIXIO()) -> Bool {
        databasePath(root: root, io: io) != nil
    }

    static func join(_ root: String, _ devicePath: String) -> String {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return base + (devicePath.hasPrefix("/") ? devicePath : "/" + devicePath)
    }

    static func safeDevicePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }
}

struct DJStickTrack: Identifiable, Equatable, Sendable {
    var id: UInt32
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Int
    var bpm: Double?
    var keyName: String?
    var comment: String
    var isrc: String?
    var analyzePath: String
    var filePath: String
    var colourId: Int = 0
    var rating: Int = 0
}

struct DJStickPlaylist: Identifiable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var path: [String]
    var trackIds: [UInt32]
}

struct DJStickLibrary: Sendable {
    let tracks: [DJStickTrack]
    let playlists: [DJStickPlaylist]
    private let index: [UInt32: Int]

    init(database: PDBDatabase) {
        let artists = Dictionary(database.artists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let albums = Dictionary(database.albums.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let keys = Dictionary(database.keys.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var built: [DJStickTrack] = []
        built.reserveCapacity(database.tracks.count)
        var seen = Set<UInt32>()
        for track in database.tracks where seen.insert(track.id).inserted {
            let isrc = track[.isrc].trimmingCharacters(in: .whitespaces)
            built.append(DJStickTrack(
                id: track.id,
                title: track.title,
                artist: artists[track.artistId] ?? "",
                album: albums[track.albumId] ?? "",
                durationSeconds: Int(track.duration),
                bpm: track.tempo > 0 ? track.bpm : nil,
                keyName: track.keyId == 0 ? nil : keys[track.keyId],
                comment: track[.comment],
                isrc: isrc.isEmpty ? nil : isrc,
                analyzePath: track.analyzePath,
                filePath: track.filePath,
                colourId: Int(track.colorId),
                rating: Int(track.rating)
            ))
        }
        tracks = built
        index = Dictionary(built.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlists = Self.playlists(from: database, knownTracks: seen)
    }

    func track(id: UInt32) -> DJStickTrack? {
        index[id].map { tracks[$0] }
    }

    func tracks(in playlist: DJStickPlaylist) -> [DJStickTrack] {
        playlist.trackIds.compactMap { track(id: $0) }
    }

    private static func playlists(from database: PDBDatabase, knownTracks: Set<UInt32>) -> [DJStickPlaylist] {
        let nodes = Dictionary(database.playlistTree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entriesByPlaylist: [UInt32: [PDBPlaylistEntry]] = [:]
        for entry in database.playlistEntries { entriesByPlaylist[entry.playlistId, default: []].append(entry) }
        var out: [DJStickPlaylist] = []
        for node in database.playlistTree.sorted(by: { ($0.parentId, $0.sortOrder, $0.id) < ($1.parentId, $1.sortOrder, $1.id) }) where !node.isFolder {
            var path: [String] = []
            var parent = node.parentId
            var hops = 0
            while parent != 0, let folder = nodes[parent], hops < 32 {
                path.insert(folder.name, at: 0)
                parent = folder.parentId
                hops += 1
            }
            let ids = (entriesByPlaylist[node.id] ?? [])
                .sorted { $0.entryIndex < $1.entryIndex }
                .map(\.trackId)
                .filter { knownTracks.contains($0) }
            out.append(DJStickPlaylist(id: node.id, name: node.name, path: path, trackIds: ids))
        }
        return out
    }
}

struct DJStickAnalysis: Equatable, Sendable {
    struct Tempo: Equatable, Sendable {
        var startSeconds: Double
        var bpm: Double
        var beatInBar: Int
    }

    enum MarkKind: Equatable, Sendable {
        case memory
        case hotCue
        case loop
    }

    struct Mark: Equatable, Sendable {
        var kind: MarkKind
        var slot: Int?
        var startSeconds: Double
        var endSeconds: Double?
        var label: String
        var rgb: UInt32?

        var xmlType: Int { kind == .loop ? 4 : 0 }
        var xmlNum: Int { slot ?? -1 }
        var red: Int? { rgb.map { Int($0 >> 16 & 0xFF) } }
        var green: Int? { rgb.map { Int($0 >> 8 & 0xFF) } }
        var blue: Int? { rgb.map { Int($0 & 0xFF) } }
    }

    var tempos: [Tempo] = []
    var marks: [Mark] = []
    var overview: [Float] = []

    var isEmpty: Bool { tempos.isEmpty && marks.isEmpty && overview.isEmpty }

    static func summarise(dat: ANLZFile?, ext: ANLZFile?) -> DJStickAnalysis {
        var analysis = DJStickAnalysis()
        if case .waveformPreview(let bytes)? = dat?.tag("PWAV") ?? ext?.tag("PWAV") {
            analysis.overview = bytes.map { Float($0 & 0x1F) / 31 }
        }
        if let beats = dat?.beatGrid ?? ext?.beatGrid { analysis.tempos = tempos(from: beats) }
        let lists = cueLists(dat: dat, ext: ext)
        for list in lists {
            for cue in list.cues { if let mark = mark(from: cue) { analysis.marks.append(mark) } }
        }
        analysis.marks.sort { ($0.startSeconds, $0.slot ?? -1) < ($1.startSeconds, $1.slot ?? -1) }
        return analysis
    }

    private static func cueLists(dat: ANLZFile?, ext: ANLZFile?) -> [ANLZCueList] {
        var extended: [ANLZCueList] = []
        for kind in [ANLZCueListKind.memory, .hotCues] {
            if let list = ext?.cueList(kind, extended: true) ?? dat?.cueList(kind, extended: true) { extended.append(list) }
        }
        if !extended.isEmpty { return extended }
        var legacy: [ANLZCueList] = []
        for kind in [ANLZCueListKind.memory, .hotCues] {
            if let list = dat?.cueList(kind, extended: false) { legacy.append(list) }
        }
        return legacy
    }

    private static func tempos(from beats: [ANLZBeat]) -> [Tempo] {
        var out: [Tempo] = []
        var last: ANLZBeat?
        for beat in beats where beat.tempo > 0 && (1...4).contains(beat.beatNumber) {
            defer { last = beat }
            if let last, beat.tempo == last.tempo, Int(beat.beatNumber) == Int(last.beatNumber) % 4 + 1 { continue }
            out.append(Tempo(startSeconds: Double(beat.timeMillis) / 1000, bpm: Double(beat.tempo) / 100, beatInBar: Int(beat.beatNumber)))
        }
        return out
    }

    private static func mark(from cue: ANLZCue) -> Mark? {
        let start = Double(cue.timeMillis) / 1000
        let end: Double? = cue.isLoop && cue.loopTimeMillis != ANLZCue.noLoop && cue.loopTimeMillis > cue.timeMillis
            ? Double(cue.loopTimeMillis) / 1000 : nil
        let slot: Int? = (1...8).contains(Int(cue.hotCue)) ? Int(cue.hotCue) - 1 : nil
        if cue.hotCue > 8 { return nil }
        let rgb: UInt32? = (cue.colorRed | cue.colorGreen | cue.colorBlue) == 0
            ? nil
            : UInt32(cue.colorRed) << 16 | UInt32(cue.colorGreen) << 8 | UInt32(cue.colorBlue)
        let kind: MarkKind
        if cue.isLoop {
            guard end != nil else { return nil }
            kind = .loop
        } else {
            kind = slot == nil ? .memory : .hotCue
        }
        return Mark(kind: kind, slot: slot, startSeconds: start, endSeconds: end, label: cue.comment, rgb: rgb)
    }
}

enum DJStickLoader {
    static func load(root: String, io: DJStickIO = DJStickPOSIXIO()) throws -> (library: DJStickLibrary, stamp: DJStickFileStamp) {
        guard let path = DJStickLayout.databasePath(root: root, io: io), let stamp = io.stamp(atPath: path) else {
            throw DJStickError.notAStick
        }
        let data = try io.readFile(atPath: path, maxBytes: DJStickLayout.maxDatabaseBytes)
        do {
            let result = try PDBReader.read(data)
            return (DJStickLibrary(database: result.database), stamp)
        } catch {
            throw DJStickError.malformed("export.pdb")
        }
    }

    static func analysis(for track: DJStickTrack, root: String, io: DJStickIO = DJStickPOSIXIO()) -> DJStickAnalysis? {
        guard let datPath = DJStickLayout.safeDevicePath(track.analyzePath) else { return nil }
        let dat = parse(io, DJStickLayout.join(root, datPath))
        var extPath = datPath
        if extPath.uppercased().hasSuffix(".DAT") { extPath = String(extPath.dropLast(3)) + "EXT" }
        let ext = extPath == datPath ? nil : parse(io, DJStickLayout.join(root, extPath))
        guard dat != nil || ext != nil else { return nil }
        return DJStickAnalysis.summarise(dat: dat, ext: ext)
    }

    private static func parse(_ io: DJStickIO, _ path: String) -> ANLZFile? {
        guard let data = try? io.readFile(atPath: path, maxBytes: DJStickLayout.maxAnalysisBytes) else { return nil }
        return try? ANLZCodec.read(data).file
    }
}

actor DJStickLibraryCache {
    static let shared = DJStickLibraryCache()

    private struct Entry {
        var stamp: DJStickFileStamp
        var library: DJStickLibrary
    }

    private var entries: [String: Entry] = [:]
    private var failures: [String: DJStickFileStamp] = [:]
    private(set) var loadCount = 0

    func library(volumeKey: String, root: String, io: DJStickIO = DJStickPOSIXIO()) -> DJStickLibrary? {
        guard let path = DJStickLayout.databasePath(root: root, io: io), let stamp = io.stamp(atPath: path) else {
            entries[volumeKey] = nil
            return nil
        }
        if let entry = entries[volumeKey], entry.stamp == stamp { return entry.library }
        if failures[volumeKey] == stamp { return nil }
        do {
            let loaded = try DJStickLoader.load(root: root, io: io)
            loadCount += 1
            entries[volumeKey] = Entry(stamp: loaded.stamp, library: loaded.library)
            failures[volumeKey] = nil
            return loaded.library
        } catch {
            entries[volumeKey] = nil
            failures[volumeKey] = stamp
            return nil
        }
    }

    func forget(volumeKey: String) {
        entries[volumeKey] = nil
        failures[volumeKey] = nil
    }
}
