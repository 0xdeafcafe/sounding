import AppKit
import Darwin
import SwiftUI

struct MacRekordboxShareSources {
    var localFiles: @MainActor () async -> [RekordboxShareLocalFile]
    var candidates: @MainActor () async -> [MatchCandidate]
    var xml: @MainActor () async -> RekordboxLibrary?
    var ourKey: @MainActor (String) async -> String?

    @MainActor
    static func live(library: MacRekordboxLibrary) -> MacRekordboxShareSources {
        MacRekordboxShareSources(
            localFiles: { await MacRekordboxShareSources.liveLocalFiles(store: library.store) },
            candidates: {
                let local = LocalMusicLibrary.shared.allTracks.map {
                    MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
                }
                return await MacRekordboxLibrary.liveCandidates() + local
            },
            xml: { await library.loadChosenXML() },
            ourKey: { await MacRekordboxKeyCheck.ourKey(trackId: $0) }
        )
    }

    @MainActor
    static func liveLocalFiles(store: CueStore) async -> [RekordboxShareLocalFile] {
        var out: [RekordboxShareLocalFile] = []
        for link in await store.allLinks() {
            guard let file = await store.linkFile(forTrack: link.trackId) else { continue }
            out.append(RekordboxShareLocalFile(trackId: link.trackId, path: file.path, durationSeconds: link.durationMillis > 0 ? Double(link.durationMillis) / 1000 : nil))
        }
        for track in LocalMusicLibrary.shared.allTracks {
            guard let file = track.localFile else { continue }
            let path = LocalMusicAccess.shared.fileURL(for: file)?.path ?? "/" + file.relativePath
            out.append(RekordboxShareLocalFile(trackId: track.id, path: path, durationSeconds: track.duration > 0 ? track.duration : nil))
        }
        return out
    }
}

enum MacRekordboxKeyCheck {
    @MainActor
    static func ourKey(trackId: String) async -> String? {
        let track = MacPrepLibraryIndex.shared.track(trackId) ?? LocalMusicLibrary.shared.allTracks.first { $0.id == trackId }
        guard let track else { return nil }
        guard #available(macOS 27.0, *) else { return nil }
        return await cachedKey(track)
    }

    @available(macOS 27.0, *)
    nonisolated static func cachedKey(_ track: Track) async -> String? {
        let generation = MusicUnderstandingProducer().generation
        for transcoding in [track.mixSource] + track.transcodings.map(Optional.init) {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation) else { continue }
            if let result = await AnalysisCache.shared.peek(MusicUnderstandingDistilledResult.self, for: key) {
                return MusicUnderstandingProducer.projectFeatures(result).key?.label
            }
        }
        return nil
    }
}

enum MacUSBArrangementPhrases {
    @MainActor
    static func sections(trackId: String, duration: Double) async -> [TrackSection] {
        let track = MacPrepLibraryIndex.shared.track(trackId) ?? LocalMusicLibrary.shared.allTracks.first { $0.id == trackId }
        guard let track else { return [] }
        return await cachedSections(track, duration: duration)
    }

    nonisolated static func cachedSections(_ track: Track, duration: Double) async -> [TrackSection] {
        let generation = BeatTrackerProducer().generation
        for transcoding in [track.mixSource] + track.transcodings.map(Optional.init) {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation) else { continue }
            if let tracked = await AnalysisCache.shared.peek(BeatTrackerResult.self, for: key),
               let arrangement = TrackArrangement.cached(trackId: track.id, tracked: tracked, ai: nil) {
                return arrangement.sections(duration: duration)
            }
        }
        return []
    }
}

@MainActor
final class MacRekordboxShareImport: ObservableObject {

    struct Found: Equatable {
        var scan: RekordboxShareScan
        var summary: RekordboxShareSummary
        var cuesFromXML: Int
    }

    struct Result: Equatable {
        var tracks = 0
        var grids = 0
        var phrases = 0
        var cues = 0
        var keptYours = 0
        var keys = RekordboxKeyAgreement()
    }

    enum Phase: Equatable {
        case needsFolder
        case scanning
        case ready(Found)
        case importing
        case done(Result)
        case failed
    }

    @Published var phase: Phase = .needsFolder
    @Published private(set) var folderName: String?

    let library: MacRekordboxLibrary
    private let defaults: UserDefaults
    private let sources: MacRekordboxShareSources
    private var rootOverride: String?
    private var matches: [RekordboxShareMatch] = []

    private static let bookmarkKey = "red.forbes.sounding.rekordbox.shareBookmark"

    init(library: MacRekordboxLibrary = .shared, defaults: UserDefaults = .sounding, sources: MacRekordboxShareSources? = nil, root: String? = nil) {
        self.library = library
        self.defaults = defaults
        self.sources = sources ?? .live(library: library)
        self.rootOverride = root
        if let root {
            folderName = (root as NSString).lastPathComponent
        } else {
            folderName = resolveBookmark()?.lastPathComponent
        }
    }

    static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the rekordbox folder. Sounding only reads it."
        panel.prompt = "Allow Access"
        let suggested = Self.realHome + "/Library/Pioneer/rekordbox"
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: suggested) ? suggested : Self.realHome, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Self.bookmarkKey)
        }
        rootOverride = nil
        folderName = url.lastPathComponent
        Task { await scan() }
    }

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func start() async {
        guard rootOverride != nil || resolveBookmark() != nil else {
            phase = .needsFolder
            return
        }
        await scan()
    }

    func scan() async {
        phase = .scanning
        let url = rootOverride.map { URL(fileURLWithPath: $0) } ?? resolveBookmark()
        guard let url else {
            phase = .needsFolder
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let chosen = url.path
        let scan = await Task.detached(priority: .userInitiated) { () -> RekordboxShareScan? in
            guard let root = RekordboxShareLayout.analysisRoot(within: chosen, exists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }) else { return nil }
            return RekordboxShareScanner.scan(root: root)
        }.value
        guard let scan, !scan.entries.isEmpty else {
            phase = .failed
            return
        }
        let files = await sources.localFiles()
        let candidates = await sources.candidates()
        let xml = await sources.xml()
        let matched = await Task.detached(priority: .userInitiated) {
            RekordboxShareMapping.match(scan.entries, files: files, xml: xml, candidates: candidates)
        }.value
        matches = matched
        let xmlCues = matched.filter { $0.trackId != nil && $0.entry.analysis.marks.isEmpty }.reduce(0) { $0 + ($1.xml?.marks.count ?? 0) }
        let summary = RekordboxShareMatcher.summary(matched.map { RekordboxShareResolution(key: $0.entry.matchKey, outcome: $0.outcome, xml: $0.xml) })
        phase = .ready(Found(scan: scan, summary: summary, cuesFromXML: xmlCues))
    }

    func importMatched() async {
        let pending = matches.filter { $0.trackId != nil }
        guard !pending.isEmpty else { return }
        phase = .importing
        let store = library.store
        var result = Result()
        for match in pending {
            guard let trackId = match.trackId else { continue }
            if let theirs = match.xml?.tonality, let ours = await sources.ourKey(trackId) {
                result.keys.add(ours: ours, theirs: theirs)
            }
            let track = RekordboxShareMapping.rekordboxTrack(match)
            let merged = await RekordboxImport.importMerging(track, trackId: trackId, title: track.name, store: store)
            result.cues += merged.cues
            result.keptYours += merged.keptYours
            if !track.tempos.isEmpty { result.grids += 1 }
            if let phrasePrep = RekordboxShareMapping.phrasePrep(match.entry, trackId: trackId, now: CueTime.nowMillis(), writerId: store.writerId) {
                let applied = await store.applyCandidatePrep(phrasePrep)
                if applied.blocked.contains(.phrases) { result.keptYours += 1 } else { result.phrases += 1 }
            }
            result.tracks += 1
        }
        await library.refreshCounts()
        phase = .done(result)
    }
}

struct MacRekordboxShareSheet: View {
    @ObservedObject var model: MacRekordboxShareImport
    @ObservedObject var library: MacRekordboxLibrary
    let onClose: () -> Void
    var startsImmediately = true

    init(model: MacRekordboxShareImport, onClose: @escaping () -> Void, startsImmediately: Bool = true) {
        self.model = model
        self.library = model.library
        self.onClose = onClose
        self.startsImmediately = startsImmediately
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: 560)
        .task {
            guard startsImmediately else { return }
            await model.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .needsFolder:
            ContentUnavailableView {
                Label("Choose Your rekordbox Folder", systemImage: "folder")
            } description: {
                Text("It’s in your Library folder, under Pioneer › rekordbox. Sounding only reads it.")
            } actions: {
                Button("Choose…") { model.chooseFolder() }
            }
        case .scanning, .importing:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("No rekordbox Analysis Found", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Choose the rekordbox folder in Library › Pioneer.")
            } actions: {
                Button("Choose Another Folder…") { model.chooseFolder() }
            }
        case .ready(let found):
            form(found)
        case .done(let result):
            ContentUnavailableView {
                Label("Imported from rekordbox", systemImage: "checkmark.circle")
            } description: {
                Text(doneText(result))
            }
        }
    }

    private func form(_ found: MacRekordboxShareImport.Found) -> some View {
        Form {
            Section {
                LabeledContent("Analysis") {
                    HStack {
                        Text(model.folderName ?? "None")
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                LabeledContent("Collection XML") {
                    HStack {
                        Text(library.xmlName ?? "None")
                            .foregroundStyle(library.xmlName == nil ? .secondary : .primary)
                        Button("Choose…") {
                            if library.chooseXML() {
                                Task { await model.scan() }
                            }
                        }
                    }
                }
            } header: {
                Text("rekordbox")
            } footer: {
                Text("For cue points, keys and playlists, export your collection from rekordbox with File › Export Collection in xml format.")
            }

            Section("Found") {
                LabeledContent("Analysed Tracks", value: "\(found.scan.entries.count)")
                LabeledContent("Beat Grids", value: "\(found.scan.withGrid)")
                LabeledContent("Phrases", value: "\(found.scan.withPhrases)")
                LabeledContent("Cue Points", value: "\(found.scan.cueCount + found.cuesFromXML)")
            }

            Section {
                LabeledContent("Matched by File", value: "\(found.summary.byPath + found.summary.byFileName)")
                LabeledContent("Matched by Title", value: "\(found.summary.byTitle)")
                if found.summary.ambiguous > 0 {
                    LabeledContent("More Than One Match", value: "\(found.summary.ambiguous)")
                }
                LabeledContent("Not in Sounding", value: "\(found.summary.missing)")
            } header: {
                Text("In Sounding")
            } footer: {
                if found.summary.missing > 0 {
                    Text("Add the folder that holds your music in Music Folders to match more.")
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    private func doneText(_ result: MacRekordboxShareImport.Result) -> String {
        var parts = ["\(result.tracks) \(result.tracks == 1 ? "track" : "tracks")", "\(result.grids) \(result.grids == 1 ? "grid" : "grids")"]
        if result.phrases > 0 { parts.append("\(result.phrases) with phrases") }
        if result.cues > 0 { parts.append("\(result.cues) cue \(result.cues == 1 ? "point" : "points")") }
        var text = parts.joined(separator: " · ") + "."
        if result.keptYours > 0 { text += " Kept your own edits on \(result.keptYours)." }
        if result.keys.compared > 0 {
            text += " Sounding’s key matches rekordbox on \(Int((result.keys.exactRate * 100).rounded()))% of \(result.keys.compared)."
        }
        return text
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.phase {
            case .ready(let found):
                Text("\(found.summary.matched) of \(found.summary.analysed) tracks will import")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.importMatched() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(found.summary.matched == 0)
            case .done, .failed:
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .needsFolder, .scanning, .importing:
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
