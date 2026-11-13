import AppKit
import SwiftUI

struct MacUSBVolume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isWritable: Bool
    let hasLibrary: Bool
    var format: DJVolumeInfo.Kind = .exfat
    var formatName = "exFAT"

    var id: String { url.path }
    var isDJFormat: Bool { format == .fat || format == .exfat }
}

struct MacUSBCandidate: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let durationSeconds: Double
    let fileURL: URL?
    let isrc: String?
    let prep: TrackPrep?
    let cues: [CuePoint]
}

enum MacUSBExportBuilder {
    static func usableCues(_ candidate: MacUSBCandidate, duration: Double) -> [CuePoint] {
        candidate.cues.filter { cue in
            guard cue.origin != .suggested, !cue.isDeleted else { return false }
            return cue.positionSeconds <= duration && (cue.endSeconds ?? 0) <= duration
        }
    }

    static func droppedCueCount(_ candidate: MacUSBCandidate, duration: Double) -> Int {
        candidate.cues.filter { $0.origin != .suggested && !$0.isDeleted }.count - usableCues(candidate, duration: duration).count
    }

    static func record(_ candidate: MacUSBCandidate, info: DJAudioFileInfo?, waveform: DJExportWaveform?, analysedSections: [TrackSection] = []) -> DJExportTrackRecord? {
        guard let url = candidate.fileURL else { return nil }
        var metadata = DJExportMetadata(title: candidate.title, durationSeconds: info?.durationSeconds ?? candidate.durationSeconds)
        metadata.artist = candidate.artist
        metadata.isrc = candidate.isrc ?? ""
        metadata.comment = candidate.prep?.comment?.value ?? ""
        metadata.colorRGB = candidate.prep?.colour?.value
        if let info {
            metadata.sampleRate = info.sampleRate
            metadata.bitDepth = info.bitDepth
            metadata.bitrateKbps = info.bitrateKbps
            metadata.fileSize = info.fileSize
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
            metadata.fileSize = size
        }
        let duration = metadata.durationSeconds
        let grid = candidate.prep?.grid?.value.beatGrid(durationSeconds: duration, confidence: 0.9).flatMap { DJExportBeatGrid($0) }
        let cues = usableCues(candidate, duration: duration).compactMap { DJExportCue($0) }
        var phrases: DJExportPhrases?
        if let list = candidate.prep?.phrases?.value, let exact = DJExportPhrases(prepPhrases: list, durationSeconds: duration) {
            phrases = exact
        } else if let list = candidate.prep?.phrases?.value.sorted(by: { $0.startMillis < $1.startMillis }), !list.isEmpty {
            let sections = list.enumerated().map { index, phrase in
                TrackSection(
                    kind: phrase.kind,
                    start: CueTime.seconds(fromMillis: phrase.startMillis),
                    end: index + 1 < list.count ? CueTime.seconds(fromMillis: list[index + 1].startMillis) : duration
                )
            }
            phrases = DJExportPhrases(sections: sections, duration: duration)
        } else if !analysedSections.isEmpty {
            phrases = DJExportPhrases(sections: analysedSections, duration: duration)
        }
        let key = candidate.prep?.key.flatMap { DJExportKey.parse($0.value.camelot) }
        return DJExportTrackRecord(
            exportID: candidate.id,
            audioFileURL: url,
            metadata: metadata,
            beatGrid: grid,
            cues: cues,
            phrases: phrases,
            waveform: waveform,
            key: key
        )
    }
}

struct MacUSBExportSource: Identifiable, Hashable, Sendable {
    struct Item: Hashable, Sendable {
        let id: String
        let title: String
        let artist: String
        let durationSeconds: Double
    }

    let id: String
    let name: String
    let items: [Item]?

    var trackIds: [String]? { items?.map(\.id) }

    static let allTracksID = "all"
    static let selectionID = "selection"

    static func playlist(_ playlist: Playlist, tracks: [Track]) -> MacUSBExportSource {
        MacUSBExportSource(id: "soundcloud:\(playlist.id)", name: playlist.title, items: tracks.map(Item.init))
    }

    static func setlist(_ setlist: GeneratedSetlist, title: String) -> MacUSBExportSource {
        let items = setlist.segments.compactMap { segment -> Item? in
            guard let id = segment.soundCloudTrackId else { return nil }
            return Item(id: id, title: segment.title, artist: segment.artist ?? "", durationSeconds: 0)
        }
        return MacUSBExportSource(id: "setlist:\(setlist.trackId)", name: title, items: items)
    }
}

extension MacUSBExportSource.Item {
    init(_ track: Track) {
        self.init(id: track.id, title: track.title, artist: track.user.username, durationSeconds: track.duration)
    }
}

typealias MacUSBExportRunner = @Sendable (
    _ tracks: [DJExportTrackRecord],
    _ playlists: [DJExportPlaylist],
    _ volume: URL,
    _ options: DJExportOptions,
    _ now: Date,
    _ progress: @escaping @Sendable (DJExportProgress) -> Void,
    _ heartbeat: @escaping @Sendable () -> Void
) async throws -> DJExportReport

@MainActor
final class MacUSBExportModel: ObservableObject {

    enum Mode: Hashable {
        case newFolder
        case blankRoot
        case replace
    }

    enum Stage: Int, CaseIterable {
        case reading, preparing, copying, checking, finishing

        var title: String {
            switch self {
            case .reading:   return "Reading Audio"
            case .preparing: return "Preparing Files"
            case .copying:   return "Copying to the Stick"
            case .checking:  return "Checking the Stick"
            case .finishing: return "Finishing"
            }
        }
    }

    struct Working: Equatable {
        var stage: Stage
        var completed: Int
        var total: Int

        var fraction: Double {
            let part = total > 0 ? Double(completed) / Double(total) : 0
            return (Double(stage.rawValue) + min(1, part)) / Double(Stage.allCases.count)
        }
    }

    struct Finished {
        let root: URL
        let volume: MacUSBVolume
        let tracks: Int
        let skipped: Int
        var leftOut: [String] = []
        var notes: [String] = []
    }

    struct Failure {
        enum Retry { case export, access, setup }
        let title: String
        let message: String
        let retry: Retry
        let retryTitle: String
    }

    enum Phase {
        case setup
        case working(Working)
        case finished(Finished)
        case failed(Failure)
    }

    struct Preview: Equatable {
        var tracks = 0
        var bytes: Int64 = 0
        var notes: [Note] = []
        var errors: [String] = []
        var isReady = false

        struct Note: Equatable, Identifiable {
            let title: String
            let detail: String
            var id: String { title + detail }
        }
    }

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var isLoading = true
    @Published private(set) var candidates: [MacUSBCandidate] = []
    @Published private(set) var sources: [MacUSBExportSource] = []
    @Published private(set) var volumes: [MacUSBVolume] = []
    @Published private(set) var preview = Preview()
    @Published private(set) var isPreviewing = false
    @Published private(set) var ejectMessage: String?
    @Published private(set) var findings: DJRecoveryFindings?
    @Published private(set) var libraryProblems: [String] = []
    @Published private(set) var repairMessage: String?
    @Published private(set) var isRepairing = false
    @Published private(set) var fetchesMissingAudio = false
    @Published var chosen: Set<String> = [MacUSBExportSource.allTracksID] { didSet { if chosen != oldValue { schedulePreview() } } }
    @Published var volumeId: String? { didSet { if volumeId != oldValue { modeDidChange() } } }
    @Published var mode: Mode = .newFolder { didSet { if mode != oldValue { schedulePreview() } } }
    @Published var confirmsReplace = false
    @Published var accessMessage: String?

    let store: CueStore
    let selectionIds: [String]
    let extraSources: [MacUSBExportSource]
    private let volumeProvider: @MainActor () -> [MacUSBVolume]
    private let runner: MacUSBExportRunner
    private let candidateProvider: (@MainActor () async -> [MacUSBCandidate])?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var accessed: [URL] = []
    private var grants: [String: URL] = [:]
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var inspectTask: Task<Void, Never>?
    private let beats = MacUSBHeartbeat()
    private(set) var plannedDate = Date()

    private static let bookmarksKey = "red.forbes.sounding.usb.volumeBookmarks"

    init(
        store: CueStore = .shared,
        selectionIds: [String] = [],
        sources extraSources: [MacUSBExportSource] = [],
        defaults: UserDefaults = .sounding,
        volumes: @escaping @MainActor () -> [MacUSBVolume] = MacUSBExportModel.mountedVolumes,
        candidates: (@MainActor () async -> [MacUSBCandidate])? = nil,
        runner: @escaping MacUSBExportRunner = MacUSBExportModel.liveRunner
    ) {
        self.store = store
        self.selectionIds = selectionIds
        self.extraSources = extraSources
        self.defaults = defaults
        self.volumeProvider = volumes
        self.candidateProvider = candidates
        self.runner = runner
        if let first = extraSources.first {
            chosen = [first.id]
        } else if !selectionIds.isEmpty {
            chosen = [MacUSBExportSource.selectionID]
        }
    }

    func forcePhase(_ phase: Phase) { self.phase = phase }

    var chosenSources: [MacUSBExportSource] { sources.filter { chosen.contains($0.id) } }

    func isChosen(_ source: MacUSBExportSource) -> Bool { chosen.contains(source.id) }

    func setChosen(_ source: MacUSBExportSource, _ on: Bool) {
        if on { chosen.insert(source.id) } else { chosen.remove(source.id) }
    }

    func count(_ source: MacUSBExportSource) -> Int {
        source.items?.count ?? candidates.count
    }

    var scopedCandidates: [MacUSBCandidate] {
        let picked = chosenSources
        if picked.contains(where: { $0.items == nil }) { return candidates }
        let known = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [MacUSBCandidate] = []
        for source in picked {
            for item in source.items ?? [] where seen.insert(item.id).inserted {
                out.append(known[item.id] ?? MacUSBCandidate(
                    id: item.id,
                    title: item.title,
                    artist: item.artist,
                    durationSeconds: item.durationSeconds,
                    fileURL: nil,
                    isrc: nil,
                    prep: nil,
                    cues: []
                ))
            }
        }
        return out
    }

    var eligible: [MacUSBCandidate] { scopedCandidates.filter { $0.fileURL != nil } }
    var streamOnly: [MacUSBCandidate] { scopedCandidates.filter { $0.fileURL == nil } }
    var hasAnyEligible: Bool { fetchesMissingAudio || candidates.contains { $0.fileURL != nil } }
    var fetched: [MacUSBCandidate] { fetchesMissingAudio ? streamOnly : [] }
    var volume: MacUSBVolume? { volumes.first { $0.id == volumeId } }

    var availableModes: [Mode] {
        guard let volume, volume.isWritable else { return [.newFolder] }
        return volume.hasLibrary ? [.newFolder, .replace] : [.newFolder, .blankRoot]
    }

    var canExport: Bool {
        guard let volume, volume.isWritable, preview.isReady || !fetched.isEmpty, preview.errors.isEmpty, !isPreviewing else { return false }
        return availableModes.contains(mode)
    }

    var backupFolderName: String { "PIONEER.before-sounding-\(Self.stamp(plannedDate))" }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    func load() async {
        isLoading = true
        #if SOUNDING_PERSONAL
        fetchesMissingAudio = SoundCloudPersonalAudioProvider.shared.isEnabled
            && MacDeckControlSurface.djDenial(.usbExport, isSoundCloudTrack: true) == nil
        #endif
        let imported = await store.rekordboxPlaylists()
        if let candidateProvider {
            candidates = await candidateProvider()
        } else {
            candidates = await loadCandidates()
        }
        sources = buildSources(imported: imported)
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                    let removed = note.name == NSWorkspace.didUnmountNotification
                    MainActor.assumeIsolated {
                        if removed, let path { self?.volumeWasUnmounted(path) }
                        self?.refreshVolumes()
                    }
                })
            }
        }
        refreshVolumes()
        isLoading = false
        schedulePreview()
    }

    private func buildSources(imported: [RekordboxPlaylistRecord]) -> [MacUSBExportSource] {
        let known = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func items(_ ids: [String]) -> [MacUSBExportSource.Item] {
            ids.compactMap { id in
                known[id].map { MacUSBExportSource.Item(id: id, title: $0.title, artist: $0.artist, durationSeconds: $0.durationSeconds) }
            }
        }
        var out = extraSources
        if !selectionIds.isEmpty {
            out.append(MacUSBExportSource(id: MacUSBExportSource.selectionID, name: "Selected in Prep", items: items(selectionIds)))
        }
        out.append(MacUSBExportSource(id: MacUSBExportSource.allTracksID, name: "All Tracks", items: nil))
        for playlist in imported {
            let name = (playlist.path + [playlist.name]).joined(separator: " › ")
            out.append(MacUSBExportSource(id: "rekordbox:\(playlist.id)", name: name, items: items(playlist.trackIds)))
        }
        return out
    }

    private func loadCandidates() async -> [MacUSBCandidate] {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        accessed = []
        let links = await store.allLinks()
        let linked = Set(links.map(\.trackId))
        let local = LocalMusicLibrary.shared.allTracks.filter { !linked.contains($0.id) }
        let ids = links.map(\.trackId) + local.map(\.id)
        let preps = await store.preps(forTracks: ids)
        let cues = await store.cues(forTracks: ids)
        var built: [MacUSBCandidate] = []
        for link in links {
            var url: URL?
            if let file = await store.linkFile(forTrack: link.trackId), let resolved = MacTrackFileLinker.resolve(file) {
                if resolved.startAccessingSecurityScopedResource() { accessed.append(resolved) }
                if FileManager.default.isReadableFile(atPath: resolved.path) { url = resolved }
            }
            built.append(MacUSBCandidate(
                id: link.trackId,
                title: link.title,
                artist: link.artist,
                durationSeconds: Double(link.durationMillis) / 1000,
                fileURL: url,
                isrc: link.isrc,
                prep: preps[link.trackId],
                cues: cues[link.trackId] ?? []
            ))
        }
        var seen = linked
        for track in local where seen.insert(track.id).inserted {
            built.append(MacUSBCandidate(
                id: track.id,
                title: track.title,
                artist: track.user.username,
                durationSeconds: track.duration,
                fileURL: LocalMusicLibrary.readyFileURL(for: track),
                isrc: nil,
                prep: preps[track.id],
                cues: cues[track.id] ?? []
            ))
        }
        return built.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func close() {
        task?.cancel()
        watchdog?.cancel()
        inspectTask?.cancel()
        previewTask?.cancel()
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        for url in grants.values { url.stopAccessingSecurityScopedResource() }
        accessed = []
        grants = [:]
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    func refreshVolumes() {
        restoreGrants()
        let previous = volumeId
        volumes = volumeProvider()
        if let previous, volumes.contains(where: { $0.id == previous }) {
            volumeId = previous
        } else {
            volumeId = volumes.first?.id
        }
        modeDidChange()
    }

    private func modeDidChange() {
        if !availableModes.contains(mode) { mode = .newFolder }
        schedulePreview()
        inspectVolume()
    }

    private func inspectVolume() {
        inspectTask?.cancel()
        findings = nil
        libraryProblems = []
        repairMessage = nil
        guard case .setup = phase, let volume, volume.isWritable else { return }
        let url = volume.url
        let hasLibrary = volume.hasLibrary
        inspectTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (DJRecoveryFindings, [String]) in
                let found = DJExportRecovery.inspect(volume: url)
                var problems: [String] = []
                if hasLibrary, !found.needsRepair {
                    problems = Self.plainProblems(DJMediaValidator.validate(exportRoot: url).errors.map(\.message))
                }
                return (found, problems)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.findings = result.0.needsRepair ? result.0 : nil
            self.libraryProblems = result.1
        }
    }

    func repair() {
        guard let volume, !isRepairing else { return }
        let url = volume.url
        isRepairing = true
        Task { [weak self] in
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let report = try DJExportRecovery.recover(volume: url)
                    switch report.outcome {
                    case .nothingToDo:     return "Nothing needed fixing."
                    case .cleanedUp:       return "Cleared the leftovers. Everything else is as it was."
                    case .rolledBack:      return "The stick is back as it was before the export."
                    case .completed:       return "The export had finished. Its files check out."
                    case .needsAttention:  return "The library still has problems. Export again to replace it."
                    }
                } catch {
                    return "Couldn't finish the repair. Check that the stick is still connected."
                }
            }.value
            guard let self else { return }
            self.isRepairing = false
            self.repairMessage = message
            self.refreshVolumes()
        }
    }

    nonisolated static func plainProblems(_ messages: [String]) -> [String] {
        var out: [String] = []
        func add(_ text: String) { if !out.contains(text) { out.append(text) } }
        for message in messages {
            if message.contains("cue after the end") { add("Some cue points sit past the end of a track.") }
            else if message.contains("bad end") { add("A loop ends past the end of its track.") }
            else if message.contains("is missing") { add("Some files in the library are missing.") }
            else if message.contains("does not add up") || message.contains("cannot be read") { add("The library's database is damaged.") }
            else { add("A file in the library failed its checks.") }
        }
        return out
    }

    private func volumeWasUnmounted(_ path: String) {
        guard case .working = phase, volume?.url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path else { return }
        stickPulled()
    }

    private func stickPulled() {
        guard case .working = phase, let volume else { return }
        task?.cancel()
        watchdog?.cancel()
        phase = .failed(Self.failure(for: DJMediaExportError.volumeRemoved(volume.url.path), volume: volume))
    }

    private func restoreGrants() {
        guard let stored = defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data] else { return }
        for (path, data) in stored where grants[path] == nil {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: path) else { continue }
            if url.startAccessingSecurityScopedResource() { grants[path] = url }
        }
    }

    func allowAccess(chooseAnyVolume: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow Access"
        if chooseAnyVolume {
            panel.message = "Choose the USB stick or SD card."
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        } else if let volume {
            panel.message = "Choose “\(volume.name)” to let Sounding write to it."
            panel.directoryURL = volume.url
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !chooseAnyVolume, let volume, url.standardizedFileURL.path != volume.url.standardizedFileURL.path {
            accessMessage = "Choose “\(volume.name)” itself, not a folder inside it."
            return
        }
        accessMessage = nil
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var stored = defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        stored[url.path] = data
        defaults.set(stored, forKey: Self.bookmarksKey)
        if url.startAccessingSecurityScopedResource() { grants[url.path] = url }
        refreshVolumes()
        volumeId = url.path
    }

    func findLocalFile(for candidate: MacUSBCandidate) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file for “\(candidate.title)”."
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = store
        let id = candidate.id
        Task {
            await MacTrackFileLinker.link(url, trackId: id, store: store)
            await load()
        }
    }

    func schedulePreview() {
        previewTask?.cancel()
        guard case .setup = phase else { return }
        let tracks = eligible
        let playlist = exportPlaylists(for: tracks)
        let streamOnlyCount = streamOnly.count
        let options = exportOptions()
        let volume = volume
        isPreviewing = true
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.makePreview(tracks: tracks, playlists: playlist, options: options, volume: volume, streamOnly: streamOnlyCount)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.preview = result
            self.isPreviewing = false
        }
    }

    nonisolated static func makePreview(
        tracks: [MacUSBCandidate],
        playlists: [DJExportPlaylist],
        options: DJExportOptions,
        volume: MacUSBVolume?,
        streamOnly: Int
    ) -> Preview {
        var preview = Preview()
        let records = tracks.compactMap { MacUSBExportBuilder.record($0, info: nil, waveform: nil) }
        guard !records.isEmpty else {
            preview.isReady = false
            return preview
        }
        let plan: DJExportPlan
        do {
            plan = try DJExportPlanner.plan(tracks: records, playlists: playlists, options: options)
        } catch {
            preview.errors.append("These tracks can't be planned for a stick.")
            return preview
        }
        let titles = Dictionary(tracks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for skipped in plan.skipped {
            preview.notes.append(.init(title: titles[skipped.id] ?? skipped.id, detail: plainReason(skipped.reason)))
        }
        for warning in plan.warnings { preview.notes.append(.init(title: "Note", detail: warning)) }
        preview.tracks = plan.copies.count
        preview.bytes = records.reduce(0) { $0 + $1.metadata.fileSize }
        var files: [String: Data] = [:]
        for analysis in plan.analysis {
            files[analysis.datPath] = ANLZCodec.write(analysis.dat)
            files[analysis.extPath] = ANLZCodec.write(analysis.ext)
        }
        let sizes = Dictionary(plan.copies.map { ($0.devicePath, $0.source) }, uniquingKeysWith: { first, _ in first })
        if let pdb = try? PDBWriter.write(plan.database) {
            let report = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: { path in
                if let source = sizes[path] {
                    return (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
                }
                return Int64(files[path]?.count ?? 0)
            })
            preview.errors += plainProblems(report.errors.map(\.message))
            for warning in report.issues where warning.severity == .warning { preview.notes.append(.init(title: "Note", detail: warning.message)) }
        } else {
            preview.errors.append("The library for this stick couldn't be written.")
        }
        if let volume {
            let needed = preview.bytes + max(16 << 20, preview.bytes / 50) + (8 << 20)
            if volume.availableBytes > 0, needed > volume.availableBytes {
                preview.errors.append("Not enough space: \(byteString(needed)) needed, \(byteString(volume.availableBytes)) free.")
            }
            if !volume.isDJFormat {
                preview.notes.append(.init(title: "\(volume.formatName) stick", detail: "DJ players can't read it. Use exFAT or FAT32."))
            }
        }
        let dropped = tracks.reduce(0) { $0 + MacUSBExportBuilder.droppedCueCount($1, duration: $1.durationSeconds) }
        if dropped > 0 { preview.notes.append(.init(title: "Cue points past a track's end", detail: "\(dropped) left out")) }
        let oversize = records.filter { $0.metadata.fileSize > 0xFFFF_FFFF }.count
        if oversize > 0 { preview.notes.append(.init(title: "Over 4 GB", detail: "\(oversize) left out")) }
        preview.isReady = preview.tracks > 0
        return preview
    }

    nonisolated static func plainReason(_ reason: String) -> String {
        if reason.hasPrefix("unsupported audio format") { return "Format players can't read" }
        switch reason {
        case "larger than 4 GB":  return "Too large for the stick"
        case "not a local file":  return "Not a file on this Mac"
        case "unknown duration":  return "Length unknown"
        default:                  return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    nonisolated static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func exportOptions() -> DJExportOptions {
        var options = DJExportOptions()
        switch mode {
        case .newFolder: options.destination = .newFolder(name: nil)
        case .blankRoot: options.destination = .volumeRoot
        case .replace:   options.destination = .replaceExistingLibrary
        }
        return options
    }

    func exportPlaylists(for tracks: [MacUSBCandidate]) -> [DJExportPlaylist] {
        let exported = Set(tracks.map(\.id))
        var names = Set<String>()
        return chosenSources.compactMap { source in
            let ids = (source.trackIds ?? tracks.map(\.id)).filter { exported.contains($0) }
            guard !ids.isEmpty else { return nil }
            var name = source.items == nil ? "Sounding" : source.name
            var suffix = 2
            while !names.insert(name).inserted {
                name = "\(source.name) \(suffix)"
                suffix += 1
            }
            return DJExportPlaylist(name: name, trackIDs: ids)
        }
    }

    func requestExport() {
        plannedDate = Date()
        if mode == .replace { confirmsReplace = true } else { startExport() }
    }

    func startExport() {
        guard let volume, canExport else { return }
        let local = eligible
        let missing = fetched
        let tracks = local + missing
        let skippedUpFront = fetchesMissingAudio ? [] : streamOnly.map(\.title)
        let playlists = exportPlaylists(for: tracks)
        let options = exportOptions()
        let date = plannedDate
        let runner = runner
        let beats = beats
        beats.touch()
        previewTask?.cancel()
        inspectTask?.cancel()
        let onProgress: @Sendable (DJExportProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        phase = .working(Working(stage: .reading, completed: 0, total: tracks.count))
        task = Task { [weak self] in
            do {
                var records: [DJExportTrackRecord] = []
                var ready = local
                var leftOut = skippedUpFront
                #if SOUNDING_PERSONAL
                if !missing.isEmpty {
                    let keepAlive = Task.detached {
                        while !Task.isCancelled {
                            beats.touch()
                            try? await Task.sleep(for: .seconds(5))
                        }
                    }
                    defer { keepAlive.cancel() }
                    let provider = SoundCloudPersonalAudioProvider.shared
                    for (index, candidate) in missing.enumerated() {
                        try Task.checkCancellation()
                        let metadata = DJExportMetadata(title: candidate.title, artist: candidate.artist, durationSeconds: candidate.durationSeconds)
                        do {
                            let url = try await provider.localAudioFile(forTrackID: candidate.id, metadata: metadata)
                            ready.append(MacUSBCandidate(
                                id: candidate.id,
                                title: candidate.title,
                                artist: candidate.artist,
                                durationSeconds: candidate.durationSeconds,
                                fileURL: url,
                                isrc: candidate.isrc,
                                prep: candidate.prep,
                                cues: candidate.cues
                            ))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            leftOut.append(candidate.title)
                        }
                        self?.setWorking(Working(stage: .reading, completed: index + 1, total: tracks.count))
                    }
                }
                #endif
                for (index, candidate) in ready.enumerated() {
                    try Task.checkCancellation()
                    guard let url = candidate.fileURL else { continue }
                    let analysed = await Task.detached(priority: .userInitiated) { () -> (DJAudioFileInfo?, DJExportWaveform?) in
                        (try? DJAudioAnalysis.info(url), try? DJAudioAnalysis.waveform(url))
                    }.value
                    let sections = candidate.prep?.phrases == nil ? await MacUSBArrangementPhrases.sections(trackId: candidate.id, duration: analysed.0?.durationSeconds ?? candidate.durationSeconds) : []
                    if let record = MacUSBExportBuilder.record(candidate, info: analysed.0, waveform: analysed.1, analysedSections: sections) { records.append(record) }
                    self?.setWorking(Working(stage: .reading, completed: index + 1, total: ready.count))
                }
                let inner = Task.detached(priority: .userInitiated) {
                    try await runner(records, playlists, volume.url, options, date, onProgress, { beats.touch() })
                }
                let report = try await withTaskCancellationHandler {
                    try await inner.value
                } onCancel: {
                    inner.cancel()
                }
                self?.watchdog?.cancel()
                let titles = Dictionary(tracks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                let skipped = leftOut + report.skipped.map { titles[$0.id] ?? $0.id }
                let skippedIds = Set(report.skipped.map(\.id))
                DJPrepExportLedger.shared.record(trackIds: ready.map(\.id).filter { !skippedIds.contains($0) })
                self?.phase = .finished(Finished(root: report.exportRoot, volume: volume, tracks: report.exportedTrackCount, skipped: skipped.count, leftOut: skipped, notes: report.warnings))
            } catch is CancellationError {
                self?.finishCancelled()
            } catch {
                guard let self else { return }
                self.watchdog?.cancel()
                if case .failed = self.phase { return }
                if Task.isCancelled {
                    self.finishCancelled()
                } else {
                    self.phase = .failed(Self.failure(for: error, volume: volume))
                }
            }
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard case .working = self.phase else { return }
                if !FileManager.default.fileExists(atPath: volume.url.path) || self.beats.secondsSinceLast > 45 {
                    self.stickPulled()
                    return
                }
            }
        }
    }

    private func finishCancelled() {
        watchdog?.cancel()
        if case .failed = phase { return }
        returnToSetup()
    }

    private func setWorking(_ working: Working) {
        if case .working = phase { phase = .working(working) }
    }

    private func apply(_ progress: DJExportProgress) {
        guard case .working = phase else { return }
        let stage: Stage
        switch progress.phase {
        case .planning, .staging, .verifying: stage = .preparing
        case .copying:                        stage = .copying
        case .flushing:                       stage = .checking
        case .finishing:                      stage = .finishing
        }
        phase = .working(Working(stage: stage, completed: progress.completed, total: progress.total))
    }

    func cancel() {
        task?.cancel()
    }

    func returnToSetup() {
        task = nil
        phase = .setup
        refreshVolumes()
        schedulePreview()
    }

    func retry(_ failure: Failure) {
        switch failure.retry {
        case .export:
            phase = .setup
            plannedDate = Date()
            startExport()
        case .access:
            phase = .setup
            allowAccess()
        case .setup:
            returnToSetup()
        }
    }

    static func failure(for error: Error, volume: MacUSBVolume) -> Failure {
        if let export = error as? DJMediaExportError {
            switch export {
            case .volumeNotFound:
                return Failure(title: "“\(volume.name)” Isn't Connected", message: "Reconnect the stick, then choose it again.", retry: .setup, retryTitle: "Choose a Volume")
            case .volumeRemoved:
                return Failure(title: "The Stick Was Removed", message: "Nothing on it was changed. Plug it back in to check it.", retry: .setup, retryTitle: "Check the Stick")
            case .readOnlyVolume:
                return Failure(title: "This Stick Is Locked", message: "It's read-only. Slide the lock switch on the stick or card, then try again.", retry: .setup, retryTitle: "Try Again")
            case .notEnoughSpace(let needed, let available):
                return Failure(title: "Not Enough Space", message: "This export needs \(byteString(needed)) and “\(volume.name)” has \(byteString(available)) free.", retry: .setup, retryTitle: "Choose Tracks")
            case .existingLibrary:
                return Failure(title: "This Stick Already Has a Library", message: "Export to a new folder instead, or choose Replace Library to keep a backup of the old one.", retry: .setup, retryTitle: "Change Destination")
            case .destinationExists:
                return Failure(title: "Contents Already Exists", message: "The stick already has a Contents folder with different files. Export to a new folder instead.", retry: .setup, retryTitle: "Change Destination")
            case .nothingToExport:
                return Failure(title: "Nothing to Export", message: "None of the chosen tracks can go on a stick.", retry: .setup, retryTitle: "Choose Tracks")
            case .invalidExport:
                return Failure(title: "The Export Didn't Pass Its Checks", message: "Sounding found a problem in what it wrote and left your stick as it was.", retry: .export, retryTitle: "Try Again")
            case .copyMismatch(let name):
                return Failure(title: "A File Didn't Copy Correctly", message: "“\(name)” didn't match its original after copying. The stick may be failing. Nothing on it was changed.", retry: .export, retryTitle: "Try Again")
            case .io:
                return Failure(title: "Couldn't Write to the Stick", message: "Check that it isn't locked or full, then try again.", retry: .export, retryTitle: "Try Again")
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(cocoa.code) {
            return Failure(title: "Sounding Can't Write to This Volume", message: "Allow access to “\(volume.name)”, or check that it isn't locked.", retry: .access, retryTitle: "Allow Access…")
        }
        return Failure(title: "Couldn't Finish the Export", message: "Your stick was left as it was. Try again.", retry: .export, retryTitle: "Try Again")
    }

    func eject() {
        guard case .finished(let finished) = phase else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: finished.volume.url)
            ejectMessage = "Ejected “\(finished.volume.name)”."
        } catch {
            ejectMessage = "Couldn't eject “\(finished.volume.name)”. Something else still has it open."
        }
    }

    func revealInFinder() {
        guard case .finished(let finished) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finished.root])
    }

    nonisolated static let liveRunner: MacUSBExportRunner = { tracks, playlists, volume, options, date, progress, heartbeat in
        try await DJMediaExporter(heartbeat: heartbeat).export(tracks: tracks, playlists: playlists, to: volume, options: options, now: date, progress: progress)
    }

    static func mountedVolumes() -> [MacUSBVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [MacUSBVolume] = []
        for url in urls where url.path.hasPrefix("/Volumes/") {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal != false,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true else { continue }
            let writable = values.volumeIsReadOnly != true && FileManager.default.isWritableFile(atPath: url.path)
            let fm = FileManager.default
            let hasLibrary = writable && (fm.fileExists(atPath: url.appending(path: "PIONEER").path) || fm.fileExists(atPath: url.appending(path: ".PIONEER").path))
            let format = DJVolumeInfo.inspect(url)
            out.append(MacUSBVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isWritable: writable,
                hasLibrary: hasLibrary,
                format: format?.kind ?? .other,
                formatName: format?.displayName ?? "Unknown"
            ))
        }
        return out
    }
}

final class MacUSBHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    var secondsSinceLast: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}
