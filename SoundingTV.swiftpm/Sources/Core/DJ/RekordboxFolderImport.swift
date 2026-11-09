import Foundation

// MARK: - Layout

struct RekordboxFolderEntry: Hashable, Sendable {
    var name: String
    var isDirectory: Bool
    var size: Int64
}

enum RekordboxFolderLayout {
    static let maxDepth = 14
    static let maxEntries = 500_000
    static let sniffBytes = 4096
    static let stickFolders: Set<String> = ["PIONEER", ".PIONEER"]
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "logicx", "band"]
    static let encryptedSuffixes = [".db", ".edb", ".db-wal", ".db-shm", ".db-journal", ".edb-wal", ".edb-shm", ".sqlite", ".sqlcipher"]
    static let trackColours: [Int: UInt32] = [
        1: 0xFF007F, 2: 0xFF0000, 3: 0xFFA500, 4: 0xFFFF00, 5: 0x00FF00, 6: 0x25FDE9, 7: 0x0000FF, 8: 0x660099,
    ]

    static func isEncryptedDatabase(_ name: String) -> Bool {
        let lower = name.lowercased()
        return encryptedSuffixes.contains { lower.hasSuffix($0) }
    }

    static func isAppDataMarker(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "master.db" || lower.hasPrefix("master.backup") || lower == "datafile.edb"
            || lower == "masterplaylists6.xml" || lower == "automixplaylist6.xml" || lower == "networkanalyze6.db"
    }

    static func isAudio(_ name: String) -> Bool {
        LocalMusicScanner.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isXML(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xml"
    }

    static func list(_ path: String) -> [RekordboxFolderEntry]? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return nil
        }
        return children.compactMap { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { return nil }
            let isDirectory = values?.isDirectory == true && values?.isPackage != true
            return RekordboxFolderEntry(name: child.lastPathComponent, isDirectory: isDirectory, size: Int64(values?.fileSize ?? 0))
        }
    }

    static func looksLikeRekordboxXML(_ path: String) -> Bool {
        guard isXML(path), !isEncryptedDatabase(path), let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sniffBytes), !head.isEmpty else { return false }
        return String(decoding: head, as: UTF8.self).contains("<DJ_PLAYLISTS")
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// MARK: - Classification

struct RekordboxFolderClassification: Equatable, Sendable {
    var root: String
    var stickRoots: [String] = []
    var xmlFiles: [String] = []
    var analysisRoots: [String] = []
    var appDataRoots: [String] = []
    var audioFiles: [String] = []
    var encryptedDatabases = 0
    var stickOutsideSelection = false
    var isTruncated = false

    var hasExport: Bool { !stickRoots.isEmpty || !xmlFiles.isEmpty }
    var hasAppData: Bool { !appDataRoots.isEmpty || !analysisRoots.isEmpty || encryptedDatabases > 0 }
    var isEmpty: Bool { !hasExport && analysisRoots.isEmpty && audioFiles.isEmpty }
    var needsExport: Bool { isEmpty && hasAppData }
}

enum RekordboxFolderClassifier {
    static func classify(
        root: String,
        list: (String) -> [RekordboxFolderEntry]? = RekordboxFolderLayout.list,
        sniff: (String) -> Bool = RekordboxFolderLayout.looksLikeRekordboxXML
    ) -> RekordboxFolderClassification {
        let base = RekordboxFolderLayout.trimmed(root)
        var result = RekordboxFolderClassification(root: base)
        guard list(base) != nil else {
            if RekordboxFolderLayout.isXML(base), sniff(base) { result.xmlFiles = [base] }
            return result
        }
        if let outer = enclosingStickRoot(of: base, list: list) {
            result.stickRoots.append(outer)
            result.stickOutsideSelection = true
        }
        var stack: [(path: String, depth: Int)] = [(base, 0)]
        var seen = 0
        walk: while let folder = stack.popLast() {
            guard let entries = list(folder.path) else { continue }
            let isStick = isStickRoot(folder.path, entries: entries, list: list)
            if isStick, !result.stickRoots.contains(folder.path) { result.stickRoots.append(folder.path) }
            if entries.contains(where: { !$0.isDirectory && RekordboxFolderLayout.isAppDataMarker($0.name) }) {
                result.appDataRoots.append(folder.path)
            }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                seen += 1
                if seen > RekordboxFolderLayout.maxEntries {
                    result.isTruncated = true
                    break walk
                }
                let path = folder.path == "/" ? "/" + entry.name : folder.path + "/" + entry.name
                if entry.isDirectory {
                    if entry.name.uppercased() == "USBANLZ" {
                        if !result.stickRoots.contains(where: { path.hasPrefix($0 + "/") }) { result.analysisRoots.append(path) }
                        continue
                    }
                    if RekordboxFolderLayout.stickFolders.contains(entry.name), isStick { continue }
                    if entry.name.hasPrefix(".") { continue }
                    if RekordboxFolderLayout.packageExtensions.contains((entry.name as NSString).pathExtension.lowercased()) { continue }
                    if folder.depth < RekordboxFolderLayout.maxDepth { stack.append((path, folder.depth + 1)) }
                    continue
                }
                if entry.name.hasPrefix(".") { continue }
                if RekordboxFolderLayout.isEncryptedDatabase(entry.name) {
                    result.encryptedDatabases += 1
                    continue
                }
                if RekordboxFolderLayout.isXML(entry.name) {
                    if entry.size <= Int64(RekordboxXML.maximumBytes), sniff(path) { result.xmlFiles.append(path) }
                    continue
                }
                if RekordboxFolderLayout.isAudio(entry.name) { result.audioFiles.append(path) }
            }
        }
        result.stickRoots.sort()
        result.xmlFiles.sort()
        result.analysisRoots.sort()
        result.appDataRoots.sort()
        result.audioFiles.sort()
        return result
    }

    static func isStickRoot(_ path: String, entries: [RekordboxFolderEntry], list: (String) -> [RekordboxFolderEntry]?) -> Bool {
        for entry in entries where entry.isDirectory && RekordboxFolderLayout.stickFolders.contains(entry.name) {
            let inner = path + "/" + entry.name + "/rekordbox"
            if list(inner)?.contains(where: { !$0.isDirectory && $0.name.lowercased() == "export.pdb" }) == true { return true }
        }
        return false
    }

    static func enclosingStickRoot(of path: String, list: (String) -> [RekordboxFolderEntry]?) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return nil }
        let candidate: [String]
        if RekordboxFolderLayout.stickFolders.contains(last) {
            candidate = Array(parts.dropLast())
            guard list(path + "/rekordbox")?.contains(where: { $0.name.lowercased() == "export.pdb" }) == true else { return nil }
        } else if last.lowercased() == "rekordbox", parts.count >= 2, RekordboxFolderLayout.stickFolders.contains(parts[parts.count - 2]) {
            candidate = Array(parts.dropLast(2))
            guard list(path)?.contains(where: { $0.name.lowercased() == "export.pdb" }) == true else { return nil }
        } else {
            return nil
        }
        return "/" + candidate.joined(separator: "/")
    }
}

// MARK: - Scan

struct RekordboxFolderTrack: Identifiable, Sendable {
    enum Origin: Int, Comparable, Sendable {
        case analysis = 0
        case stick = 1
        case xml = 2

        static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var origin: Origin
    var rekordboxId: String?
    var track: RekordboxTrack
    var filePath: String?
    var fileName: String
    var phrases: [PrepPhrase]
    var hasWaveform = false

    var title: String { track.name.isEmpty ? (fileName as NSString).deletingPathExtension : track.name }
    var durationSeconds: Double? { track.totalTime > 0 ? track.totalTime : nil }
    var richness: Int { track.marks.count * 4 + phrases.count * 2 + track.tempos.count + (track.tonality == nil ? 0 : 1) }
}

struct RekordboxFolderPlaylist: Hashable, Sendable {
    var path: [String]
    var name: String
    var trackKeys: [String]

    var fullPath: String { (path + [name]).joined(separator: "/") }
}

struct RekordboxFolderProgress: Equatable, Sendable {
    var tracks = 0
    var playlists = 0
    var cues = 0
}

struct RekordboxFolderScan: Sendable {
    var classification: RekordboxFolderClassification
    var tracks: [RekordboxFolderTrack] = []
    var playlists: [RekordboxFolderPlaylist] = []
    var unreadable = 0

    var cueCount: Int { tracks.reduce(0) { $0 + $1.track.marks.count } }
    var gridCount: Int { tracks.filter { !$0.track.tempos.isEmpty }.count }
    var keyCount: Int { tracks.filter { $0.track.tonality != nil }.count }
    var waveformCount: Int { tracks.filter(\.hasWaveform).count }
    var isAnalysisOnly: Bool { classification.stickRoots.isEmpty && classification.xmlFiles.isEmpty && !tracks.isEmpty }
    var progress: RekordboxFolderProgress { RekordboxFolderProgress(tracks: tracks.count, playlists: playlists.count, cues: cueCount) }
}

struct RekordboxFolderStickTrack: Sendable {
    var id: UInt32
    var title: String
    var artist: String
    var album: String = ""
    var durationSeconds: Int
    var bpm: Double?
    var keyName: String?
    var comment: String = ""
    var colourId: Int = 0
    var rating: Int = 0
    var filePath: String
    var tempos: [RekordboxTempo] = []
    var marks: [RekordboxMark] = []
    var phrases: [PrepPhrase] = []
    var hasWaveform = false
}

struct RekordboxFolderStick: Sendable {
    var tracks: [RekordboxFolderStickTrack]
    var playlists: [RekordboxFolderPlaylist]
}

struct RekordboxFolderAnalysisEntry: Sendable {
    var id: String
    var devicePath: String
    var fileName: String
    var track: RekordboxTrack
    var phrases: [PrepPhrase]
    var hasWaveform: Bool
}

struct RekordboxFolderAnalysis: Sendable {
    var entries: [RekordboxFolderAnalysisEntry] = []
    var unreadable = 0
}

struct RekordboxFolderReaders: Sendable {
    var xml: @Sendable (String) -> Data?
    var stick: @Sendable (String) -> RekordboxFolderStick?
    var analysis: @Sendable (String) -> RekordboxFolderAnalysis

    static let xmlOnly = RekordboxFolderReaders(
        xml: { path in try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) },
        stick: { _ in nil },
        analysis: { _ in RekordboxFolderAnalysis() }
    )
}

enum RekordboxFolderScanner {
    static func scan(
        _ classification: RekordboxFolderClassification,
        readers: RekordboxFolderReaders,
        progress: (RekordboxFolderProgress) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> RekordboxFolderScan {
        var scan = RekordboxFolderScan(classification: classification)
        var tracks: [RekordboxFolderTrack] = []
        var playlists: [RekordboxFolderPlaylist] = []
        var cues = 0

        for (index, path) in classification.xmlFiles.enumerated() {
            if isCancelled() { return scan }
            guard let data = readers.xml(path), let library = try? RekordboxXML.parse(data) else {
                scan.unreadable += 1
                continue
            }
            let prefix = "xml:\(index):"
            for track in library.tracks {
                let url = track.fileURL
                tracks.append(RekordboxFolderTrack(
                    id: prefix + track.trackId,
                    origin: .xml,
                    rekordboxId: track.trackId.isEmpty ? nil : track.trackId,
                    track: track,
                    filePath: url?.path,
                    fileName: url?.lastPathComponent ?? "",
                    phrases: []
                ))
                cues += track.marks.count
            }
            for playlist in library.flattenedPlaylists() {
                playlists.append(RekordboxFolderPlaylist(path: playlist.path, name: playlist.name, trackKeys: playlist.trackIds.map { prefix + $0 }))
            }
            progress(RekordboxFolderProgress(tracks: tracks.count, playlists: playlists.count, cues: cues))
        }

        for (index, root) in classification.stickRoots.enumerated() {
            if isCancelled() { return scan }
            guard let stick = readers.stick(root) else {
                scan.unreadable += 1
                continue
            }
            let prefix = "usb:\(index):"
            for stickTrack in stick.tracks {
                let item = track(from: stickTrack, root: root, prefix: prefix)
                tracks.append(item)
                cues += item.track.marks.count
            }
            for playlist in stick.playlists {
                playlists.append(RekordboxFolderPlaylist(path: playlist.path, name: playlist.name, trackKeys: playlist.trackKeys.map { prefix + $0 }))
            }
            progress(RekordboxFolderProgress(tracks: tracks.count, playlists: playlists.count, cues: cues))
        }

        for (index, root) in classification.analysisRoots.enumerated() {
            if isCancelled() { return scan }
            let analysis = readers.analysis(root)
            scan.unreadable += analysis.unreadable
            for entry in analysis.entries {
                tracks.append(RekordboxFolderTrack(
                    id: "anlz:\(index):\(entry.id)",
                    origin: .analysis,
                    rekordboxId: nil,
                    track: entry.track,
                    filePath: entry.devicePath.hasPrefix("/") ? entry.devicePath : nil,
                    fileName: entry.fileName,
                    phrases: entry.phrases,
                    hasWaveform: entry.hasWaveform
                ))
                cues += entry.track.marks.count
            }
            progress(RekordboxFolderProgress(tracks: tracks.count, playlists: playlists.count, cues: cues))
        }

        let consolidated = consolidate(tracks)
        scan.tracks = consolidated.tracks
        scan.playlists = playlists.map { playlist in
            var copy = playlist
            copy.trackKeys = playlist.trackKeys.map { consolidated.aliases[$0] ?? $0 }
            return copy
        }
        progress(scan.progress)
        return scan
    }

    static func track(from stickTrack: RekordboxFolderStickTrack, root: String, prefix: String) -> RekordboxFolderTrack {
        var attributes: [String: String] = [
            "Name": stickTrack.title,
            "Artist": stickTrack.artist,
            "TotalTime": String(stickTrack.durationSeconds),
        ]
        if !stickTrack.album.isEmpty { attributes["Album"] = stickTrack.album }
        if let bpm = stickTrack.bpm { attributes["AverageBpm"] = RekordboxXML.bpm(bpm) }
        if let key = stickTrack.keyName, !key.isEmpty { attributes["Tonality"] = key }
        if !stickTrack.comment.isEmpty { attributes["Comments"] = stickTrack.comment }
        if let colour = RekordboxFolderLayout.trackColours[stickTrack.colourId] { attributes["Colour"] = String(format: "0x%06X", colour) }
        if stickTrack.rating > 0 { attributes["Rating"] = String(min(5, stickTrack.rating) * 51) }
        var filePath: String?
        if let device = safeDevicePath(stickTrack.filePath) {
            let path = RekordboxFolderLayout.trimmed(root) + device
            filePath = path
            attributes["Location"] = RekordboxXML.location(for: URL(fileURLWithPath: path))
        }
        let id = prefix + String(stickTrack.id)
        return RekordboxFolderTrack(
            id: id,
            origin: .stick,
            rekordboxId: nil,
            track: RekordboxTrack(trackId: id, attributes: attributes, tempos: stickTrack.tempos, marks: stickTrack.marks),
            filePath: filePath,
            fileName: filePath.map { ($0 as NSString).lastPathComponent } ?? "",
            phrases: stickTrack.phrases,
            hasWaveform: stickTrack.hasWaveform
        )
    }

    static func safeDevicePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    static func consolidate(_ tracks: [RekordboxFolderTrack]) -> (tracks: [RekordboxFolderTrack], aliases: [String: String]) {
        let ordered = tracks.enumerated().sorted { lhs, rhs in
            lhs.element.origin != rhs.element.origin ? lhs.element.origin > rhs.element.origin : lhs.offset < rhs.offset
        }.map(\.element)
        var kept: [RekordboxFolderTrack] = []
        var aliases: [String: String] = [:]
        var byPath: [String: Int] = [:]
        var byName: [String: [Int]] = [:]
        for track in ordered {
            let path = track.filePath.map(RekordboxShareMatcher.normalisedPath)
            var target: Int?
            if let path, let index = byPath[path] {
                target = index
            } else if track.origin == .analysis, !track.fileName.isEmpty {
                let named = (byName[RekordboxShareMatcher.nameKey(track.fileName)] ?? []).filter { index in
                    guard let a = kept[index].durationSeconds, let b = track.durationSeconds else { return true }
                    return abs(a - b) <= RekordboxShareMatcher.durationTolerance
                }
                if named.count == 1 { target = named[0] }
            }
            if let target {
                kept[target] = merge(kept[target], track)
                aliases[track.id] = kept[target].id
                continue
            }
            let index = kept.count
            kept.append(track)
            if let path { byPath[path] = index }
            if track.origin != .analysis, !track.fileName.isEmpty {
                byName[RekordboxShareMatcher.nameKey(track.fileName), default: []].append(index)
            }
        }
        return (kept, aliases)
    }

    static func merge(_ base: RekordboxFolderTrack, _ extra: RekordboxFolderTrack) -> RekordboxFolderTrack {
        var out = base
        if out.track.tempos.isEmpty { out.track.tempos = extra.track.tempos }
        if out.track.marks.isEmpty { out.track.marks = extra.track.marks }
        if out.phrases.isEmpty { out.phrases = extra.phrases }
        for (key, value) in extra.track.attributes where (out.track.attributes[key] ?? "").isEmpty {
            out.track.attributes[key] = value
        }
        if out.filePath == nil { out.filePath = extra.filePath }
        if out.fileName.isEmpty { out.fileName = extra.fileName }
        if out.rekordboxId == nil { out.rekordboxId = extra.rekordboxId }
        out.hasWaveform = out.hasWaveform || extra.hasWaveform
        return out
    }
}

// MARK: - Matching

struct RekordboxFolderRoot: Hashable, Sendable {
    var folderID: String
    var path: String
}

enum RekordboxFolderOutcome: Hashable, Sendable {
    case path(String)
    case fileName(String)
    case title(String)
    case duplicate(String)
    case ambiguous
    case missing

    var importedTrackId: String? {
        switch self {
        case .path(let id), .fileName(let id), .title(let id): return id
        case .duplicate, .ambiguous, .missing: return nil
        }
    }

    var linkedTrackId: String? {
        if case .duplicate(let id) = self { return id }
        return importedTrackId
    }
}

struct RekordboxFolderMatch: Identifiable, Sendable {
    var item: RekordboxFolderTrack
    var outcome: RekordboxFolderOutcome

    var id: String { item.id }
}

struct RekordboxFolderSummary: Equatable, Sendable {
    var tracks = 0
    var playlists = 0
    var cues = 0
    var grids = 0
    var keys = 0
    var byFile = 0
    var byTitle = 0
    var duplicates = 0
    var ambiguous = 0
    var missing = 0
    var audioFiles = 0
    var newAudioFiles = 0

    var matched: Int { byFile + byTitle }
    var notFound: Int { ambiguous + missing }
}

enum RekordboxFolderFiles {
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func root(containing path: String, in roots: [RekordboxFolderRoot]) -> RekordboxFolderRoot? {
        let target = resolved(path)
        return roots
            .map { RekordboxFolderRoot(folderID: $0.folderID, path: resolved($0.path)) }
            .filter { target == $0.path || target.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    static func localFiles(_ audioFiles: [String], roots: [RekordboxFolderRoot]) -> [RekordboxShareLocalFile] {
        let prepared = roots.map { RekordboxFolderRoot(folderID: $0.folderID, path: resolved($0.path)) }
            .sorted { $0.path.count > $1.path.count }
        return audioFiles.compactMap { path in
            let target = resolved(path)
            guard let root = prepared.first(where: { target.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) else { return nil }
            let relative = LocalMusicScanner.relativePath(of: URL(fileURLWithPath: path), base: root.path)
            return RekordboxShareLocalFile(
                trackId: LocalMusicScanner.trackID(folderID: root.folderID, relativePath: relative),
                path: path,
                durationSeconds: nil
            )
        }
    }

    static func candidates(_ files: [RekordboxShareLocalFile]) -> [MatchCandidate] {
        files.map { file in
            let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let guess = LocalMusicScanner.fallbackTitleAndArtist(fromFileName: stem)
            return MatchCandidate(trackId: file.trackId, title: guess.title, artist: guess.artist ?? "", durationSeconds: file.durationSeconds ?? 0)
        }
    }
}

enum RekordboxFolderMatcher {
    static func match(
        _ tracks: [RekordboxFolderTrack],
        files: [RekordboxShareLocalFile],
        local: [MatchCandidate] = [],
        other: [MatchCandidate] = []
    ) -> [RekordboxFolderMatch] {
        let byPath = Dictionary(grouping: files) { RekordboxShareMatcher.normalisedPath($0.path) }
        let byName = Dictionary(grouping: files) { RekordboxShareMatcher.nameKey(($0.path as NSString).lastPathComponent) }
        let localIndex = TrackMatcher.Index(local)
        let otherIndex = TrackMatcher.Index(other)
        var out: [RekordboxFolderMatch] = []
        out.reserveCapacity(tracks.count)
        for item in tracks {
            out.append(RekordboxFolderMatch(item: item, outcome: outcome(item, byPath: byPath, byName: byName, local: localIndex, other: otherIndex)))
        }
        return deduplicated(out)
    }

    private static func outcome(
        _ item: RekordboxFolderTrack,
        byPath: [String: [RekordboxShareLocalFile]],
        byName: [String: [RekordboxShareLocalFile]],
        local: TrackMatcher.Index,
        other: TrackMatcher.Index
    ) -> RekordboxFolderOutcome {
        if let path = item.filePath, let file = pick(byPath[RekordboxShareMatcher.normalisedPath(path)] ?? [], duration: item.durationSeconds) {
            return .path(file.trackId)
        }
        if !item.fileName.isEmpty {
            let named = byName[RekordboxShareMatcher.nameKey(item.fileName)] ?? []
            if let file = pick(named, duration: item.durationSeconds) { return .fileName(file.trackId) }
            if Set(named.map(\.trackId)).count > 1 { return .ambiguous }
        }
        let query = MatchQuery(title: item.title, artist: item.track.artist, durationSeconds: item.durationSeconds ?? 0, isrc: nil)
        switch TrackMatcher.match(query, in: local) {
        case .matched(let id): return .title(id)
        case .ambiguous: return .ambiguous
        case .missing: break
        }
        switch TrackMatcher.match(query, in: other) {
        case .matched(let id): return .title(id)
        case .ambiguous: return .ambiguous
        case .missing: return .missing
        }
    }

    private static func pick(_ files: [RekordboxShareLocalFile], duration: Double?) -> RekordboxShareLocalFile? {
        guard !files.isEmpty else { return nil }
        let fitting = files.filter { file in
            guard let duration, let other = file.durationSeconds else { return true }
            return abs(duration - other) <= RekordboxShareMatcher.durationTolerance
        }
        if Set(fitting.map(\.trackId)).count == 1 { return fitting[0] }
        guard fitting.count > 1, let duration else { return nil }
        let timed = fitting.compactMap { file in file.durationSeconds.map { (file, abs($0 - duration)) } }.sorted { $0.1 < $1.1 }
        guard timed.count == fitting.count, timed.count > 1 else { return nil }
        return timed[0].1 < timed[1].1 ? timed[0].0 : nil
    }

    private static func deduplicated(_ matches: [RekordboxFolderMatch]) -> [RekordboxFolderMatch] {
        var best: [String: Int] = [:]
        for (index, match) in matches.enumerated() {
            guard let id = match.outcome.importedTrackId else { continue }
            if let current = best[id] {
                let challenger = (match.item.richness, match.item.origin)
                let holder = (matches[current].item.richness, matches[current].item.origin)
                if challenger > holder { best[id] = index }
            } else {
                best[id] = index
            }
        }
        return matches.enumerated().map { index, match in
            guard let id = match.outcome.importedTrackId, best[id] != index else { return match }
            var copy = match
            copy.outcome = .duplicate(id)
            return copy
        }
    }

    static func summary(_ scan: RekordboxFolderScan, matches: [RekordboxFolderMatch], newAudioFiles: Int) -> RekordboxFolderSummary {
        var summary = RekordboxFolderSummary()
        summary.tracks = scan.tracks.count
        summary.playlists = scan.playlists.count
        summary.cues = scan.cueCount
        summary.grids = scan.gridCount
        summary.keys = scan.keyCount
        summary.audioFiles = scan.classification.audioFiles.count
        summary.newAudioFiles = newAudioFiles
        for match in matches {
            switch match.outcome {
            case .path, .fileName: summary.byFile += 1
            case .title: summary.byTitle += 1
            case .duplicate: summary.duplicates += 1
            case .ambiguous: summary.ambiguous += 1
            case .missing: summary.missing += 1
            }
        }
        return summary
    }
}

// MARK: - Import

struct RekordboxFolderResult: Equatable, Sendable {
    var tracks = 0
    var cues = 0
    var grids = 0
    var phrases = 0
    var playlists = 0
    var keptYours = 0
    var missing = 0
}

enum RekordboxFolderImporter {
    static let playlistPrefix = "rekordbox#"

    static func pairs(_ matches: [RekordboxFolderMatch]) -> [(track: RekordboxTrack, trackId: String, title: String)] {
        matches.compactMap { match in
            match.outcome.importedTrackId.map { (track: match.item.track, trackId: $0, title: match.item.title) }
        }
    }

    static func plan(_ matches: [RekordboxFolderMatch], store: CueStore, now: Int64 = CueTime.nowMillis()) async -> RekordboxImportPlan {
        let pairs = pairs(matches)
        let ids = pairs.map(\.trackId)
        let preps = await store.preps(forTracks: ids)
        let cues = await store.cues(forTracks: ids)
        return RekordboxImport.plan(pairs: pairs, localPreps: preps, localCues: cues, writerId: store.writerId, now: now)
    }

    static func apply(
        _ plan: RekordboxImportPlan,
        choices: [String: ImportChoice],
        matches: [RekordboxFolderMatch],
        playlists: [RekordboxFolderPlaylist],
        store: CueStore,
        now: Int64 = CueTime.nowMillis()
    ) async -> RekordboxFolderResult {
        var result = RekordboxFolderResult()
        let applied = await RekordboxImport.apply(plan, choices: choices, store: store, now: now)
        result.tracks = applied.prepared
        result.cues = applied.cues
        result.grids = plan.changes.filter { $0.prep.grid != nil }.count
        result.keptYours = plan.conflicts.filter { choices[$0.id] != .useImported }.count
        for match in matches {
            guard let trackId = match.outcome.importedTrackId else { continue }
            if match.item.phrases.count >= 2 {
                var prep = TrackPrep(trackId: trackId)
                prep.phrases = PrepField(match.item.phrases, source: .rekordbox, updatedAtMillis: now, writerId: store.writerId)
                let outcome = await store.applyCandidatePrep(prep)
                if outcome.blocked.contains(.phrases) { result.keptYours += 1 } else { result.phrases += 1 }
            }
            if let rekordboxId = match.item.rekordboxId {
                await link(trackId: trackId, item: match.item, rekordboxId: rekordboxId, store: store, now: now)
            }
        }
        let records = playlistRecords(playlists, matches: matches)
        if !records.isEmpty {
            let existing = await store.rekordboxPlaylists()
            await store.saveRekordboxPlaylists(merged(existing: existing, incoming: records))
        }
        result.playlists = records.count
        result.missing = matches.filter { $0.outcome.linkedTrackId == nil }.count
        return result
    }

    static func link(trackId: String, item: RekordboxFolderTrack, rekordboxId: String, store: CueStore, now: Int64) async {
        if var existing = await store.link(forTrack: trackId) {
            guard existing.rekordboxTrackId != rekordboxId else { return }
            existing.rekordboxTrackId = rekordboxId
            await store.saveLink(existing, now: now)
            return
        }
        await store.saveLink(TrackLink(
            trackId: trackId,
            title: item.title,
            artist: item.track.artist,
            durationMillis: CueTime.millis(fromSeconds: item.track.totalTime),
            rekordboxTrackId: rekordboxId
        ), now: now)
    }

    static func playlistRecords(_ playlists: [RekordboxFolderPlaylist], matches: [RekordboxFolderMatch]) -> [RekordboxPlaylistRecord] {
        let ids = Dictionary(
            matches.compactMap { match in match.outcome.linkedTrackId.map { (match.item.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var out: [RekordboxPlaylistRecord] = []
        for playlist in playlists {
            var trackIds: [String] = []
            var inList = Set<String>()
            for key in playlist.trackKeys {
                if let id = ids[key], inList.insert(id).inserted { trackIds.append(id) }
            }
            guard !trackIds.isEmpty, seen.insert(playlist.fullPath).inserted else { continue }
            out.append(RekordboxPlaylistRecord(id: playlistPrefix + playlist.fullPath, name: playlist.name, path: playlist.path, trackIds: trackIds))
        }
        return out
    }

    static func merged(existing: [RekordboxPlaylistRecord], incoming: [RekordboxPlaylistRecord]) -> [RekordboxPlaylistRecord] {
        func key(_ record: RekordboxPlaylistRecord) -> String { (record.path + [record.name]).joined(separator: "/") }
        var pending = Dictionary(incoming.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var out: [RekordboxPlaylistRecord] = []
        var placed = Set<String>()
        for record in existing {
            let recordKey = key(record)
            if let replacement = pending.removeValue(forKey: recordKey) {
                out.append(replacement)
                placed.insert(recordKey)
            } else if !placed.contains(recordKey) {
                out.append(record)
            }
        }
        for record in incoming where pending[key(record)] != nil {
            out.append(record)
            pending[key(record)] = nil
        }
        return out
    }
}
