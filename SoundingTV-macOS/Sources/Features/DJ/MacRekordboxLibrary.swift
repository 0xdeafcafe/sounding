import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacRekordboxLibrary: ObservableObject {
    static let shared = MacRekordboxLibrary()

    enum ImportPhase {
        case idle
        case loading
        case preview(RekordboxImportPreview)
        case review(RekordboxImportPlan)
        case applying
        case done(tracks: Int, cues: Int)
        case failed
    }

    enum Bucket: Hashable {
        case matched
        case choose
        case missing
    }

    @Published private(set) var xmlName: String?
    @Published private(set) var musicFolderName: String?
    @Published private(set) var linkedCount = 0
    @Published private(set) var fileCount = 0
    @Published var phase: ImportPhase = .idle
    @Published var bucket: Bucket = .matched
    @Published var ambiguousChoices: [String: String] = [:]
    @Published var conflictChoices: [String: ImportChoice] = [:]
    @Published private(set) var candidatesById: [String: MatchCandidate] = [:]

    let store: CueStore
    private let defaults: UserDefaults
    private let candidateSource: @MainActor () async -> [MatchCandidate]
    private var pendingPairs: [(track: RekordboxTrack, trackId: String, title: String)] = []
    private var pendingLibrary: RekordboxLibrary?
    private var chosenXML: URL?

    private enum Key {
        static let xmlBookmark = "red.forbes.sounding.rekordbox.xmlBookmark"
        static let folderBookmark = "red.forbes.sounding.rekordbox.folderBookmark"
    }

    init(
        store: CueStore = .shared,
        defaults: UserDefaults = .standard,
        candidates: @escaping @MainActor () async -> [MatchCandidate] = MacRekordboxLibrary.liveCandidates
    ) {
        self.store = store
        self.defaults = defaults
        self.candidateSource = candidates
        xmlName = resolve(Key.xmlBookmark)?.lastPathComponent
        musicFolderName = resolve(Key.folderBookmark)?.lastPathComponent
    }

    static func liveCandidates() async -> [MatchCandidate] {
        var tracks = await MacPrepLibraryIndex.shared.load()
        tracks += PlayerService.shared.queue
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }.map {
            MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
        }
    }

    func refreshCounts() async {
        linkedCount = await store.allLinks().count
        fileCount = await store.linkedFileTrackIds().count
    }


    var hasChosenXML: Bool { xmlURL != nil }

    private var xmlURL: URL? { chosenXML ?? resolve(Key.xmlBookmark) }

    @discardableResult
    func chooseXML() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the collection you exported from rekordbox with File › Export Collection in xml format."
        panel.prompt = "Choose"
        if let current = xmlURL { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        save(url, key: Key.xmlBookmark)
        chosenXML = url
        xmlName = url.lastPathComponent
        return true
    }

    func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your DJ music."
        panel.prompt = "Allow Access"
        if let suggested = suggestedMusicFolder() { panel.directoryURL = suggested }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(url, key: Key.folderBookmark)
        musicFolderName = url.lastPathComponent
    }

    private func suggestedMusicFolder() -> URL? {
        guard case .preview(let preview) = phase else { return nil }
        let paths = preview.library.tracks.compactMap { $0.fileURL?.deletingLastPathComponent().pathComponents }
        guard var common = paths.first else { return nil }
        for components in paths.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common))
    }

    private func save(_ url: URL, key: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: key)
        }
    }

    private func resolve(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }


    func beginImport() async {
        guard let url = xmlURL else {
            phase = .idle
            return
        }
        phase = .loading
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard let data, let library = try? await Task.detached(priority: .userInitiated, operation: { try RekordboxXML.parse(data) }).value else {
            phase = .failed
            return
        }
        await preview(library)
    }

    func loadChosenXML() async -> RekordboxLibrary? {
        guard let url = xmlURL else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard let data else { return nil }
        return try? await Task.detached(priority: .userInitiated) { try RekordboxXML.parse(data) }.value
    }

    func preview(_ library: RekordboxLibrary) async {
        let candidates = await candidateSource()
        candidatesById = Dictionary(candidates.map { ($0.trackId, $0) }, uniquingKeysWith: { first, _ in first })
        let preview = await Task.detached(priority: .userInitiated) {
            RekordboxImport.preview(library, candidates: candidates)
        }.value
        pendingLibrary = library
        ambiguousChoices = [:]
        bucket = preview.matched.isEmpty && !preview.ambiguous.isEmpty ? .choose : .matched
        phase = .preview(preview)
    }

    func continueImport() async {
        guard case .preview(let preview) = phase else { return }
        var pairs: [(track: RekordboxTrack, trackId: String, title: String)] = []
        for row in preview.rows {
            switch row.outcome {
            case .matched(let id):
                pairs.append((row.track, id, row.track.name))
            case .ambiguous:
                if let chosen = ambiguousChoices[row.id] { pairs.append((row.track, chosen, row.track.name)) }
            case .missing:
                continue
            }
        }
        pendingPairs = pairs
        let ids = pairs.map(\.trackId)
        let preps = await store.preps(forTracks: ids)
        let cues = await store.cues(forTracks: ids)
        let plan = RekordboxImport.plan(pairs: pairs, localPreps: preps, localCues: cues, writerId: store.writerId)
        if plan.conflicts.isEmpty {
            await apply(plan)
        } else {
            conflictChoices = Dictionary(plan.conflicts.map { ($0.id, ImportChoice.keepSounding) }, uniquingKeysWith: { first, _ in first })
            phase = .review(plan)
        }
    }

    func setAllConflicts(_ choice: ImportChoice) {
        for key in conflictChoices.keys { conflictChoices[key] = choice }
    }

    func apply(_ plan: RekordboxImportPlan) async {
        phase = .applying
        let result = await RekordboxImport.apply(plan, choices: conflictChoices, store: store)
        await linkFiles(for: pendingPairs)
        if let library = pendingLibrary {
            var map: [String: String] = [:]
            for pair in pendingPairs { map[pair.track.trackId] = pair.trackId }
            await store.saveRekordboxPlaylists(RekordboxImport.playlists(from: library, trackIdByRekordboxId: map))
        }
        await refreshCounts()
        phase = .done(tracks: result.prepared, cues: result.cues)
    }

    private func linkFiles(for pairs: [(track: RekordboxTrack, trackId: String, title: String)]) async {
        let folder = resolve(Key.folderBookmark)
        let accessing = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
        for pair in pairs {
            var link = await store.link(forTrack: pair.trackId) ?? TrackLink(
                trackId: pair.trackId,
                title: candidatesById[pair.trackId]?.title ?? pair.track.name,
                artist: candidatesById[pair.trackId]?.artist ?? pair.track.artist,
                durationMillis: CueTime.millis(fromSeconds: candidatesById[pair.trackId]?.durationSeconds ?? pair.track.totalTime)
            )
            link.rekordboxTrackId = pair.track.trackId
            await store.saveLink(link)
            if let url = pair.track.fileURL, FileManager.default.isReadableFile(atPath: url.path) {
                await MacTrackFileLinker.link(url, trackId: pair.trackId, store: store)
            }
        }
    }

    func reset() {
        phase = .idle
        pendingPairs = []
        pendingLibrary = nil
        conflictChoices = [:]
        ambiguousChoices = [:]
    }


    struct ExportDraft {
        let items: [RekordboxExportItem]
        let summary: RekordboxExportSummary
    }

    func prepareExport() async -> ExportDraft {
        let links = await store.allLinks()
        var items: [RekordboxExportItem] = []
        var skipped = 0
        for link in links {
            guard let file = await store.linkFile(forTrack: link.trackId), let url = MacTrackFileLinker.resolve(file) else {
                skipped += 1
                continue
            }
            let prep = await store.prep(forTrack: link.trackId)
            let cues = await store.cues(forTrack: link.trackId)
            let grid = prep?.grid?.value.beatGrid(durationSeconds: Double(link.durationMillis) / 1000, confidence: 0.9)
            let suggestions = await store.listeningSuggestions(forTrack: link.trackId, grid: grid, duration: Double(link.durationMillis) / 1000)
            items.append(RekordboxExportItem(link: link, fileURL: url, prep: prep, cues: cues, pendingSuggestions: suggestions.count))
        }
        return ExportDraft(items: items, summary: RekordboxExport.summary(items, skipped: skipped))
    }

    @discardableResult
    func export(_ draft: ExportDraft) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "Sounding for rekordbox.xml"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let data = RekordboxXML.write(RekordboxExport.library(draft.items, version: version))
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
