import SwiftUI

enum MacPrepStickMapping {

    static func rekordboxTrack(_ track: DJStickTrack, analysis: DJStickAnalysis) -> RekordboxTrack {
        var attributes: [String: String] = [
            "Name": track.title,
            "Artist": track.artist,
            "TotalTime": String(track.durationSeconds),
        ]
        if let bpm = track.bpm { attributes["AverageBpm"] = RekordboxXML.bpm(bpm) }
        if let key = track.keyName, !key.isEmpty { attributes["Tonality"] = key }
        if !track.comment.isEmpty { attributes["Comments"] = track.comment }
        return RekordboxTrack(
            trackId: String(track.id),
            attributes: attributes,
            tempos: analysis.tempos.map {
                RekordboxTempo(inizio: $0.startSeconds, bpm: $0.bpm, metro: "4/4", battito: $0.beatInBar)
            },
            marks: analysis.marks.map {
                RekordboxMark(
                    name: $0.label, type: $0.xmlType, start: $0.startSeconds, end: $0.endSeconds,
                    num: $0.xmlNum, red: $0.red, green: $0.green, blue: $0.blue
                )
            }
        )
    }

    static func detail(volumeId: String, track: DJStickTrack, analysis: DJStickAnalysis) -> MacPrepModel.Detail {
        let trackId = "stick:\(volumeId):\(track.id)"
        let rekordbox = rekordboxTrack(track, analysis: analysis)
        var prep = TrackPrep(trackId: trackId)
        let segments = rekordbox.tempos.map {
            PrepTempoSegment(startMillis: CueTime.millis(fromSeconds: $0.inizio), bpm: $0.bpm, beatInBar: $0.battito)
        }
        if !segments.isEmpty {
            prep.grid = PrepField(PrepGrid(segments: RekordboxMapping.compact(segments)), source: .rekordbox, updatedAtMillis: 0, writerId: "stick")
        }
        let mapped = RekordboxMapping.cues(from: rekordbox, trackId: trackId, now: 0, writerId: "stick")
        return MacPrepModel.Detail(
            trackId: trackId,
            title: track.title,
            durationSeconds: TimeInterval(track.durationSeconds),
            envelope: analysis.overview,
            prep: prep.isEmpty ? nil : prep,
            cues: mapped.cues.sorted { $0.positionMillis < $1.positionMillis },
            suggestions: [],
            fallbackGrid: nil
        )
    }
}

@MainActor
final class MacPrepStickModel: ObservableObject {

    struct Row: Identifiable, Hashable {
        let id: UInt32
        let title: String
        let artist: String
        let durationSeconds: Int
        let bpm: Double?
        let key: String?
        var cueCount: Int?
        var outcome: MatchOutcome

        var bpmText: String { bpm.map { String(format: "%.2f", $0) } ?? "–" }
        var timeText: String { DJFormat.time(TimeInterval(durationSeconds)) }
        var matchedTrackId: String? { outcome.matchedTrackId }
    }

    enum ImportState: Equatable {
        case idle
        case working
        case done(tracks: Int, cues: Int, kept: Int)
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isLoading = false
    @Published private(set) var detail: MacPrepModel.Detail?
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var volumeName = ""
    @Published var cursorSeconds: TimeInterval = 0
    @Published var selectedCueId: String?
    @Published var selection: UInt32? {
        didSet {
            guard selection != oldValue else { return }
            importState = .idle
            Task { await loadDetail() }
        }
    }

    let store: CueStore
    private let sticks: MacDJSticks
    private let io: DJStickIO
    private let candidates: @MainActor () async -> [MatchCandidate]
    private var volumeId: String?
    private var rootPath = ""
    private var library: DJStickLibrary?
    private var analyses: [UInt32: DJStickAnalysis] = [:]
    private var openGeneration = 0

    init(
        store: CueStore = .shared,
        sticks: MacDJSticks = .shared,
        io: DJStickIO = DJStickPOSIXIO(),
        candidates: @escaping @MainActor () async -> [MatchCandidate] = MacRekordboxLibrary.liveCandidates
    ) {
        self.store = store
        self.sticks = sticks
        self.io = io
        self.candidates = candidates
    }

    var matchedRows: [Row] { rows.filter { $0.matchedTrackId != nil } }
    var selectedRow: Row? { selection.flatMap { id in rows.first { $0.id == id } } }
    var selectedTrack: DJStickTrack? { selection.flatMap { library?.track(id: $0) } }

    func visibleRows(matching text: String) -> [Row] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    func open(volume id: String, playlist: UInt32?) async {
        openGeneration += 1
        let generation = openGeneration
        isLoading = true
        importState = .idle
        guard let volume = sticks.volume(id: id) else {
            rows = []
            detail = nil
            isLoading = false
            return
        }
        volumeId = id
        volumeName = volume.name
        rootPath = volume.rootPath
        library = volume.library
        analyses = [:]
        let tracks = playlist
            .flatMap { pid in volume.library.playlists.first { $0.id == pid } }
            .map { volume.library.tracks(in: $0) } ?? volume.library.tracks
        let pool = await candidates()
        let built = await Task.detached(priority: .userInitiated) { () -> [Row] in
            let index = TrackMatcher.Index(pool)
            return tracks.map { track in
                Row(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    durationSeconds: track.durationSeconds,
                    bpm: track.bpm,
                    key: track.keyName.flatMap { PrepKey(parsing: $0)?.camelot } ?? track.keyName,
                    cueCount: nil,
                    outcome: TrackMatcher.match(
                        MatchQuery(title: track.title, artist: track.artist, durationSeconds: TimeInterval(track.durationSeconds), isrc: track.isrc),
                        in: index
                    )
                )
            }
        }.value
        guard generation == openGeneration else { return }
        rows = playlist == nil ? built.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : built
        isLoading = false
        if selection == nil || !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        } else {
            await loadDetail()
        }
    }

    func close() {
        openGeneration += 1
        rows = []
        detail = nil
        selection = nil
        volumeId = nil
        library = nil
        analyses = [:]
        isLoading = false
    }

    func loadDetail() async {
        guard let id = selection, let track = library?.track(id: id), let volumeId else {
            detail = nil
            return
        }
        let analysis = await analysis(for: track)
        guard selection == id else { return }
        detail = MacPrepStickMapping.detail(volumeId: volumeId, track: track, analysis: analysis)
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].cueCount = analysis.marks.count }
        cursorSeconds = 0
        selectedCueId = nil
    }

    private func analysis(for track: DJStickTrack) async -> DJStickAnalysis {
        if let cached = analyses[track.id] { return cached }
        let root = rootPath
        let io = io
        let read = await Task.detached(priority: .userInitiated) {
            DJStickLoader.analysis(for: track, root: root, io: io)
        }.value ?? DJStickAnalysis()
        analyses[track.id] = read
        return read
    }

    func importSelected() async {
        guard let row = selectedRow, let trackId = row.matchedTrackId, let track = library?.track(id: row.id) else { return }
        importState = .working
        let analysis = await analysis(for: track)
        let result = await RekordboxImport.importMerging(
            MacPrepStickMapping.rekordboxTrack(track, analysis: analysis),
            trackId: trackId,
            title: track.title,
            store: store
        )
        importState = .done(tracks: 1, cues: result.cues, kept: result.keptYours)
    }

    func importAllMatched() async {
        let matched = matchedRows
        guard !matched.isEmpty else { return }
        importState = .working
        var cues = 0
        var kept = 0
        var tracks = 0
        for row in matched {
            guard let trackId = row.matchedTrackId, let track = library?.track(id: row.id) else { continue }
            let analysis = await analysis(for: track)
            let result = await RekordboxImport.importMerging(
                MacPrepStickMapping.rekordboxTrack(track, analysis: analysis),
                trackId: trackId,
                title: track.title,
                store: store
            )
            cues += result.cues
            kept += result.keptYours
            tracks += 1
        }
        importState = .done(tracks: tracks, cues: cues, kept: kept)
    }
}
