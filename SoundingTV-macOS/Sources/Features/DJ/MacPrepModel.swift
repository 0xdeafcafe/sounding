import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class MacPrepModel: ObservableObject {

    enum Access: Hashable {
        case local
        case streams
        case autoMixOnly

        var canEdit: Bool { self != .autoMixOnly }
        var canLoad: Bool { self != .autoMixOnly }
    }

    enum Analysis: Hashable {
        case done
        case analysing
        case missing
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let durationSeconds: TimeInterval
        let bpm: Double?
        let key: String?
        let energy: Int?
        let cueCount: Int
        let hasFile: Bool
        let gridLocked: Bool
        var gridSource: PrepSource? = nil
        var access: Access = .local
        var fileFormat: String? = nil
        var fileMissing = false
        var folder: String? = nil
        var addedMillis: Int64 = 0
        var analysis: Analysis = .done
        var artworkURL: URL? = nil
        var isLike = false

        var bpmText: String { bpm.map { String(format: "%.2f", $0) } ?? "–" }
        var timeText: String { DJFormat.time(durationSeconds) }
        var cuesText: String { cueCount == 0 ? "–" : "\(min(cueCount, CuePoint.hotCueSlotCount))/\(CuePoint.hotCueSlotCount)" }
        var canExport: Bool { access == .local && !fileMissing }

        var sourceText: String {
            switch access {
            case .local: return fileMissing ? "File moved" : "Local · \(fileFormat ?? "File")"
            case .streams: return "Streams · Not on USB"
            case .autoMixOnly: return "Auto Mix only"
            }
        }

        var duplicateKey: String {
            "\(title.lowercased().trimmingCharacters(in: .whitespaces))|\(artist.lowercased().trimmingCharacters(in: .whitespaces))"
        }

        var needsGridCheck: Bool {
            guard access.canEdit, analysis == .done else { return false }
            if bpm == nil { return true }
            return !gridLocked && gridSource == .sounding
        }

        var sortBPM: Double { bpm ?? 0 }
        var sortKey: String { key ?? "" }
        var sortEnergy: Int { energy ?? -1 }
        var sortSource: String { sourceText }
    }

    struct Detail: Equatable {
        let trackId: String
        let title: String
        let durationSeconds: TimeInterval
        var envelope: [Float]
        var prep: TrackPrep?
        var cues: [CuePoint]
        var suggestions: [CueSuggestion]
        var fallbackGrid: BeatGrid?
        var confidence: Double? = nil

        var grid: PrepGrid? { prep?.grid?.value }
        var gridSource: PrepSource? { prep?.grid?.source }
    }

    enum SmartCrate: String, Hashable, CaseIterable {
        case needsGridCheck
        case notOnStick
        case duplicates

        var title: String {
            switch self {
            case .needsGridCheck: return "Needs a Grid Check"
            case .notOnStick: return "Not on the Stick"
            case .duplicates: return "Duplicates"
            }
        }
    }

    enum Source: Hashable {
        case all
        case likes
        case folder(String)
        case playlist(String)
        case smart(SmartCrate)
        case stick(volume: String, playlist: UInt32?)

        var isStick: Bool {
            if case .stick = self { return true }
            return false
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var allRows: [Row] = []
    @Published private(set) var playlists: [RekordboxPlaylistRecord] = []
    @Published private(set) var detail: Detail?
    @Published private(set) var isLoading = true
    @Published private(set) var volumes: [MacUSBVolume] = []
    @Published private(set) var changedSinceExport = 0
    @Published private(set) var exportedIds: Set<String> = []
    @Published private(set) var trim: TrackTrim?
    @Published var selection: String? {
        didSet { if selection != oldValue { Task { await loadDetail() } } }
    }
    @Published var source: Source = .all {
        didSet {
            guard source != oldValue else { return }
            if case .stick(let volume, let playlist) = source {
                enterStick(volume: volume, playlist: playlist)
            } else {
                if oldValue.isStick { stick.close() }
                Task { await reload() }
            }
        }
    }
    @Published var searchText = ""
    @Published var cursorSeconds: TimeInterval = 0
    @Published var showsUSBExport = false
    @Published var inspectorChoice: Bool?
    @Published var isInspectorShown = true
    @Published var zoomWindow: TimeInterval = 16

    let store: CueStore
    let stick: MacPrepStickModel
    let ledger: DJPrepExportLedger
    let trackMap: TrackMapModel
    weak var undoManager: UndoManager? {
        didSet { trackMap.undoManager = undoManager }
    }
    private let tracks: MacPrepTrackSource
    private let access: (DJGearFeature, Bool) -> SoundCloudEntitlementError?
    private var stickChanges: AnyCancellable?
    private var trackMapChanges: AnyCancellable?
    private var taps: [Date] = []

    var selectedCueId: String? {
        get { trackMap.selectedCueId }
        set { trackMap.selectedCueId = newValue }
    }

    init(
        store: CueStore = .shared,
        tracks: MacPrepTrackSource = .live,
        stick: MacPrepStickModel? = nil,
        ledger: DJPrepExportLedger = .shared,
        access: @escaping (DJGearFeature, Bool) -> SoundCloudEntitlementError? = { MacDeckControlSurface.djDenial($0, isSoundCloudTrack: $1) }
    ) {
        self.store = store
        self.tracks = tracks
        self.ledger = ledger
        self.access = access
        let stick = stick ?? MacPrepStickModel(store: store)
        self.stick = stick
        trackMap = TrackMapModel(board: CueBoard(store: store))
        stickChanges = stick.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        trackMapChanges = trackMap.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        trackMap.livePosition = { [weak self] in self?.cursorSeconds ?? 0 }
        trackMap.onSeek = { [weak self] seconds in self?.cursorSeconds = seconds }
        trackMap.onEdit = { [weak self] in await self?.refreshAfterEdit() }
    }

    private func enterStick(volume: String, playlist: UInt32?) {
        rows = []
        selection = nil
        detail = nil
        selectedCueId = nil
        isLoading = false
        Task { await stick.open(volume: volume, playlist: playlist) }
    }

    var visibleRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.title.lowercased().contains(query)
                || row.artist.lowercased().contains(query)
                || (row.key?.lowercased() == query)
                || (row.bpm.map { String(Int($0.rounded())) } == query)
        }
    }

    var selectedRow: Row? {
        guard let selection else { return nil }
        return allRows.first { $0.id == selection }
    }

    var streamsAllowed: Bool { access(.prep, true) == nil }

    var exportsSoundCloud: Bool { access(.usbExport, true) == nil }

    var canEditSelection: Bool { selectedRow?.access.canEdit ?? false }

    func row(_ id: String) -> Row? { allRows.first { $0.id == id } }

    func track(_ id: String) -> Track? { tracks.track(id) }

    var folders: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in allRows { if let folder = row.folder { counts[folder, default: 0] += 1 } }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, counts[$0] ?? 0) }
    }

    var likesCount: Int { allRows.filter(\.isLike).count }

    func count(_ crate: SmartCrate) -> Int { rows(for: .smart(crate)).count }

    func count(_ source: Source) -> Int { rows(for: source).count }

    var exportableCount: Int { allRows.filter(\.canExport).count }

    var streamingCount: Int { allRows.filter { $0.access != .local }.count }

    func title(for source: Source) -> String {
        switch source {
        case .all: return "All Tracks"
        case .likes: return "Likes"
        case .folder(let name): return name
        case .playlist(let id): return playlists.first { $0.id == id }?.name ?? "Crate"
        case .smart(let crate): return crate.title
        case .stick: return stick.volumeName
        }
    }

    func rows(for source: Source) -> [Row] {
        switch source {
        case .all, .stick:
            return allRows.filter { !$0.isLike || $0.hasFile || $0.cueCount > 0 || $0.bpm != nil }
        case .likes:
            return allRows.filter(\.isLike)
        case .folder(let name):
            return allRows.filter { $0.folder == name }
        case .playlist(let id):
            guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
            let byId = Dictionary(allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return playlist.trackIds.compactMap { byId[$0] }
        case .smart(.needsGridCheck):
            return allRows.filter(\.needsGridCheck)
        case .smart(.notOnStick):
            return allRows.filter { $0.canExport && !exportedIds.contains($0.id) }
        case .smart(.duplicates):
            var groups: [String: Int] = [:]
            for row in allRows { groups[row.duplicateKey, default: 0] += 1 }
            return allRows.filter { (groups[$0.duplicateKey] ?? 0) > 1 }
        }
    }

    func reload() async {
        if source.isStick {
            isLoading = false
            return
        }
        let store = store
        playlists = await store.rekordboxPlaylists()
        volumes = tracks.volumes()
        let likes = await tracks.likes()
        let likeIds = Set(likes.map(\.id))
        let links = await store.allLinks()
        let linkById = Dictionary(links.map { ($0.trackId, $0) }, uniquingKeysWith: { first, _ in first })
        let files = await store.linkedFileTrackIds()
        var seen = Set<String>()
        var ids: [String] = []
        for id in await store.preparedTrackIds() + files.sorted() + likes.map(\.id) where seen.insert(id).inserted {
            ids.append(id)
        }
        let cuesByTrack = await store.cues(forTracks: ids)
        let preps = await store.preps(forTracks: ids)
        var built: [Row] = []
        for id in ids {
            let link = linkById[id]
            let track = tracks.track(id) ?? likes.first { $0.id == id }
            let title = link?.title ?? track?.title ?? ""
            guard !title.isEmpty else { continue }
            let prep = preps[id]
            let hasFile = files.contains(id)
            var path: String?
            var missing = false
            if hasFile, let file = await store.linkFile(forTrack: id) {
                path = file.path
                missing = !tracks.fileExists(file)
            }
            let isSoundCloud = !LocalTrackFile.isLocalTrackID(id)
            let rowAccess: Access = hasFile || !isSoundCloud ? .local : (access(.prep, true) == nil ? .streams : .autoMixOnly)
            let analysisState = tracks.analysis(id)
            let analysis: Analysis
            switch analysisState {
            case .analysing?, .queued?: analysis = .analysing
            default: analysis = prep?.grid == nil && prep?.key == nil ? .missing : .done
            }
            built.append(Row(
                id: id,
                title: title,
                artist: link?.artist ?? track?.user.username ?? "",
                durationSeconds: link.map { Double($0.durationMillis) / 1000 } ?? track?.duration ?? 0,
                bpm: prep?.grid?.value.bpm,
                key: prep?.key?.value.camelot,
                energy: prep?.energy?.value,
                cueCount: cuesByTrack[id]?.filter { $0.hotCueIndex != nil }.count ?? 0,
                hasFile: hasFile,
                gridLocked: prep?.hasLockedGrid ?? false,
                gridSource: prep?.grid?.source,
                access: rowAccess,
                fileFormat: path.map { URL(fileURLWithPath: $0).pathExtension.uppercased() }.flatMap { $0.isEmpty ? nil : $0 },
                fileMissing: missing,
                folder: path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
                addedMillis: track.map { Int64($0.createdAt.timeIntervalSince1970 * 1000) } ?? link?.updatedAtMillis ?? 0,
                analysis: analysis,
                artworkURL: track?.artworkURL,
                isLike: likeIds.contains(id)
            ))
        }
        allRows = built
        exportedIds = ledger.exportedIds
        let changed = await store.prepSyncRecords(changedSince: ledger.lastExportMillis)
        let exportable = Set(built.filter(\.canExport).map(\.id))
        changedSinceExport = ledger.lastExportMillis == 0 ? 0 : Set(changed.map(\.trackId)).intersection(exportable).count
        applySource()
        isLoading = false
        if selection == nil || !built.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        } else {
            await loadDetail()
        }
    }

    private func applySource() {
        var filtered = rows(for: source)
        if case .all = source { filtered.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        rows = filtered
    }

    func loadDetail() async {
        guard let id = selection, let row = allRows.first(where: { $0.id == id }) else {
            detail = nil
            trim = nil
            return
        }
        let prep = await store.prep(forTrack: id)
        let cues = await store.cues(forTrack: id)
        let grid = prep?.grid?.value.beatGrid(durationSeconds: row.durationSeconds, confidence: 0.9)
        let suggestions = await store.listeningSuggestions(forTrack: id, grid: grid, duration: row.durationSeconds)
        let previousEnvelope = detail?.trackId == id ? detail?.envelope ?? [] : []
        let confidence = await tracks.confidence(id)
        detail = Detail(
            trackId: id,
            title: row.title,
            durationSeconds: row.durationSeconds,
            envelope: previousEnvelope,
            prep: prep,
            cues: cues,
            suggestions: suggestions,
            fallbackGrid: nil,
            confidence: confidence
        )
        trim = TrackTrimStore.shared.trim(for: id)
        trackMap.isEditable = row.access.canEdit
        trackMap.load(trackId: id, title: row.title, duration: row.durationSeconds, envelope: previousEnvelope, beatGrid: grid)
        if previousEnvelope.isEmpty {
            let envelope = await tracks.envelope(id, row.durationSeconds)
            if detail?.trackId == id {
                detail?.envelope = envelope
                trackMap.load(trackId: id, title: row.title, duration: row.durationSeconds, envelope: envelope, beatGrid: grid)
            }
        }
        if let selectedCueId, !cues.contains(where: { $0.id == selectedCueId }) { self.selectedCueId = nil }
    }

    private func refreshAfterEdit() async {
        await loadDetail()
        guard let id = selection, let detail else { return }
        func updated(_ old: Row) -> Row {
            var row = Row(
                id: old.id, title: old.title, artist: old.artist, durationSeconds: old.durationSeconds,
                bpm: detail.grid?.bpm, key: detail.prep?.key?.value.camelot ?? old.key, energy: old.energy,
                cueCount: detail.cues.filter { $0.hotCueIndex != nil }.count, hasFile: old.hasFile,
                gridLocked: detail.prep?.hasLockedGrid ?? false
            )
            row.gridSource = detail.gridSource
            row.access = old.access
            row.fileFormat = old.fileFormat
            row.fileMissing = old.fileMissing
            row.folder = old.folder
            row.addedMillis = old.addedMillis
            row.analysis = old.analysis
            row.artworkURL = old.artworkURL
            row.isLike = old.isLike
            return row
        }
        if let index = allRows.firstIndex(where: { $0.id == id }) { allRows[index] = updated(allRows[index]) }
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = updated(rows[index]) }
        if ledger.lastExportMillis > 0, allRows.first(where: { $0.id == id })?.canExport == true {
            let changed = await store.prepSyncRecords(changedSince: ledger.lastExportMillis)
            let exportable = Set(allRows.filter(\.canExport).map(\.id))
            changedSinceExport = Set(changed.map(\.trackId)).intersection(exportable).count
        }
    }

    // MARK: Trim, tap and analysis

    func setTrim(start: TimeInterval? = nil, end: TimeInterval? = nil) {
        guard let detail, canEditSelection else { return }
        let range = TrackTrimStore.range(trim, duration: detail.durationSeconds)
        let next = TrackTrim(start: start ?? range.lowerBound, end: end ?? range.upperBound)
        TrackTrimStore.shared.setTrim(next, for: detail.trackId, duration: detail.durationSeconds)
        trim = TrackTrimStore.shared.trim(for: detail.trackId)
    }

    func tap(now: Date = Date()) {
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
        taps.append(now)
        if taps.count > 8 { taps.removeFirst(taps.count - 8) }
        guard taps.count >= 4, let first = taps.first, let last = taps.last else { return }
        let interval = last.timeIntervalSince(first) / Double(taps.count - 1)
        guard interval > 0 else { return }
        let bpm = (60 / interval * 100).rounded() / 100
        if editableGrid == nil {
            applyGrid(PrepGrid(segments: [PrepTempoSegment(startMillis: CueTime.millis(fromSeconds: cursorSeconds), bpm: bpm)]), action: "Tap Tempo")
        } else {
            setBPM(bpm)
        }
    }

    func analyse(_ ids: [String]) {
        for id in ids {
            guard let track = tracks.track(id) else { continue }
            Task { _ = await AutomaticAnalysisScheduler.shared.analyseNow(track, refresh: true) }
        }
    }

    func addCrate(named name: String) {
        let record = RekordboxPlaylistRecord(id: "sounding#\(UUID().uuidString)", name: name, path: [], trackIds: [])
        let store = store
        let updated = playlists + [record]
        Task {
            await store.saveRekordboxPlaylists(updated)
            await reload()
        }
    }

    func add(_ ids: [String], toCrate crateId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == crateId }) else { return }
        var updated = playlists
        let existing = updated[index]
        let merged = existing.trackIds + ids.filter { !existing.trackIds.contains($0) }
        updated[index] = RekordboxPlaylistRecord(id: existing.id, name: existing.name, path: existing.path, trackIds: merged)
        let store = store
        Task {
            await store.saveRekordboxPlaylists(updated)
            await reload()
        }
    }

    var editableGrid: PrepGrid? {
        if let grid = detail?.grid { return grid }
        guard let detail else { return nil }
        if let bpm = rows.first(where: { $0.id == detail.trackId })?.bpm {
            return PrepGrid(segments: [PrepTempoSegment(startMillis: 0, bpm: bpm)])
        }
        return nil
    }

    func setDownbeat() {
        let millis = CueTime.millis(fromSeconds: cursorSeconds)
        let base = editableGrid ?? PrepGrid(segments: [PrepTempoSegment(startMillis: millis, bpm: 120)])
        applyGrid(PrepGridEditor.setDownbeat(base, atMillis: millis), action: "Set Downbeat")
    }

    func nudge(byMillis delta: Int64) {
        guard let grid = editableGrid else { return }
        applyGrid(PrepGridEditor.nudge(grid, byMillis: delta), action: "Nudge Grid")
    }

    func halveTempo() {
        guard let grid = editableGrid else { return }
        applyGrid(PrepGridEditor.halve(grid), action: "Halve Tempo")
    }

    func doubleTempo() {
        guard let grid = editableGrid else { return }
        applyGrid(PrepGridEditor.double(grid), action: "Double Tempo")
    }

    func setBPM(_ bpm: Double) {
        guard let grid = editableGrid, abs(grid.bpm - bpm) > 0.001 else { return }
        applyGrid(PrepGridEditor.setBPM(grid, bpm: bpm), action: "Change Tempo")
    }

    func toggleLock() {
        guard let grid = editableGrid else { return }
        applyGrid(PrepGridEditor.setLocked(grid, !grid.locked), action: grid.locked ? "Unlock Grid" : "Lock Grid")
    }

    private func applyGrid(_ grid: PrepGrid?, action: String) {
        guard let trackId = detail?.trackId, canEditSelection else { return }
        let previous = detail?.prep?.grid
        let store = store
        Task {
            await store.setUserGrid(trackId: trackId, grid)
            await refreshAfterEdit()
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreGrid(previous, trackId: trackId, action: action) }
        }
        undoManager?.setActionName(action)
    }

    private func restoreGrid(_ field: PrepField<PrepGrid>?, trackId: String, action: String) {
        let current = detail?.trackId == trackId ? detail?.prep?.grid : nil
        let store = store
        Task {
            var prep = await store.prep(forTrack: trackId) ?? TrackPrep(trackId: trackId)
            prep.grid = field.map { PrepField($0.value, source: $0.source, updatedAtMillis: CueTime.nowMillis(), writerId: store.writerId) }
            await store.savePrep(prep)
            await refreshAfterEdit()
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreGrid(current, trackId: trackId, action: action) }
        }
        undoManager?.setActionName(action)
    }

    func snapped(_ seconds: TimeInterval) -> TimeInterval {
        guard let detail, let grid = detail.grid?.beatGrid(durationSeconds: detail.durationSeconds, confidence: 0.9) else {
            return seconds
        }
        return grid.nearestBeat(to: seconds)
    }

    func linkFile() {
        guard let trackId = detail?.trackId else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = store
        Task {
            await MacTrackFileLinker.link(url, trackId: trackId, store: store)
            await reload()
        }
    }

    func togglePlay() {
        guard let id = detail?.trackId else { return }
        let player = PlayerService.shared
        if player.currentTrack?.id == id {
            player.togglePlayPause()
            return
        }
        guard let track = tracks.track(id) else { return }
        let seconds = cursorSeconds
        Task {
            await player.play(track, in: [track])
            if seconds > 0.5 { player.seek(to: seconds, expectedTrackID: id) }
        }
    }

    var playheadSeconds: TimeInterval? {
        guard let id = detail?.trackId, PlayerService.shared.currentTrack?.id == id else { return nil }
        return PlayerService.shared.currentTime
    }
}

struct MacPrepTrackSource {
    var track: @MainActor (String) -> Track?
    var envelope: @MainActor (String, TimeInterval) async -> [Float]
    var likes: @MainActor () async -> [Track] = { [] }
    var analysis: @MainActor (String) -> AnalysisWorkState? = { _ in nil }
    var fileExists: @MainActor (TrackLinkFile) -> Bool = { _ in true }
    var volumes: @MainActor () -> [MacUSBVolume] = { [] }
    var confidence: @MainActor (String) async -> Double? = { _ in nil }

    static let live = MacPrepTrackSource(
        track: { id in
            if PlayerService.shared.currentTrack?.id == id { return PlayerService.shared.currentTrack }
            return PlayerService.shared.queue.first { $0.id == id } ?? MacPrepLibraryIndex.shared.track(id)
        },
        envelope: { id, duration in
            guard let track = PlayerService.shared.queue.first(where: { $0.id == id }) ?? MacPrepLibraryIndex.shared.track(id) else { return [] }
            if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
                return waveform.resampled(to: 1_200)
            }
            return []
        },
        likes: { await MacPrepLibraryIndex.shared.load() },
        analysis: { AutomaticAnalysisStatus.shared.state(for: $0) },
        fileExists: { file in
            guard let url = MacTrackFileLinker.resolve(file) else { return FileManager.default.fileExists(atPath: file.path) }
            return FileManager.default.fileExists(atPath: url.path)
        },
        volumes: { MacUSBExportModel.mountedVolumes() }
    )
}

final class DJPrepExportLedger: @unchecked Sendable {
    static let shared = DJPrepExportLedger(defaults: .standard)

    private let defaults: UserDefaults
    private static let millisKey = "djPrep.lastExportMillis"
    private static let idsKey = "djPrep.exportedTrackIds"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var lastExportMillis: Int64 { Int64(defaults.double(forKey: Self.millisKey)) }

    var exportedIds: Set<String> { Set(defaults.stringArray(forKey: Self.idsKey) ?? []) }

    func record(trackIds: [String], at millis: Int64 = CueTime.nowMillis()) {
        defaults.set(Double(millis), forKey: Self.millisKey)
        defaults.set(Array(exportedIds.union(trackIds)), forKey: Self.idsKey)
    }
}

@MainActor
final class MacPrepLibraryIndex {
    static let shared = MacPrepLibraryIndex()
    private var tracksById: [String: Track] = [:]
    private var loaded = false

    func track(_ id: String) -> Track? { tracksById[id] }

    func load() async -> [Track] {
        if !loaded {
            let rows = await LibraryCache.shared.loadAllLikes()
            let decoder = JSONDecoder()
            for row in rows {
                if let track = try? decoder.decode(Track.self, from: row.payload) { tracksById[track.id] = track }
            }
            loaded = true
        }
        return Array(tracksById.values)
    }

    func install(_ tracks: [Track]) {
        for track in tracks { tracksById[track.id] = track }
        loaded = true
    }
}

enum MacTrackFileLinker {
    static func link(_ url: URL, trackId: String, store: CueStore, fallback: (title: String, artist: String, durationMillis: Int64)? = nil) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let hash = await Task.detached(priority: .utility) { TrackFileHash.hash(of: url) }.value
        let isrc = await LocalAudioTags.isrc(of: url)
        await store.saveLinkFile(TrackLinkFile(trackId: trackId, bookmark: bookmark, path: url.path))
        var link = await store.link(forTrack: trackId)
        if link == nil {
            let track = await MainActor.run { MacPrepLibraryIndex.shared.track(trackId) }
            link = TrackLink(
                trackId: trackId,
                title: track?.title ?? fallback?.title ?? url.deletingPathExtension().lastPathComponent,
                artist: track?.user.username ?? fallback?.artist ?? "",
                durationMillis: track.map { CueTime.millis(fromSeconds: $0.duration) } ?? fallback?.durationMillis ?? 0
            )
        }
        guard var updated = link else { return }
        updated.fileHash = hash ?? updated.fileHash
        updated.isrc = isrc ?? updated.isrc
        await store.saveLink(updated)
    }

    static func resolve(_ file: TrackLinkFile) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

enum LocalAudioTags {
    static func isrc(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            guard identifier.contains("tsrc") || identifier.contains("isrc") else { continue }
            if let value = try? await item.load(.stringValue), let code = TrackMatcher.normaliseISRC(value) {
                return code
            }
        }
        return nil
    }
}
