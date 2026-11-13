import SwiftUI
import Combine

enum MacSmartPlaylist: Hashable {
    case needsGridCheck
    case notAnalysed
    case notOnStick
    case duplicates
    case crate(id: String, name: String)

    static let builtIn: [MacSmartPlaylist] = [.needsGridCheck, .notAnalysed, .notOnStick, .duplicates]

    var title: String {
        switch self {
        case .needsGridCheck: return "Needs a Grid Check"
        case .notAnalysed: return "Not Analysed"
        case .notOnStick: return "Not on the Stick"
        case .duplicates: return "Duplicates"
        case .crate(_, let name): return name
        }
    }

    var symbol: String { "gearshape" }

    var exportID: String {
        switch self {
        case .needsGridCheck: return "smart:gridcheck"
        case .notAnalysed: return "smart:notanalysed"
        case .notOnStick: return "smart:stick"
        case .duplicates: return "smart:duplicates"
        case .crate(let id, _): return "crate:\(id)"
        }
    }

    var prepCrate: MacPrepModel.SmartCrate? {
        switch self {
        case .needsGridCheck: return .needsGridCheck
        case .notOnStick: return .notOnStick
        case .duplicates: return .duplicates
        case .notAnalysed, .crate: return nil
        }
    }
}

extension FocusedValues {
    @Entry var macUSBExportSource: MacUSBExportSource?
}

extension Notification.Name {
    static let macCratesDidChange = Notification.Name.rekordboxPlaylistsDidChange
}

enum MacCrateID {
    static func isUserMade(_ id: String) -> Bool { id.hasPrefix("sounding#") }
}

@MainActor
enum MacSmartPlaylistTracks {
    static func tracks(_ ids: [String], prep: MacPrepModel? = nil) -> [Track] {
        let local = Dictionary(LocalMusicLibrary.shared.allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return prep?.track(id) ?? MacPrepLibraryIndex.shared.track(id) ?? local[id]
        }
    }

    static func exportSource(_ kind: MacSmartPlaylist, tracks: [Track]) -> MacUSBExportSource {
        MacUSBExportSource(id: kind.exportID, name: kind.title, items: tracks.map(MacUSBExportSource.Item.init))
    }
}

@MainActor
final class MacCrateList: ObservableObject {
    static let shared = MacCrateList()

    @Published private(set) var crates: [RekordboxPlaylistRecord] = []

    private let store: CueStore
    private var observers: [NSObjectProtocol] = []
    private var feedTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var didWarmIndex = false

    init(store: CueStore = .shared) {
        self.store = store
        for name in [Notification.Name.rekordboxFolderImported, .macCratesDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        let feed = store.changes.subscribe()
        feedTask = Task { [weak self] in
            for await _ in feed {
                guard let self else { break }
                self.scheduleReload()
            }
        }
        scheduleReload()
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        if !didWarmIndex {
            didWarmIndex = true
            _ = await MacPrepLibraryIndex.shared.load()
        }
        let loaded = await store.rekordboxPlaylists()
        if loaded != crates { crates = loaded }
    }

    func crate(_ id: String) -> RekordboxPlaylistRecord? { crates.first { $0.id == id } }

    func tracks(in crate: RekordboxPlaylistRecord) -> [Track] {
        MacSmartPlaylistTracks.tracks(crate.trackIds)
    }

    func delete(_ id: String) {
        guard MacCrateID.isUserMade(id) else { return }
        let remaining = crates.filter { $0.id != id }
        crates = remaining
        let store = store
        Task {
            await store.saveRekordboxPlaylists(remaining)
        }
    }
}

@MainActor
final class MacSmartPlaylistModel: ObservableObject {
    let kind: MacSmartPlaylist

    @Published private(set) var rows: [MacLibraryRow] = []
    @Published private(set) var isLoading = true

    private let prep: MacPrepModel
    private let store: CueStore
    private var subscriptions: Set<AnyCancellable> = []
    private var feedTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var hasStarted = false

    init(kind: MacSmartPlaylist, store: CueStore = .shared) {
        self.kind = kind
        self.store = store
        prep = MacPrepModel(store: store)
    }

    var tracks: [Track] { rows.map(\.track) }

    var exportSource: MacUSBExportSource { MacSmartPlaylistTracks.exportSource(kind, tracks: tracks) }

    var summary: String {
        let count = "\(rows.count) \(rows.count == 1 ? "track" : "tracks")"
        let total = rows.reduce(0) { $0 + $1.track.duration }
        let duration = Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "\(count), \(duration)"
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if MacAnalysisIndex.shared.lastRefreshedAt == nil { await MacAnalysisIndex.shared.refresh() }
        prep.$isLoading
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .analysisDataDidChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAnalysis() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .rekordboxFolderImported)
            .merge(with: NotificationCenter.default.publisher(for: .macCratesDidChange))
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &subscriptions)
        let feed = store.changes.subscribe()
        feedTask = Task { [weak self] in
            for await _ in feed {
                guard let self else { break }
                self.scheduleReload()
            }
        }
        prep.source = .playlist("")
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.prep.reload()
        }
    }

    func refreshAnalysis() {
        Task { [weak self] in
            await MacAnalysisIndex.shared.refresh()
            self?.rebuild()
        }
    }

    private func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            let tracks = await self.currentTracks()
            guard !Task.isCancelled else { return }
            let added = Dictionary(self.prep.allRows.map { ($0.id, $0.addedMillis) }, uniquingKeysWith: { first, _ in first })
            self.rows = tracks.map { track in
                let millis = added[track.id] ?? 0
                return MacLibraryRow(
                    track: track,
                    analysis: MacAnalysisIndex.shared.result(forTrackId: track.id),
                    dateAdded: millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : nil
                )
            }
            self.isLoading = false
        }
    }

    private func currentTracks() async -> [Track] {
        switch kind {
        case .needsGridCheck, .notOnStick, .duplicates:
            guard let crate = kind.prepCrate else { return [] }
            return MacSmartPlaylistTracks.tracks(prep.rows(for: .smart(crate)).map(\.id), prep: prep)
        case .notAnalysed:
            return await missingAnalysis()
        case .crate(let id, _):
            let records = await store.rekordboxPlaylists()
            return MacSmartPlaylistTracks.tracks(records.first { $0.id == id }?.trackIds ?? [], prep: prep)
        }
    }

    private func missingAnalysis() async -> [Track] {
        let candidates = MacSmartPlaylistTracks.tracks(prep.allRows.map(\.id) + LocalMusicLibrary.shared.allTracks.map(\.id), prep: prep)
        let preps = await store.preps(forTracks: candidates.map(\.id))
        return candidates.filter { track in
            let summary = MacAnalysisIndex.shared.summariesByTrack[track.id] ?? AnalysisSummaries.shared.summary(for: track.id)
            return MissingAnalysis.isMissing(track, summary: summary, prep: preps[track.id])
        }
    }
}

struct MacSmartPlaylistView: View {
    let kind: MacSmartPlaylist

    @StateObject private var model: MacSmartPlaylistModel
    @ObservedObject private var run = MissingAnalysisRun.shared

    init(kind: MacSmartPlaylist) {
        self.kind = kind
        _model = StateObject(wrappedValue: MacSmartPlaylistModel(kind: kind))
    }

    private var isRunActive: Bool { run.progress.isActive || run.isPaused || run.isPreparing }

    var body: some View {
        Group {
            if model.isLoading, model.rows.isEmpty {
                MacLoadingView()
                    .macFillsPane()
            } else if model.rows.isEmpty {
                VStack(spacing: 0) {
                    if run.hasStatus {
                        MissingAnalysisProgressLine()
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    emptyState
                        .macFillsPane()
                }
            } else {
                VStack(spacing: 0) {
                    header
                    MacLibraryTable(
                        rows: model.rows,
                        showsArtwork: true,
                        usesCompactRows: false,
                        onLoad: { track, deck in
                            Task { try? await MacMixLoader.load(track, into: deck) }
                        },
                        onDoubleClick: { track in
                            let context = model.tracks
                            Task { await MacPlayback.play(track, in: context) }
                        },
                        onAnalysisChanged: { model.refreshAnalysis() },
                        storageKey: "smart",
                        showsSource: true,
                        exportScope: model.exportSource
                    )
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationSubtitle(model.rows.isEmpty ? "" : model.summary)
        .toolbar {
            ToolbarItem {
                Menu("Actions", systemImage: "ellipsis.circle") {
                    AnalyseMissingMenuItems(tracks: model.tracks, scopeTitle: kind.title)
                    Button("Export to USB…", systemImage: "externaldrive.badge.plus") {
                        MacRootSelection.shared.request(usbExport: model.exportSource)
                    }
                    .disabled(model.rows.isEmpty)
                }
            }
        }
        .focusedSceneValue(\.macUSBExportSource, model.rows.isEmpty ? nil : model.exportSource)
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    Text(model.summary)
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                if kind == .notAnalysed {
                    Button("Analyse Missing") { run.start(model.tracks) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunActive || model.rows.isEmpty)
                }
            }
            if run.hasStatus {
                MissingAnalysisProgressLine()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch kind {
        case .needsGridCheck:
            ContentUnavailableView("No Grids to Check", systemImage: "metronome", description: Text("Every beat grid looks right."))
        case .notAnalysed:
            ContentUnavailableView("All Analysed", systemImage: "waveform", description: Text("Every track has been analysed."))
        case .notOnStick:
            ContentUnavailableView("All on the Stick", systemImage: "externaldrive", description: Text("Your files are on your last USB export."))
        case .duplicates:
            ContentUnavailableView("No Duplicates", systemImage: "square.on.square", description: Text("No track appears twice."))
        case .crate:
            ContentUnavailableView("Nothing Here Yet", systemImage: "gearshape", description: Text("This crate is empty."))
        }
    }
}

@MainActor
enum MacAnalyseMissing {
    static func startLibrary() {
        MacRootSelection.shared.request(.smartPlaylist(.notAnalysed))
        MissingAnalysisRun.shared.startLibrary()
    }
}
