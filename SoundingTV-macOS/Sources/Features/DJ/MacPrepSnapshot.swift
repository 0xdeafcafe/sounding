#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum MacPrepFixtures {

    static func makeStore() -> CueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPrepFixtures-\(UUID().uuidString)", isDirectory: true)
        return CueStore(directory: directory, writerId: "fixture-mac")
    }

    static var tracks: [Track] { Array(VisualFixtures.tracks.prefix(12)) }

    static func envelope(seed: String, duration: TimeInterval) -> [Float] {
        let count = 1_200
        let phase = Double(abs(seed.hashValue % 97)) / 97
        return (0..<count).map { index in
            let t = Double(index) / Double(count)
            let base: Double
            switch t {
            case ..<0.08: base = 0.18
            case ..<0.32: base = 0.55
            case ..<0.46: base = 0.92
            case ..<0.56: base = 0.22
            case ..<0.84: base = 0.95
            default:      base = 0.35
            }
            let ripple = 0.06 * sin(Double(index) * 0.9 + phase * 6) + 0.04 * sin(Double(index) * 0.13)
            return Float(max(0.02, min(1, base + ripple)))
        }
    }

    static func source() -> MacPrepTrackSource {
        MacPrepTrackSource(
            track: { id in VisualFixtures.tracks.first { $0.id == id } },
            envelope: { id, duration in envelope(seed: id, duration: duration) }
        )
    }

    static func seed(_ store: CueStore) async {
        let bpms: [Double] = [124, 122, 126, 128, 123, 125, 120, 127, 124, 126, 118, 130]
        let keys = ["8A", "9A", "4A", "11B", "5A", "8B", "7A", "10A", "6A", "2A", "3B", "12A"]
        for (index, track) in tracks.enumerated() {
            let id = track.id
            let link = TrackLink(
                trackId: id,
                title: track.title,
                artist: track.user.username,
                durationMillis: CueTime.millis(fromSeconds: track.duration),
                rekordboxTrackId: String(91_234_500 + index)
            )
            await store.saveLink(link)
            if index % 3 != 2 {
                await store.saveLinkFile(TrackLinkFile(trackId: id, bookmark: Data([1]), path: "/Users/dj/Music/DJ/\(track.title).mp3"))
            }
            var prep = TrackPrep(trackId: id)
            let grid = PrepGrid(
                segments: [PrepTempoSegment(startMillis: 120 + Int64(index * 7), bpm: bpms[index])],
                locked: index == 0 || index == 4
            )
            prep.grid = PrepField(grid, source: index == 0 ? .user : .rekordbox, updatedAtMillis: 1, writerId: "fixture")
            prep.key = PrepField(PrepKey(camelot: keys[index], original: keys[index]), source: .rekordbox, updatedAtMillis: 1, writerId: "fixture")
            await store.savePrep(prep)

            let bar = 240 / bpms[index]
            let anchor = 0.12 + Double(index) * 0.007
            func at(_ bars: Double) -> Int64 { CueTime.millis(fromSeconds: anchor + bars * bar) }
            await store.upsert(CuePoint(trackId: id, kind: .hotCue, positionMillis: at(16), hotCueIndex: 0, label: "Drop", origin: .imported))
            await store.upsert(CuePoint(trackId: id, kind: .hotCue, positionMillis: at(48), hotCueIndex: 1, label: "Break", origin: .imported))
            if index % 2 == 0 {
                await store.upsert(CuePoint(trackId: id, kind: .hotCue, positionMillis: at(64), hotCueIndex: 3, label: "Vocal"))
                await store.upsert(CuePoint(trackId: id, kind: .loop, positionMillis: at(80), endMillis: at(81), hotCueIndex: 4, label: "Roll"))
            }
            await store.upsert(CuePoint(trackId: id, kind: .memory, positionMillis: at(0), label: ""))
            await store.upsert(CuePoint(trackId: id, kind: .memory, positionMillis: at(32), label: "Mix in here"))
            await store.upsert(CuePoint(id: "\(id)#loop#fixture", trackId: id, kind: .loop, positionMillis: at(88), endMillis: at(96), label: "Outro"))
        }
        let first = tracks[0]
        let bar = 240 / bpms[0]
        let landing = CueTime.millis(fromSeconds: 0.12 + 40 * bar)
        for session in ["a1", "a1", "a2", "a3"] {
            await store.recordListening(trackId: first.id, positionMillis: landing, sessionId: session)
        }
        await store.saveRekordboxPlaylists([
            RekordboxPlaylistRecord(id: "0#Warm-up", name: "Warm-up", path: [], trackIds: tracks.prefix(5).map(\.id)),
            RekordboxPlaylistRecord(id: "1#Gigs/Friday", name: "Friday", path: ["Gigs"], trackIds: tracks.suffix(6).map(\.id)),
        ])
    }

    static func library(store: CueStore) -> MacRekordboxLibrary {
        let defaults = UserDefaults(suiteName: "MacPrepFixtures-\(UUID().uuidString)") ?? .standard
        let candidates = VisualFixtures.tracks.map {
            MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
        } + [MatchCandidate(trackId: "dup-1", title: VisualFixtures.tracks[2].title, artist: VisualFixtures.tracks[2].user.username, durationSeconds: VisualFixtures.tracks[2].duration + 1)]
        return MacRekordboxLibrary(store: store, defaults: defaults, candidates: { candidates })
    }

    static func rekordboxLibrary() -> RekordboxLibrary {
        var tracks: [RekordboxTrack] = VisualFixtures.tracks.prefix(14).enumerated().map { index, track in
            let bpm = 120.0 + Double(index % 8)
            return RekordboxTrack(
                trackId: String(91_234_500 + index),
                attributes: [
                    "Name": track.title,
                    "Artist": track.user.username,
                    "TotalTime": String(Int(track.duration)),
                    "AverageBpm": String(format: "%.2f", bpm),
                    "Tonality": ["8A", "9A", "4A", "11B"][index % 4],
                    "Location": "file://localhost/Users/dj/Music/DJ/\(track.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "").mp3",
                ],
                tempos: [RekordboxTempo(inizio: 0.2, bpm: bpm + 0.5, metro: "4/4", battito: 1)],
                marks: [
                    RekordboxMark(name: "Drop", type: 0, start: 32.2, end: nil, num: 0, red: 40, green: 226, blue: 20),
                    RekordboxMark(name: "", type: 0, start: 0.2, end: nil, num: -1),
                    RekordboxMark(name: "", type: 4, start: 150.2, end: 158.2, num: -1),
                ]
            )
        }
        for (index, name) in ["Basement Tape 4", "Untitled Edit (Dub)", "Vinyl Rip – Side B", "Friday Opener"].enumerated() {
            tracks.append(RekordboxTrack(
                trackId: String(91_240_000 + index),
                attributes: ["Name": name, "Artist": "Unknown Artist", "TotalTime": String(300 + index * 17)],
                tempos: [],
                marks: []
            ))
        }
        return RekordboxLibrary(
            productName: "rekordbox",
            productVersion: "7.1.3",
            tracks: tracks,
            playlists: [.playlist(name: "Warm-up", keyType: 0, trackKeys: tracks.prefix(6).map(\.trackId)), .folder(name: "Gigs", children: [.playlist(name: "Friday", keyType: 0, trackKeys: tracks.suffix(5).map(\.trackId))])]
        )
    }
}

@MainActor
enum MacUSBFixtures {

    static let eligibleIndices = (0..<12).filter { $0 % 3 != 2 }

    static func tones() -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacUSBFixtures-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rate = 8_000
        return eligibleIndices.enumerated().map { order, trackIndex in
            let frames = rate * Int(MacPrepFixtures.tracks[trackIndex].duration)
            var data = Data()
            func u32(_ value: Int) { var v = UInt32(value).littleEndian; data.append(Data(bytes: &v, count: 4)) }
            func u16(_ value: Int) { var v = UInt16(value).littleEndian; data.append(Data(bytes: &v, count: 2)) }
            data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames)
            data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate); u16(1); u16(8)
            data.append(contentsOf: Array("data".utf8)); u32(frames)
            let frequency = 110.0 * pow(2, Double(order) / 12)
            var samples = [UInt8](repeating: 128, count: frames)
            for frame in 0..<frames {
                let beat = Double(frame % (rate / 2)) / Double(rate / 2)
                let envelope = max(0, 1 - beat * 2.2)
                samples[frame] = UInt8(128 + sin(Double(frame) / Double(rate) * 2 * .pi * frequency) * envelope * 100)
            }
            data.append(contentsOf: samples)
            let url = directory.appendingPathComponent("Track \(order + 1).wav")
            try? data.write(to: url)
            return url
        }
    }

    static func candidates(store: CueStore, files: [URL]) -> @MainActor () async -> [MacUSBCandidate] {
        {
            var out: [MacUSBCandidate] = []
            for (index, track) in MacPrepFixtures.tracks.enumerated() {
                let prep = await store.prep(forTrack: track.id)
                let cues = await store.cues(forTrack: track.id)
                out.append(MacUSBCandidate(
                    id: track.id,
                    title: track.title,
                    artist: track.user.username,
                    durationSeconds: track.duration,
                    fileURL: index % 3 == 2 ? nil : files[index / 3 * 2 + index % 3],
                    isrc: nil,
                    prep: prep,
                    cues: cues
                ))
            }
            return out
        }
    }

    static func volume(_ name: String, in directory: URL, total: Int64 = 31_900_000_000, free: Int64 = 27_400_000_000, writable: Bool = true, library: Bool = false) -> MacUSBVolume {
        MacUSBVolume(url: directory.appendingPathComponent(name, isDirectory: true), name: name, totalBytes: total, availableBytes: free, isWritable: writable, hasLibrary: library)
    }

    static func playlistSources() -> [MacUSBExportSource] {
        let tracks = MacPrepFixtures.tracks
        let items = tracks.map(MacUSBExportSource.Item.init)
        return [
            MacUSBExportSource(id: "soundcloud:fixture-friday", name: "Friday at Corsica", items: Array(items.prefix(7))),
            MacUSBExportSource(id: "setlist:fixture-warmup", name: "Warm-up Set", items: Array(items.suffix(4))),
        ]
    }

    static func model(scene: String, store: CueStore) async -> MacUSBExportModel {
        let files = tones()
        let root = files[0].deletingLastPathComponent()
        let defaults = UserDefaults(suiteName: "MacUSBFixtures-\(UUID().uuidString)") ?? .standard
        let stick = volume("DJ STICK", in: root)
        let gig = volume("GIG DRIVE", in: root, total: 128_000_000_000, free: 96_000_000_000, library: true)
        let locked = volume("SANDISK", in: root, writable: false)
        var volumes = [stick, gig, locked]
        var provider: @MainActor () -> [MacUSBVolume] = { volumes }
        switch scene {
        case "usb-replace":
            volumes = [gig, stick]
        case "usb-access":
            volumes = [locked]
        case "usb-novolume":
            volumes = []
        case "usb-unfinished":
            let unfinished = root.appendingPathComponent("UNFINISHED", isDirectory: true)
            try? FileManager.default.createDirectory(at: unfinished.appendingPathComponent(".sounding-incoming-8F2A", isDirectory: true), withIntermediateDirectories: true)
            volumes = [MacUSBVolume(url: unfinished, name: "UNFINISHED", totalBytes: 31_900_000_000, availableBytes: 27_400_000_000, isWritable: true, hasLibrary: false)]
        case "usb-full":
            volumes = [volume("TINY SD", in: root, total: 8_000_000, free: 3_000_000)]
        case "usb-run":
            let real = root.appendingPathComponent("REAL STICK", isDirectory: true)
            try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            volumes = [MacUSBVolume(url: real, name: "REAL STICK", totalBytes: 31_900_000_000, availableBytes: 27_400_000_000, isWritable: true, hasLibrary: false)]
        default:
            break
        }
        for volume in volumes { try? FileManager.default.createDirectory(at: volume.url, withIntermediateDirectories: true) }
        if scene == "usb-replace" {
            let all = await candidates(store: store, files: files)()
            let records = all.compactMap { MacUSBExportBuilder.record($0, info: nil, waveform: nil) }
            _ = try? await DJMediaExporter().export(tracks: records, playlists: [], to: gig.url, options: DJExportOptions(destination: .volumeRoot))
        }
        provider = { volumes }
        let runner: MacUSBExportRunner
        if scene == "usb-progress" || scene == "usb-error" || scene == "usb-pulled" {
            let fails = scene == "usb-error" || scene == "usb-pulled"
            let pulled = scene == "usb-pulled"
            runner = { _, _, _, _, _, progress, _ in
                if pulled { throw DJMediaExportError.volumeRemoved("/Volumes/DJ STICK") }
                if fails { throw DJMediaExportError.copyMismatch("Orange Rooms.wav") }
                progress(DJExportProgress(phase: .copying, completed: 4, total: 9))
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            }
        } else {
            runner = MacUSBExportModel.liveRunner
        }
        var candidateSource = candidates(store: store, files: files)
        if scene == "usb-noeligible" { candidateSource = { [] } }
        return MacUSBExportModel(
            store: store,
            selectionIds: scene == "usb-selection" ? [MacPrepFixtures.tracks[0].id] : [],
            sources: scene == "usb-playlists" ? playlistSources() : [],
            defaults: defaults,
            volumes: provider,
            candidates: candidateSource,
            runner: runner
        )
    }
}

@MainActor
enum MacPrepStickFixture {

    static let volumeName = "CDJ STICK"

    static func make() throws -> MacStickVolume {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPrepStick-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(volumeName, isDirectory: true)
        let rekordbox = root.appendingPathComponent("PIONEER/rekordbox", isDirectory: true)
        try FileManager.default.createDirectory(at: rekordbox, withIntermediateDirectories: true)

        var database = PDBDatabase.exportDefaults()
        let tracks = Array(VisualFixtures.tracks.prefix(12))
        var artistIds: [String: UInt32] = [:]
        let bpms: [Double] = [124, 122, 126, 128, 123, 125, 120, 127, 124, 126, 118, 130]
        let keys = ["Am", "Em", "Cm", "Gb", "Dm", "Bbm", "Fm", "Gm", "Bm", "Abm", "Eb", "F#m"]
        database.keys = keys.enumerated().map { PDBKey(id: UInt32($0.offset + 1), name: $0.element) }
        var stickTracks: [PDBTrack] = []
        for (index, track) in tracks.enumerated() {
            let artistId = artistIds[track.user.username] ?? UInt32(artistIds.count + 1)
            artistIds[track.user.username] = artistId
            var row = PDBTrack(id: UInt32(index + 1))
            row[.title] = track.title
            let filePath = "/Contents/\(track.user.username)/Singles/\(track.title).mp3"
            row[.filePath] = filePath
            row[.filename] = "\(track.title).mp3"
            let folder = DJAnalysisPath.directory(for: filePath)
            row[.analyzePath] = folder + "/ANLZ0000.DAT"
            row.tempo = UInt32(bpms[index] * 100)
            row.duration = UInt16(min(Double(UInt16.max), track.duration))
            row.artistId = artistId
            row.keyId = UInt32(index + 1)
            stickTracks.append(row)
            try writeAnalysis(root: root, folder: folder, filePath: filePath, bpm: bpms[index], duration: track.duration, index: index)
        }
        database.tracks = stickTracks
        database.artists = artistIds.sorted { $0.value < $1.value }.map { PDBArtist(id: $0.value, name: $0.key) }

        database.playlistTree = [
            PDBPlaylistNode(id: 1, parentId: 0, sortOrder: 0, isFolder: false, name: "Warm-up"),
            PDBPlaylistNode(id: 2, parentId: 0, sortOrder: 1, isFolder: true, name: "Gigs"),
            PDBPlaylistNode(id: 3, parentId: 2, sortOrder: 0, isFolder: false, name: "Friday"),
        ]
        database.playlistEntries =
            (1...5).map { PDBPlaylistEntry(entryIndex: UInt32($0), trackId: UInt32($0), playlistId: 1) }
            + (6...12).map { PDBPlaylistEntry(entryIndex: UInt32($0 - 5), trackId: UInt32($0), playlistId: 3) }
        try PDBWriter.write(database).write(to: rekordbox.appendingPathComponent("export.pdb"))

        let loaded = try DJStickLoader.load(root: root.path)
        return MacStickVolume(id: "fixture-stick", name: volumeName, rootPath: root.path, library: loaded.library)
    }

    private static func writeAnalysis(root: URL, folder: String, filePath: String, bpm: Double, duration: TimeInterval, index: Int) throws {
        let directory = root.appendingPathComponent(String(folder.dropFirst()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let period = 60 / bpm
        let anchor = 0.12 + Double(index) * 0.007
        func ms(_ bars: Double) -> UInt32 { UInt32((anchor + bars * period * 4) * 1000) }

        var beats: [ANLZBeat] = []
        var beat = 0
        while anchor + Double(beat) * period < duration {
            beats.append(ANLZBeat(beatNumber: UInt16(beat % 4 + 1), tempo: UInt16(bpm * 100), timeMillis: UInt32((anchor + Double(beat) * period) * 1000)))
            beat += 1
        }
        let bytes = MacPrepFixtures.envelope(seed: filePath, duration: duration)
            .enumerated().filter { $0.offset % 3 == 0 }.prefix(400).map { UInt8(min(31, $0.element * 31)) | 0xA0 }

        func hot(_ slot: UInt32, _ bars: Double, _ label: String, _ rgb: (UInt8, UInt8, UInt8)) -> ANLZCue {
            var cue = ANLZCue(timeMillis: ms(bars))
            cue.hotCue = slot
            cue.comment = label
            cue.colorRed = rgb.0; cue.colorGreen = rgb.1; cue.colorBlue = rgb.2
            return cue
        }
        var hotCues = [hot(1, 16, "Drop", (0x28, 0xE2, 0x14)), hot(2, 48, "Break", (0xFF, 0xA0, 0x00))]
        if index % 2 == 0 { hotCues.append(hot(4, 64, "Vocal", (0x30, 0x5A, 0xFF))) }
        var memory = [ANLZCue(timeMillis: ms(0)), ANLZCue(timeMillis: ms(32))]
        memory[1].comment = "Mix in here"
        var loop = ANLZCue(timeMillis: ms(88))
        loop.isLoop = true
        loop.loopTimeMillis = ms(96)
        memory.append(loop)

        let dat = ANLZFile(tags: [
            .path(filePath),
            .beatGrid(beats),
            .waveformPreview(Array(bytes)),
        ])
        let ext = ANLZFile(tags: [
            .path(filePath),
            .extendedCueList(ANLZCueList(kind: .memory, cues: memory)),
            .extendedCueList(ANLZCueList(kind: .hotCues, cues: hotCues)),
        ])
        try ANLZCodec.write(dat).write(to: directory.appendingPathComponent("ANLZ0000.DAT"))
        try ANLZCodec.write(ext).write(to: directory.appendingPathComponent("ANLZ0000.EXT"))
    }
}

enum MacRekordboxShareFixture {
    @MainActor
    static func make() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRekordboxShare-\(UUID().uuidString)/USBANLZ", isDirectory: true)
        let names = MacPrepFixtures.tracks.map { "\($0.title).mp3" } + ["Promo 0412.wav", "Sampler Kick 01.wav", "Unreleased Edit.m4a"]
        for (index, name) in names.enumerated() {
            let folder = root.appendingPathComponent(String(format: "%03x/%08x-0000-4000-8000-%012x", index, index * 977, index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bpm = 120.0 + Double(index % 9)
            let period = 60 / bpm
            let beats = (0 ..< 640).map { ANLZBeat(beatNumber: UInt16($0 % 4 + 1), tempo: UInt16(bpm * 100), timeMillis: UInt32((0.12 + Double($0) * period) * 1000)) }
            let dat = ANLZFile(tags: [.path("?/\(name)"), .beatGrid(beats)])
            var extTags: [ANLZTag] = [.path("?/\(name)"), .waveformDetail([UInt8](repeating: 0x40, count: Int((index < MacPrepFixtures.tracks.count ? MacPrepFixtures.tracks[index].duration : 640 * period) * 150)))]
            if index % 2 == 0 {
                let kinds: [UInt16] = [1, 2, 5, 3, 2, 5, 6]
                let phrases = kinds.enumerated().map { ANLZPhrase(index: UInt16($0.offset + 1), beat: UInt16($0.offset * 64 + 1), kind: $0.element) }
                extTags.append(.songStructure(ANLZSongStructure(mood: 1, endBeat: 640, phrases: phrases)))
            }
            try ANLZCodec.write(dat).write(to: folder.appendingPathComponent("ANLZ0000.DAT"))
            try ANLZCodec.write(ANLZFile(tags: extTags)).write(to: folder.appendingPathComponent("ANLZ0000.EXT"))
        }
        return root.path
    }
}

@MainActor
enum MacPrepSnapshot {

    static func run(scene: String, dark: Bool) async {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let store = MacPrepFixtures.makeStore()
        await MacPrepFixtures.seed(store)

        let content: AnyView
        var size = CGSize(width: 1180, height: 760)
        switch scene {
        case "import", "choose", "review", "done":
            let library = MacPrepFixtures.library(store: store)
            await library.preview(MacPrepFixtures.rekordboxLibrary())
            if scene == "choose" { library.bucket = .choose }
            if scene == "review" {
                let first = MacPrepFixtures.tracks[0]
                await store.upsert(CuePoint(trackId: first.id, kind: .hotCue, positionMillis: 31_000, hotCueIndex: 0, label: "My drop"))
                var editedKey = await store.prep(forTrack: first.id) ?? TrackPrep(trackId: first.id)
                editedKey.key = PrepField(PrepKey(camelot: "1A", original: "1A"), source: .user, updatedAtMillis: CueTime.nowMillis(), writerId: "fixture")
                await store.savePrep(editedKey)
                for track in MacPrepFixtures.tracks.prefix(4).dropFirst() {
                    await store.upsert(CuePoint(trackId: track.id, kind: .hotCue, positionMillis: 33_500, hotCueIndex: 0, label: "Drop"))
                }
                await library.continueImport()
            }
            if scene == "done" { library.phase = .done(tracks: 12, cues: 41) }
            content = AnyView(MacRekordboxImportSheet(library: library, onClose: {}, startsImmediately: false))
            size = CGSize(width: 720, height: 520)
        case "rbshare", "rbshare-done", "rbshare-folder":
            let library = MacPrepFixtures.library(store: store)
            let root = try? MacRekordboxShareFixture.make()
            let files = await MacRekordboxShareSources.liveLocalFiles(store: store)
            let candidates = VisualFixtures.tracks.map {
                MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
            }
            let sources = MacRekordboxShareSources(localFiles: { files }, candidates: { candidates }, xml: { nil }, ourKey: { _ in nil })
            let model = MacRekordboxShareImport(library: library, sources: sources, root: scene == "rbshare-folder" ? nil : root)
            if scene == "rbshare-folder" {
                model.phase = .needsFolder
            } else {
                await model.scan()
            }
            if scene == "rbshare-done" { await model.importMatched() }
            content = AnyView(MacRekordboxShareSheet(model: model, onClose: {}, startsImmediately: false))
            size = CGSize(width: 520, height: 560)
        case "export":
            let library = MacPrepFixtures.library(store: store)
            var summary = RekordboxExportSummary()
            summary.tracks = 8
            summary.cues = 52
            summary.skippedSoundCloudOnly = 4
            summary.droppedSuggestions = 1
            summary.droppedMemoryColours = 2
            content = AnyView(MacRekordboxExportSheet(library: library, draft: .init(items: [], summary: summary), onClose: {}))
            size = CGSize(width: 460, height: 440)
        case let usb where usb.hasPrefix("usb-"):
            let model = await MacUSBFixtures.model(scene: usb, store: store)
            content = AnyView(MacUSBExportSheet(model: model, onClose: {}).task {
                try? await Task.sleep(for: .milliseconds(1200))
                switch usb {
                case "usb-progress", "usb-error", "usb-run", "usb-pulled":
                    model.requestExport()
                case "usb-replace":
                    model.mode = .replace
                case "usb-done":
                    model.forcePhase(.finished(.init(root: URL(fileURLWithPath: "/Volumes/DJ STICK/Sounding Export 2026-11-06 2105"), volume: MacUSBFixtures.volume("DJ STICK", in: URL(fileURLWithPath: "/Volumes")), tracks: 8, skipped: 4, leftOut: [2, 5, 8, 11].map { MacPrepFixtures.tracks[$0].title })))
                default:
                    break
                }
            })
            size = CGSize(width: 520, height: 720)
        case "settings":
            let library = MacPrepFixtures.library(store: store)
            content = AnyView(MacLibrarySettingsTab(library: library).frame(width: 680, height: 560))
            size = CGSize(width: 680, height: 560)
        case "stick", "stick-playlist":
            let volume = try? MacPrepStickFixture.make()
            if let volume { MacDJSticks.shared.installFixture([volume]) }
            let candidates = VisualFixtures.tracks.map {
                MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
            }
            let stick = MacPrepStickModel(store: store, candidates: { candidates })
            let model = MacPrepModel(store: store, tracks: MacPrepFixtures.source(), stick: stick)
            let target: MacPrepModel.Source = .stick(volume: volume?.id ?? "", playlist: scene == "stick" ? nil : 3)
            content = AnyView(MacPrepView(model: model).task {
                try? await Task.sleep(for: .milliseconds(500))
                model.source = target
                try? await Task.sleep(for: .milliseconds(1200))
                stick.selection = scene == "stick" ? 1 : 6
                try? await Task.sleep(for: .milliseconds(800))
                stick.cursorSeconds = 0.12 + 16 * (240 / 124.0) - 3
                stick.selectedCueId = stick.detail?.cues.first { $0.hotCueIndex == 0 }?.id
            })
        case "stick-inspector", "stick-inspector-done":
            let volume = try? MacPrepStickFixture.make()
            if let volume { MacDJSticks.shared.installFixture([volume]) }
            let candidates = VisualFixtures.tracks.map {
                MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
            }
            let stick = MacPrepStickModel(store: store, candidates: { candidates })
            await stick.open(volume: volume?.id ?? "", playlist: nil)
            stick.selection = 1
            try? await Task.sleep(for: .milliseconds(600))
            if scene == "stick-inspector-done" {
                await store.upsert(CuePoint(trackId: MacPrepFixtures.tracks[0].id, kind: .hotCue, positionMillis: 31_000, hotCueIndex: 0, label: "My drop"))
                await stick.importSelected()
            }
            content = AnyView(MacPrepStickInspector(stick: stick))
            size = CGSize(width: 340, height: 760)
        case "dj-prep", "dj-prep-go", "dj-prep-menu":
            let model = await DJPrepFixtures.model(store: store, tier: scene == "dj-prep-go" ? .go : .goPlus)
            let context = DJPrepFixtures.context()
            content = AnyView(DJPrepScreen(model: model, context: context).task {
                try? await Task.sleep(for: .milliseconds(700))
                model.source = .playlist("1#Gigs/Friday")
                try? await Task.sleep(for: .milliseconds(500))
                let target = MacPrepFixtures.tracks[scene == "dj-prep-go" ? 8 : 6]
                model.selection = target.id
                try? await Task.sleep(for: .milliseconds(500))
                model.cursorSeconds = 0.12 + 48 * (240 / 120.0) + 0.5
                model.selectedCueId = model.detail?.cues.first { $0.hotCueIndex == 1 }?.id
            })
            size = CGSize(width: 1280, height: 800)
        case "dj-library", "dj-library-go":
            let model = await DJPrepFixtures.model(store: store, tier: scene == "dj-library-go" ? .go : .goPlus)
            model.searchText = ""
            content = AnyView(DJLibraryPanel(model: model, context: DJPrepFixtures.context())
                .padding(12)
                .frame(width: 330, height: 720))
            size = CGSize(width: 330, height: 720)
        case "empty":
            content = AnyView(MacPrepView(model: MacPrepModel(store: MacPrepFixtures.makeStore(), tracks: MacPrepFixtures.source())))
        default:
            let model = MacPrepModel(store: store, tracks: MacPrepFixtures.source())
            content = AnyView(MacPrepView(model: model).task {
                try? await Task.sleep(for: .milliseconds(600))
                model.selection = MacPrepFixtures.tracks[0].id
                try? await Task.sleep(for: .milliseconds(400))
                model.cursorSeconds = 0.12 + 40 * (240 / 124.0) - 3
                model.selectedCueId = "\(MacPrepFixtures.tracks[0].id)#hot#0"
            })
        }

        let controller = NSHostingController(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = scene == "prep" || scene == "empty" || scene.hasPrefix("stick") || scene.hasPrefix("dj-prep")
            ? [.titled, .closable, .resizable, .fullSizeContentView, .miniaturizable]
            : [.titled, .closable]
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if scene != "prep", scene != "empty", !scene.hasPrefix("stick") { window.title = "" }
        if let width = ProcessInfo.processInfo.environment["SOUNDING_TV_PREP_SNAPSHOT_WIDTH"].flatMap(Double.init) {
            size.width = width
            size.height = (ProcessInfo.processInfo.environment["SOUNDING_TV_PREP_SNAPSHOT_HEIGHT"].flatMap(Double.init)) ?? size.height
        }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_NO_ACTIVATE"] != "1" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        try? await Task.sleep(for: .seconds(scene == "usb-progress" || scene == "usb-error" || scene == "usb-pulled" ? 9 : 3))

        if scene.hasPrefix("usb-") {
            window.setContentSize(controller.view.fittingSize)
            try? await Task.sleep(for: .milliseconds(400))
        }
        var png = await captureWindow(window)
        if png == nil {
            guard let frameView = window.contentView?.superview else { exit(2) }
            let bounds = frameView.bounds
            guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { exit(3) }
            frameView.cacheDisplay(in: bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        guard let png else { exit(4) }
        print("[PREP_WINDOW]\(window.windowNumber)")
        fflush(stdout)
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PREP_SNAPSHOT_HOLD"] == "1" {
            try? await Task.sleep(for: .seconds(6))
        }
        window.close()
        print("[PREP_SNAPSHOT_B64]\(png.base64EncodedString())")
        fflush(stdout)
        exit(0)
    }
}

extension MacPrepSnapshot {
    static func captureWindow(_ window: NSWindow) async -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prep-snapshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let number = window.windowNumber
        let ok: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(number)", url.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        guard ok else { return nil }
        return try? Data(contentsOf: url)
    }
}

@_cdecl("soundingtv_mac_prep_snapshot_bootstrap")
private func soundingtv_mac_prep_snapshot_bootstrap() {
    guard let scene = ProcessInfo.processInfo.environment["SOUNDING_TV_PREP_SNAPSHOT"] else { return }
    let dark = ProcessInfo.processInfo.environment["SOUNDING_TV_PREP_SNAPSHOT_SCHEME"] == "dark"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        Task { @MainActor in
            await MacPrepSnapshot.run(scene: scene, dark: dark)
        }
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_prep_snapshot_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_prep_snapshot_bootstrap

struct MacPrepView: View {
    private let model: () -> MacPrepModel
    @ObservedObject private var engine = MixEngine.shared
    @ObservedObject private var registry = MacDeckTrackRegistry.shared
    @ObservedObject private var settings = SettingsStore.shared

    init(model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel()) {
        self.model = model
    }

    var body: some View {
        DJPrepScreen(model: model(), context: .live(tracks: { MacPrepTrackSource.live.track($0) }))
            .navigationTitle("Prep")
            .frame(minWidth: 1080, minHeight: 640)
            .tint(Color.scAccent)
            .preferredColorScheme(settings.prepAppearance.colorScheme)
    }
}
#endif
