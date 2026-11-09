import Foundation

struct DJExportOptions: Sendable {
    enum Destination: Equatable, Sendable {
        case newFolder(name: String?)
        case volumeRoot
        case replaceExistingLibrary
    }

    var destination: Destination = .newFolder(name: nil)
    var keyNotation: DJExportKey.Notation = .classic
    var writeSongStructure = true
    var maskSongStructure = true
    var autoloadHotCues = true
    var writeThreeBandWaveform = true
    var verifyCopiedAudio = true
}

struct DJPlannedAnalysis: Equatable, Sendable {
    var trackID: UInt32
    var directory: String
    var baseName: String
    var dat: ANLZFile
    var ext: ANLZFile
    var ex2: ANLZFile?

    var datPath: String { "\(directory)/\(baseName).DAT" }
    var extPath: String { "\(directory)/\(baseName).EXT" }
    var ex2Path: String { "\(directory)/\(baseName).2EX" }
}

struct DJPlannedCopy: Equatable, Sendable {
    var exportID: String
    var source: URL
    var devicePath: String
}

struct DJPlannedArtwork: Equatable, Sendable {
    var devicePath: String
    var largeDevicePath: String
    var jpeg: Data
}

struct DJSkippedTrack: Equatable, Sendable {
    var id: String
    var reason: String
}

struct DJExportPlan: Equatable, Sendable {
    var database: PDBDatabase
    var analysis: [DJPlannedAnalysis]
    var copies: [DJPlannedCopy]
    var artwork: [DJPlannedArtwork]
    var skipped: [DJSkippedTrack]
    var warnings: [String]
}

enum DJExportPlanner {
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "flac", "wav", "wave", "aif", "aiff"]
    static let maxFileSize: Int64 = 0xFFFF_FFFF

    static func plan(
        tracks: [any DJExportTrack],
        playlists: [DJExportPlaylist],
        options: DJExportOptions = DJExportOptions(),
        now: Date = Date()
    ) throws -> DJExportPlan {
        var db = PDBDatabase.exportDefaults()
        var analysis: [DJPlannedAnalysis] = []
        var copies: [DJPlannedCopy] = []
        var artworkFiles: [DJPlannedArtwork] = []
        var skipped: [DJSkippedTrack] = []
        var warnings: [String] = []

        var artistIDs: [String: UInt32] = [:]
        var albumIDs: [String: UInt32] = [:]
        var genreIDs: [String: UInt32] = [:]
        var labelIDs: [String: UInt32] = [:]
        var keyIDs: [String: UInt32] = [:]
        var usedPaths = Set<String>()
        var usedAnalysis: [String: Int] = [:]
        var trackIDs: [String: UInt32] = [:]

        func artist(_ name: String) -> UInt32 {
            guard !name.isEmpty else { return 0 }
            if let id = artistIDs[name] { return id }
            let id = UInt32(db.artists.count + 1)
            db.artists.append(PDBArtist(id: id, name: name))
            artistIDs[name] = id
            return id
        }

        func named(_ name: String, _ ids: inout [String: UInt32], _ rows: inout [PDBNamedRow]) -> UInt32 {
            guard !name.isEmpty else { return 0 }
            if let id = ids[name] { return id }
            let id = UInt32(rows.count + 1)
            rows.append(PDBNamedRow(id: id, name: name))
            ids[name] = id
            return id
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: now)

        for track in tracks {
            let source = track.audioFileURL
            guard source.isFileURL else {
                skipped.append(DJSkippedTrack(id: track.exportID, reason: "not a local file"))
                continue
            }
            let ext = source.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                skipped.append(DJSkippedTrack(id: track.exportID, reason: "unsupported audio format .\(ext)"))
                continue
            }
            guard trackIDs[track.exportID] == nil else {
                warnings.append("duplicate track \(track.exportID) ignored")
                continue
            }
            let meta = track.metadata
            guard meta.fileSize <= maxFileSize else {
                skipped.append(DJSkippedTrack(id: track.exportID, reason: "larger than 4 GB"))
                continue
            }
            guard meta.durationSeconds.isFinite, meta.durationSeconds > 0 else {
                skipped.append(DJSkippedTrack(id: track.exportID, reason: "unknown duration"))
                continue
            }

            let artistFolder = DJDevicePath.component(meta.artist, fallback: "UnknownArtist")
            let albumFolder = DJDevicePath.component(meta.album, fallback: "UnknownAlbum")
            let fileName = DJDevicePath.fileName(source.lastPathComponent, fallback: "Track")
            var devicePath = "/Contents/\(artistFolder)/\(albumFolder)/\(fileName)"
            var n = 2
            while usedPaths.contains(devicePath.lowercased()) {
                let stem = (fileName as NSString).deletingPathExtension
                let suffix = (fileName as NSString).pathExtension
                devicePath = "/Contents/\(artistFolder)/\(albumFolder)/\(stem) (\(n)).\(suffix)"
                n += 1
            }
            usedPaths.insert(devicePath.lowercased())

            let id = UInt32(db.tracks.count + 1)
            trackIDs[track.exportID] = id
            let directory = DJAnalysisPath.directory(for: devicePath)
            let slot = usedAnalysis[directory, default: 0]
            usedAnalysis[directory] = slot + 1
            let baseName = String(format: "ANLZ%04d", slot)

            var row = PDBTrack(id: id)
            row.artistId = artist(meta.artist)
            row.composerId = artist(meta.composer)
            row.remixerId = artist(meta.remixer)
            row.originalArtistId = artist(meta.originalArtist)
            if !meta.album.isEmpty {
                let albumKey = "\(meta.album)\u{0}\(row.artistId)"
                if let existing = albumIDs[albumKey] {
                    row.albumId = existing
                } else {
                    let albumID = UInt32(db.albums.count + 1)
                    db.albums.append(PDBAlbum(id: albumID, name: meta.album, artistId: row.artistId))
                    albumIDs[albumKey] = albumID
                    row.albumId = albumID
                }
            }
            row.genreId = named(meta.genre, &genreIDs, &db.genres)
            row.labelId = named(meta.label, &labelIDs, &db.labels)
            if let key = track.key {
                let name = key.name(options.keyNotation)
                if let existing = keyIDs[name] {
                    row.keyId = existing
                } else {
                    let keyID = UInt32(db.keys.count + 1)
                    db.keys.append(PDBKey(id: keyID, name: name))
                    keyIDs[name] = keyID
                    row.keyId = keyID
                }
            }
            row.sampleRate = UInt32(clamping: max(0, meta.sampleRate))
            row.sampleDepth = UInt16(clamping: max(0, meta.bitDepth))
            row.bitrate = UInt32(clamping: max(0, meta.bitrateKbps))
            row.fileSize = UInt32(clamping: max(0, meta.fileSize))
            row.unknown2 = stableNonZero(devicePath)
            row.trackNumber = UInt32(clamping: max(0, meta.trackNumber))
            row.discNumber = UInt16(clamping: max(0, meta.discNumber))
            row.year = UInt16(clamping: max(0, meta.year))
            row.duration = UInt16(clamping: Int(meta.durationSeconds.rounded()))
            row.rating = UInt8(clamping: min(5, max(0, meta.rating)))
            row.colorId = DJMediaColor.trackColorId(meta.colorRGB)
            row.fileType = PDBFileType(pathExtension: ext).rawValue
            if let grid = track.beatGrid, grid.bpm.isFinite, grid.bpm > 0 {
                row.tempo = UInt32(DJAnalysisMapping.tempo(grid.bpm))
            }
            row[.isrc] = meta.isrc
            row[.autoloadHotCues] = options.autoloadHotCues ? "ON" : ""
            row[.dateAdded] = meta.dateAdded.map(dateFormatter.string(from:)) ?? today
            row[.releaseDate] = meta.releaseDate
            row[.mixName] = meta.mixName
            row[.analyzePath] = "\(directory)/\(baseName).DAT"
            row[.analyzeDate] = today
            row[.comment] = meta.comment
            row[.title] = meta.title.isEmpty ? (fileName as NSString).deletingPathExtension : meta.title
            row[.filename] = (devicePath as NSString).lastPathComponent
            row[.filePath] = devicePath

            if let jpeg = meta.artworkJPEG, !jpeg.isEmpty {
                let artID = UInt32(db.artwork.count + 1)
                let folder = String(format: "/PIONEER/Artwork/%05d", (artID - 1) / 1000 + 1)
                let path = "\(folder)/a\(artID).jpg"
                db.artwork.append(PDBArtwork(id: artID, path: path))
                artworkFiles.append(DJPlannedArtwork(devicePath: path, largeDevicePath: "\(folder)/a\(artID)_m.jpg", jpeg: jpeg))
                row.artworkId = artID
            }

            _ = try PDBWriter.encodeTrack(row)
            db.tracks.append(row)
            copies.append(DJPlannedCopy(exportID: track.exportID, source: source, devicePath: devicePath))
            let files = analysisFiles(for: track, devicePath: devicePath, ext: ext, options: options)
            analysis.append(DJPlannedAnalysis(trackID: id, directory: directory, baseName: baseName, dat: files.dat, ext: files.ext, ex2: files.ex2))
        }

        var nextNode: UInt32 = 1
        func addNodes(_ nodes: [DJExportPlaylist], parent: UInt32) {
            for (order, node) in nodes.enumerated() {
                let nodeID = nextNode
                nextNode += 1
                db.playlistTree.append(PDBPlaylistNode(
                    id: nodeID, parentId: parent, sortOrder: UInt32(order),
                    isFolder: node.isFolder, name: node.name.isEmpty ? "Untitled" : node.name
                ))
                if node.isFolder {
                    addNodes(node.children, parent: nodeID)
                } else {
                    var index: UInt32 = 1
                    for exportID in node.trackIDs {
                        guard let trackID = trackIDs[exportID] else {
                            warnings.append("playlist \(node.name): track \(exportID) not exported")
                            continue
                        }
                        db.playlistEntries.append(PDBPlaylistEntry(entryIndex: index, trackId: trackID, playlistId: nodeID))
                        index += 1
                    }
                }
            }
        }
        addNodes(playlists, parent: 0)

        return DJExportPlan(
            database: db, analysis: analysis, copies: copies, artwork: artworkFiles,
            skipped: skipped, warnings: warnings
        )
    }

    static func stableNonZero(_ text: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for byte in text.utf8 { h = (h ^ UInt32(byte)) &* 0x0100_0193 }
        return h == 0 ? 1 : h
    }

    static func analysisFiles(
        for track: any DJExportTrack,
        devicePath: String,
        ext: String,
        options: DJExportOptions
    ) -> (dat: ANLZFile, ext: ANLZFile, ex2: ANLZFile?) {
        let duration = track.metadata.durationSeconds
        let beats = track.beatGrid.map { DJAnalysisMapping.beats(for: $0, duration: duration) } ?? []
        let cues = DJAnalysisMapping.cueLists(track.cues, grid: track.beatGrid)
        let legacyHot = cues.hot.filter { $0.hotCue <= 3 }
        let rendered = DJWaveformSynth.render(track.waveform ?? DJExportWaveform(amplitude: []), duration: duration)

        var totalSamples: UInt32 = 0
        if ext == "mp3" {
            let samples = duration * Double(max(1, track.metadata.sampleRate))
            let frames = (samples / 1152).rounded(.up)
            totalSamples = UInt32(clamping: Int(min(frames * 1152, Double(UInt32.max))))
        }

        var dat = ANLZFile()
        dat.tags = [
            .path(devicePath),
            .vbr(totalSamples: totalSamples),
            .beatGrid(beats),
            .waveformPreview(rendered.preview),
            .tinyWaveformPreview(rendered.tinyPreview),
            .cueList(ANLZCueList(kind: .hotCues, cues: legacyHot, memoryCount: legacyHot.isEmpty ? 0xFFFF_FFFF : UInt32(legacyHot.count))),
            .cueList(ANLZCueList(kind: .memory, cues: cues.memory, memoryCount: cues.memory.isEmpty ? 0xFFFF_FFFF : UInt32(cues.memory.count))),
        ]

        var extFile = ANLZFile()
        extFile.tags = [
            .path(devicePath),
            .waveformDetail(rendered.detail),
            .cueList(ANLZCueList(kind: .hotCues, cues: legacyHot, memoryCount: legacyHot.isEmpty ? 0xFFFF_FFFF : UInt32(legacyHot.count))),
            .cueList(ANLZCueList(kind: .memory, cues: cues.memory, memoryCount: cues.memory.isEmpty ? 0xFFFF_FFFF : UInt32(cues.memory.count))),
            .extendedCueList(ANLZCueList(kind: .hotCues, cues: cues.hot)),
            .extendedCueList(ANLZCueList(kind: .memory, cues: cues.memory)),
            .colorWaveformDetail(rendered.colorDetail),
            .colorWaveformPreview(rendered.colorPreview),
        ]
        if options.writeSongStructure, let phrases = track.phrases,
           var structure = DJAnalysisMapping.songStructure(phrases, beats: beats, duration: duration) {
            structure.masked = options.maskSongStructure
            extFile.tags.append(.songStructure(structure))
        }
        var ex2File: ANLZFile?
        if options.writeThreeBandWaveform, track.waveform?.hasBands == true {
            var file = ANLZFile()
            file.tags = [
                .path(devicePath),
                .threeBandPreview(rendered.threeBandPreview),
                .threeBandDetail(rendered.threeBandDetail),
            ]
            ex2File = file
        }
        return (dat, extFile, ex2File)
    }
}
