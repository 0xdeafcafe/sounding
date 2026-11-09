import Foundation

extension RekordboxFolderReaders {
    static func live(io: DJStickIO = DJStickPOSIXIO()) -> RekordboxFolderReaders {
        RekordboxFolderReaders(
            xml: { path in try? io.readFile(atPath: path, maxBytes: RekordboxXML.maximumBytes) },
            stick: { root in RekordboxFolderStickReader.stick(root: root, io: io) },
            analysis: { root in RekordboxFolderStickReader.analysis(root: root, io: io) }
        )
    }
}

enum RekordboxFolderStickReader {
    static func stick(root: String, io: DJStickIO) -> RekordboxFolderStick? {
        guard let loaded = try? DJStickLoader.load(root: root, io: io) else { return nil }
        let tracks = loaded.library.tracks.map { track(from: $0, root: root, io: io) }
        let playlists = loaded.library.playlists.map {
            RekordboxFolderPlaylist(path: $0.path, name: $0.name, trackKeys: $0.trackIds.map { String($0) })
        }
        return RekordboxFolderStick(tracks: tracks, playlists: playlists)
    }

    static func track(from stickTrack: DJStickTrack, root: String, io: DJStickIO) -> RekordboxFolderStickTrack {
        let read = analysis(for: stickTrack, root: root, io: io)
        return RekordboxFolderStickTrack(
            id: stickTrack.id,
            title: stickTrack.title,
            artist: stickTrack.artist,
            album: stickTrack.album,
            durationSeconds: stickTrack.durationSeconds,
            bpm: stickTrack.bpm,
            keyName: stickTrack.keyName,
            comment: stickTrack.comment,
            colourId: stickTrack.colourId,
            rating: stickTrack.rating,
            filePath: stickTrack.filePath,
            tempos: read.analysis.tempos.map {
                RekordboxTempo(inizio: $0.startSeconds, bpm: $0.bpm, metro: "4/4", battito: $0.beatInBar)
            },
            marks: read.analysis.marks.map {
                RekordboxMark(name: $0.label, type: $0.xmlType, start: $0.startSeconds, end: $0.endSeconds, num: $0.xmlNum, red: $0.red, green: $0.green, blue: $0.blue)
            },
            phrases: read.phrases,
            hasWaveform: !read.analysis.overview.isEmpty
        )
    }

    static func analysis(for stickTrack: DJStickTrack, root: String, io: DJStickIO) -> (analysis: DJStickAnalysis, phrases: [PrepPhrase]) {
        guard let datPath = DJStickLayout.safeDevicePath(stickTrack.analyzePath) else { return (DJStickAnalysis(), []) }
        let dat = anlz(io, DJStickLayout.join(root, datPath))
        var extPath = datPath
        if extPath.uppercased().hasSuffix(".DAT") { extPath = String(extPath.dropLast(3)) + "EXT" }
        let ext = extPath == datPath ? nil : anlz(io, DJStickLayout.join(root, extPath))
        guard let primary = dat ?? ext else { return (DJStickAnalysis(), []) }
        if let entry = RekordboxShareScanner.entry(id: String(stickTrack.id), dat: primary, ext: ext, twoEx: nil) {
            return (entry.analysis, RekordboxShareMapping.phrases(entry))
        }
        return (DJStickAnalysis.summarise(dat: dat, ext: ext), [])
    }

    static func analysis(root: String, io: DJStickIO) -> RekordboxFolderAnalysis {
        let share = RekordboxShareScanner.scan(root: root, io: io)
        let entries = share.entries.map { entry in
            RekordboxFolderAnalysisEntry(
                id: entry.id,
                devicePath: entry.devicePath,
                fileName: entry.fileName,
                track: RekordboxShareMapping.rekordboxTrack(RekordboxShareMatch(entry: entry, outcome: .missing, xml: nil)),
                phrases: RekordboxShareMapping.phrases(entry),
                hasWaveform: !entry.analysis.overview.isEmpty || entry.hasThreeBandWaveform
            )
        }
        return RekordboxFolderAnalysis(entries: entries, unreadable: share.unreadable)
    }

    private static func anlz(_ io: DJStickIO, _ path: String) -> ANLZFile? {
        guard let data = try? io.readFile(atPath: path, maxBytes: DJStickLayout.maxAnalysisBytes) else { return nil }
        return try? ANLZCodec.read(data).file
    }
}
