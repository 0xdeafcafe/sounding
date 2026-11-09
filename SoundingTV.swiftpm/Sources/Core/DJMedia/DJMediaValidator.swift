import Foundation

struct DJValidationIssue: Equatable, Sendable, CustomStringConvertible {
    enum Severity: Sendable { case error, warning }

    var severity: Severity
    var message: String

    var description: String { "\(severity == .error ? "error" : "warning"): \(message)" }
}

struct DJValidationReport: Sendable {
    var issues: [DJValidationIssue] = []
    var database: PDBDatabase?

    var errors: [DJValidationIssue] { issues.filter { $0.severity == .error } }
    var isValid: Bool { errors.isEmpty }

    mutating func error(_ m: String) { issues.append(DJValidationIssue(severity: .error, message: m)) }
    mutating func warn(_ m: String) { issues.append(DJValidationIssue(severity: .warning, message: m)) }
}

enum DJMediaValidator {
    static let requiredTables: [PDBTableType] = [
        .tracks, .genres, .artists, .albums, .labels, .keys, .colors, .playlistTree, .playlistEntries, .artwork,
    ]

    static func validate(exportRoot root: URL) -> DJValidationReport {
        let visible = root.appending(path: "PIONEER/rekordbox/export.pdb")
        let hidden = root.appending(path: ".PIONEER/rekordbox/export.pdb")
        guard let data = (try? Data(contentsOf: visible)) ?? (try? Data(contentsOf: hidden)) else {
            var r = DJValidationReport()
            r.error("PIONEER/rekordbox/export.pdb is missing")
            return r
        }
        return validate(pdb: data, file: { path in
            try? Data(contentsOf: root.appending(path: String(path.drop { $0 == "/" })))
        }, fileSize: { path in
            let url = root.appending(path: String(path.drop { $0 == "/" }))
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        })
    }

    static func validate(
        pdb data: Data,
        file: (String) -> Data?,
        fileSize: (String) -> Int64?
    ) -> DJValidationReport {
        var report = DJValidationReport()
        let result: PDBReadResult
        do {
            result = try PDBReader.read(data)
        } catch {
            report.error("export.pdb cannot be read: \(error)")
            return report
        }
        report.database = result.database
        for issue in result.issues { report.error("export.pdb: \(issue)") }
        checkStructure(data, result, &report)
        checkReferences(result.database, &report)
        for track in result.database.tracks {
            checkTrack(track, file: file, fileSize: fileSize, &report)
        }
        for art in result.database.artwork where fileSize(art.path) == nil {
            report.error("artwork \(art.id) \(art.path) is missing")
        }
        return report
    }

    // MARK: - Pages

    static func checkStructure(_ data: Data, _ result: PDBReadResult, _ report: inout DJValidationReport) {
        let db = result.database
        if db.pageSize != 4096 { report.warn("page size \(db.pageSize), players expect 4096") }
        if data.count % db.pageSize != 0 { report.error("file length \(data.count) is not a whole number of pages") }
        let types = Set(db.tables.map(\.type))
        for t in requiredTables where !types.contains(t.rawValue) {
            report.error("table \(t) is missing")
        }
        if Set(db.tables.map(\.firstPage)).count != db.tables.count { report.error("two tables share a first page") }
        var owner: [UInt32: UInt32] = [:]
        for table in db.tables {
            let pages = result.pages[table.type] ?? []
            guard let first = pages.first else {
                report.error("table \(table.type) has no readable pages")
                continue
            }
            if !first.isIndexPage { report.warn("table \(table.type) does not start with an index page") }
            if let last = pages.last {
                if last.index != table.lastPage { report.error("table \(table.type) chain ends at \(last.index), header says \(table.lastPage)") }
                if last.nextPage != table.emptyCandidate {
                    report.warn("table \(table.type) last page links to \(last.nextPage), empty candidate is \(table.emptyCandidate)")
                }
            }
            for page in pages {
                if let other = owner[page.index], other != table.type {
                    report.error("page \(page.index) belongs to tables \(other) and \(table.type)")
                }
                owner[page.index] = table.type
                guard !page.isIndexPage else { continue }
                if page.flags & 0x24 != 0x24 { report.warn("table \(table.type) page \(page.index) flags \(page.flags)") }
                let directory = PDBWriter.directoryBytes(page.slotCount)
                if page.freeSize + page.usedSize + directory != db.pageSize - PDBReader.pageHeaderSize {
                    report.error("table \(table.type) page \(page.index): free \(page.freeSize) + used \(page.usedSize) + directory \(directory) does not add up")
                }
                if page.presentCount != page.rowOffsets.count {
                    report.error("table \(table.type) page \(page.index): \(page.presentCount) rows declared, \(page.rowOffsets.count) present")
                }
                if page.rowOffsets.contains(where: { $0 >= PDBReader.pageHeaderSize + page.usedSize }) {
                    report.error("table \(table.type) page \(page.index): a row starts beyond the used heap")
                }
            }
        }
    }

    // MARK: - Rows

    static func checkReferences(_ db: PDBDatabase, _ report: inout DJValidationReport) {
        func ids<T>(_ rows: [T], _ id: (T) -> UInt32, _ name: String) -> Set<UInt32> {
            let all = rows.map(id)
            let set = Set(all)
            if set.count != all.count { report.error("duplicate \(name) ids") }
            if set.contains(0) { report.error("\(name) id 0 is reserved") }
            return set
        }
        let artists = ids(db.artists, \.id, "artist")
        let albums = ids(db.albums, \.id, "album")
        let genres = ids(db.genres, \.id, "genre")
        let labels = ids(db.labels, \.id, "label")
        let keys = ids(db.keys, \.id, "key")
        let artwork = ids(db.artwork, \.id, "artwork")
        let tracks = ids(db.tracks, \.id, "track")
        let nodes = ids(db.playlistTree, \.id, "playlist")
        if db.colors.count != 8 { report.warn("\(db.colors.count) colour rows, rekordbox writes 8") }

        for t in db.tracks {
            func ref(_ value: UInt32, _ set: Set<UInt32>, _ what: String) {
                if value != 0, !set.contains(value) { report.error("track \(t.id) points at missing \(what) \(value)") }
            }
            ref(t.artistId, artists, "artist")
            ref(t.composerId, artists, "composer")
            ref(t.remixerId, artists, "remixer")
            ref(t.originalArtistId, artists, "original artist")
            ref(t.albumId, albums, "album")
            ref(t.genreId, genres, "genre")
            ref(t.labelId, labels, "label")
            ref(t.keyId, keys, "key")
            ref(t.artworkId, artwork, "artwork")
            if t.colorId > 8 { report.error("track \(t.id) colour \(t.colorId) is outside 0–8") }
            if t.rating > 5 { report.error("track \(t.id) rating \(t.rating) is outside 0–5") }
        }
        for album in db.albums where album.artistId != 0 && !artists.contains(album.artistId) {
            report.error("album \(album.id) points at missing artist \(album.artistId)")
        }

        let folders = Set(db.playlistTree.filter(\.isFolder).map(\.id))
        for node in db.playlistTree {
            if node.parentId != 0, !folders.contains(node.parentId) {
                report.error("playlist \(node.id) has missing parent folder \(node.parentId)")
            }
            var seen: Set<UInt32> = [node.id]
            var parent = node.parentId
            while parent != 0, let p = db.playlistTree.first(where: { $0.id == parent }) {
                if !seen.insert(p.id).inserted {
                    report.error("playlist tree loops at \(p.id)")
                    break
                }
                parent = p.parentId
            }
        }
        var entryKeys = Set<String>()
        for e in db.playlistEntries {
            if !tracks.contains(e.trackId) { report.error("playlist \(e.playlistId) entry \(e.entryIndex) points at missing track \(e.trackId)") }
            if !nodes.contains(e.playlistId) || folders.contains(e.playlistId) {
                report.error("playlist entry for track \(e.trackId) points at \(e.playlistId), which is not a playlist")
            }
            if !entryKeys.insert("\(e.playlistId)/\(e.entryIndex)").inserted {
                report.error("playlist \(e.playlistId) has two entries at position \(e.entryIndex)")
            }
        }
    }

    // MARK: - Tracks and analysis

    static func checkTrack(
        _ t: PDBTrack,
        file: (String) -> Data?,
        fileSize: (String) -> Int64?,
        _ report: inout DJValidationReport
    ) {
        let path = t.filePath
        guard path.hasPrefix("/"), path.count > 1 else {
            report.error("track \(t.id) has no file path")
            return
        }
        if t.title.isEmpty { report.warn("track \(t.id) has no title") }
        if t[.filename] != (path as NSString).lastPathComponent { report.warn("track \(t.id) file name does not match its path") }
        if PDBFileType(rawValue: t.fileType) == nil || t.fileType == 0 { report.error("track \(t.id) file type \(t.fileType) is unknown") }
        if t.duration == 0 { report.error("track \(t.id) has no duration") }
        if t.tempo > 0, !(2000 ... 99900).contains(t.tempo) { report.warn("track \(t.id) tempo \(t.bpm) looks wrong") }
        for component in path.split(separator: "/") {
            if component.unicodeScalars.contains(where: { DJDevicePath.illegal.contains($0) || $0.value < 0x20 }) {
                report.error("track \(t.id) path component \(component) is not FAT-safe")
            }
        }
        if let size = fileSize(path) {
            if t.fileSize != 0, Int64(t.fileSize) != size {
                report.error("track \(t.id) file is \(size) bytes, database says \(t.fileSize)")
            }
        } else {
            report.error("track \(t.id) audio \(path) is missing")
        }

        let expectedDirectory = DJAnalysisPath.directory(for: path)
        let hiddenDirectory = "/." + expectedDirectory.dropFirst()
        let analyzePath = t.analyzePath
        let inExpectedFolder = analyzePath.hasPrefix(expectedDirectory + "/ANLZ") || analyzePath.hasPrefix(hiddenDirectory + "/ANLZ")
        if !inExpectedFolder || !analyzePath.hasSuffix(".DAT") {
            report.error("track \(t.id) analysis path \(analyzePath) is not where players look (\(expectedDirectory))")
        }
        let base = String(analyzePath.dropLast(4))
        let duration = Double(t.duration)
        for (ext, required) in [(".DAT", true), (".EXT", true), (".2EX", false)] {
            guard let data = file(base + ext) else {
                if required { report.error("track \(t.id) is missing \(base + ext)") }
                continue
            }
            do {
                let anlz = try ANLZCodec.read(data)
                for issue in anlz.issues { report.error("\(base + ext): \(issue)") }
                checkAnalysis(anlz.file, trackPath: path, duration: duration, isExtended: ext == ".EXT", isThreeBand: ext == ".2EX", name: base + ext, &report)
            } catch {
                report.error("\(base + ext) cannot be read: \(error)")
            }
        }
    }

    static func checkAnalysis(
        _ f: ANLZFile,
        trackPath: String,
        duration: Double,
        isExtended: Bool,
        isThreeBand: Bool = false,
        name: String,
        _ report: inout DJValidationReport
    ) {
        if f.path != trackPath { report.error("\(name) belongs to \(f.path ?? "nothing"), not \(trackPath)") }
        let limit = UInt32(max(0, duration + 2) * 1000)
        var beatCount = 0
        if let beats = f.beatGrid {
            beatCount = beats.count
            var previous: UInt32?
            for b in beats {
                if !(1 ... 16).contains(b.beatNumber) { report.error("\(name): beat number \(b.beatNumber)"); break }
                if b.tempo == 0 { report.error("\(name): beat with zero tempo"); break }
                if let previous, b.timeMillis <= previous { report.error("\(name): beat grid is not ascending"); break }
                if b.timeMillis > limit { report.error("\(name): beat after the end of the track"); break }
                previous = b.timeMillis
            }
        } else if !isExtended, !isThreeBand {
            report.error("\(name) has no beat grid tag")
        }
        for tag in f.tags {
            switch tag {
            case .cueList(let list), .extendedCueList(let list):
                var slots = Set<UInt32>()
                for cue in list.cues {
                    if list.kind == .hotCues {
                        if !(1 ... 8).contains(cue.hotCue) { report.error("\(name): hot cue number \(cue.hotCue)") }
                        if !slots.insert(cue.hotCue).inserted { report.error("\(name): hot cue \(cue.hotCue) appears twice") }
                    } else if cue.hotCue != 0 {
                        report.error("\(name): memory cue with hot cue number \(cue.hotCue)")
                    }
                    if cue.timeMillis > limit { report.error("\(name): cue after the end of the track") }
                    if cue.isLoop, cue.loopTimeMillis <= cue.timeMillis || cue.loopTimeMillis > limit {
                        report.error("\(name): loop at \(cue.timeMillis) ms has a bad end")
                    }
                }
            case .waveformPreview(let d) where d.count != 400:
                report.error("\(name): PWAV has \(d.count) columns, players expect 400")
            case .tinyWaveformPreview(let d) where d.count != 100:
                report.error("\(name): PWV2 has \(d.count) columns, players expect 100")
            case .colorWaveformPreview(let d) where d.count != 7200:
                report.error("\(name): PWV4 has \(d.count) bytes, players expect 7200")
            case .waveformDetail(let d):
                checkDetailLength(d.count, duration: duration, tag: "PWV3", name: name, &report)
            case .colorWaveformDetail(let d):
                checkDetailLength(d.count, duration: duration, tag: "PWV5", name: name, &report)
            case .threeBandPreview(let d):
                if d.count != DJWaveformSynth.threeBandPreviewColumns * 3 {
                    report.error("\(name): PWV6 has \(d.count) bytes, players expect 3600")
                }
            case .threeBandDetail(let d):
                checkDetailLength(d.count / 3, duration: duration, tag: "PWV7", name: name, &report)
            case .songStructure(let s):
                if !(1 ... 3).contains(s.mood) { report.error("\(name): phrase mood \(s.mood)") }
                var last: UInt16 = 0
                for p in s.phrases {
                    if p.beat <= last { report.error("\(name): phrases are not ascending"); break }
                    if beatCount > 0, Int(p.beat) > beatCount { report.error("\(name): phrase starts beyond the beat grid"); break }
                    last = p.beat
                }
                if s.endBeat < last { report.error("\(name): phrase end beat precedes the last phrase") }
            default:
                break
            }
        }
        if isThreeBand {
            for code in ["PPTH", "PWV6", "PWV7"] where f.tag(code) == nil { report.error("\(name) has no \(code) tag") }
            return
        }
        let required = isExtended ? ["PPTH", "PWV3", "PCO2", "PWV5", "PWV4"] : ["PPTH", "PQTZ", "PWAV", "PWV2", "PCOB"]
        for code in required where f.tag(code) == nil { report.error("\(name) has no \(code) tag") }
    }

    static func checkDetailLength(_ count: Int, duration: Double, tag: String, name: String, _ report: inout DJValidationReport) {
        let expected = DJWaveformSynth.detailCount(duration: duration)
        if abs(count - expected) > 300 {
            report.warn("\(name): \(tag) has \(count) entries, expected about \(expected)")
        }
    }
}
