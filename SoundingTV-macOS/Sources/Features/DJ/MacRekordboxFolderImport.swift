import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let rekordboxFolderImported = Notification.Name("red.forbes.sounding.rekordbox.folderImported")
}

final class RekordboxFolderCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor
final class MacRekordboxFolderImport: ObservableObject {
    struct Found {
        var scan: RekordboxFolderScan
        var summary: RekordboxFolderSummary
    }

    enum Phase {
        case scanning
        case needsExport
        case nothingFound
        case ready(Found)
        case review(RekordboxImportPlan)
        case importing
        case done(RekordboxFolderResult)
    }

    static let exportHelpURL = URL(string: "https://rekordbox.com/en/support/faq/")
    static let pendingFolderID = "pending-rekordbox-folder"

    @Published var phase: Phase = .scanning
    @Published private(set) var progress = RekordboxFolderProgress()
    @Published var showsMissing = false
    @Published private(set) var missing: [RekordboxFolderMatch] = []

    let url: URL
    let library: MacRekordboxLibrary
    private let musicLibrary: LocalMusicLibrary
    private let cancelFlag = RekordboxFolderCancelFlag()
    private var scoped: [URL] = []
    private var extraAudio: [String] = []
    private var scan: RekordboxFolderScan?
    private var matches: [RekordboxFolderMatch] = []
    private var task: Task<Void, Never>?

    init(url: URL, library: MacRekordboxLibrary = .shared, musicLibrary: LocalMusicLibrary = .shared) {
        self.url = url
        self.library = library
        self.musicLibrary = musicLibrary
    }

    var folderName: String { FileManager.default.displayName(atPath: url.path) }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func finish() {
        cancelFlag.cancel()
        task?.cancel()
        for scopedURL in scoped { scopedURL.stopAccessingSecurityScopedResource() }
        scoped = []
        if case .review = phase { library.conflictChoices = [:] }
    }

    func openExportHelp() {
        guard let help = Self.exportHelpURL else { return }
        NSWorkspace.shared.open(help)
    }

    // MARK: - Scan

    private func run() async {
        phase = .scanning
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        let root = url.path
        let flag = cancelFlag
        let report: @Sendable (RekordboxFolderProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        let found = await Task.detached(priority: .userInitiated) { () -> RekordboxFolderScan in
            let classification = RekordboxFolderClassifier.classify(root: root)
            return RekordboxFolderScanner.scan(classification, readers: .live(), progress: report, isCancelled: { flag.isCancelled })
        }.value
        guard !flag.isCancelled else { return }
        if found.tracks.isEmpty && found.classification.audioFiles.isEmpty {
            phase = found.classification.hasAppData ? .needsExport : .nothingFound
            return
        }
        scan = found
        await rematch()
    }

    private var existingRoots: [RekordboxFolderRoot] {
        musicLibrary.folders.compactMap { folder in
            LocalMusicAccess.shared.root(for: folder.id).map { RekordboxFolderRoot(folderID: folder.id, path: $0.path) }
        }
    }

    private var needsMusicFolder: Bool {
        guard isDirectory, let scan, !scan.classification.audioFiles.isEmpty else { return false }
        return RekordboxFolderFiles.root(containing: url.path, in: existingRoots) == nil
    }

    private func rematch(showing: Bool = true) async {
        guard let scan else { return }
        var roots = existingRoots
        if needsMusicFolder { roots.append(RekordboxFolderRoot(folderID: Self.pendingFolderID, path: url.path)) }
        let chosen = RekordboxFolderFiles.localFiles(scan.classification.audioFiles + extraAudio, roots: roots)
        let existing = await MacRekordboxShareSources.liveLocalFiles(store: library.store)
        let known = Set(existing.map { RekordboxShareMatcher.normalisedPath($0.path) })
        let added = chosen.filter { !known.contains(RekordboxShareMatcher.normalisedPath($0.path)) }
        let files = existing + added
        let local = musicLibrary.allTracks.map {
            MatchCandidate(trackId: $0.id, title: $0.title, artist: $0.user.username, durationSeconds: $0.duration)
        } + RekordboxFolderFiles.candidates(added)
        let other = await MacRekordboxLibrary.liveCandidates().filter { !LocalTrackFile.isLocalTrackID($0.trackId) }
        let tracks = scan.tracks
        let matched = await Task.detached(priority: .userInitiated) {
            RekordboxFolderMatcher.match(tracks, files: files, local: local, other: other)
        }.value
        matches = matched
        missing = matched.filter { $0.outcome.linkedTrackId == nil }
        if showing {
            phase = .ready(Found(scan: scan, summary: RekordboxFolderMatcher.summary(scan, matches: matched, newAudioFiles: added.count)))
        }
    }

    // MARK: - Music access

    var suggestedMusicFolder: URL? {
        if let scan, scan.classification.stickOutsideSelection, let stick = scan.classification.stickRoots.first {
            return URL(fileURLWithPath: stick, isDirectory: true)
        }
        let folders = missing.compactMap { $0.item.filePath }.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().pathComponents
        }
        guard var common = folders.first else { return nil }
        for components in folders.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 2 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    var canAllowMusicAccess: Bool {
        !missing.isEmpty && missing.contains { $0.item.filePath?.hasPrefix("/") == true }
    }

    func allowMusicAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds the missing music."
        panel.prompt = "Allow Access"
        if let suggested = suggestedMusicFolder { panel.directoryURL = suggested }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        _ = try? musicLibrary.addFolder(at: chosen)
        if chosen.startAccessingSecurityScopedResource() { scoped.append(chosen) }
        let path = chosen.path
        phase = .scanning
        Task {
            let audio = await Task.detached(priority: .userInitiated) {
                RekordboxFolderClassifier.classify(root: path).audioFiles
            }.value
            extraAudio = Array(Set(extraAudio + audio)).sorted()
            await rematch()
        }
    }

    // MARK: - Import

    func commit() async {
        guard scan != nil else { return }
        showsMissing = false
        phase = .importing
        if needsMusicFolder { _ = try? musicLibrary.addFolder(at: url) }
        await rematch(showing: false)
        let plan = await RekordboxFolderImporter.plan(matches, store: library.store)
        if plan.conflicts.isEmpty {
            await apply(plan)
        } else {
            library.conflictChoices = Dictionary(plan.conflicts.map { ($0.id, ImportChoice.keepSounding) }, uniquingKeysWith: { first, _ in first })
            phase = .review(plan)
        }
    }

    func apply(_ plan: RekordboxImportPlan) async {
        guard let scan else { return }
        phase = .importing
        let result = await RekordboxFolderImporter.apply(
            plan,
            choices: library.conflictChoices,
            matches: matches,
            playlists: scan.playlists,
            store: library.store
        )
        library.conflictChoices = [:]
        await library.refreshCounts()
        NotificationCenter.default.post(name: .rekordboxFolderImported, object: nil)
        phase = .done(result)
    }
}

// MARK: - Presentation

@MainActor
final class MacRekordboxFolderPresenter: ObservableObject {
    static let shared = MacRekordboxFolderPresenter()

    @Published var model: MacRekordboxFolderImport?

    private init() {}

    nonisolated static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        return RekordboxFolderLayout.isXML(url.lastPathComponent)
    }

    static func choose() {
        guard shared.model == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .xml]
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a rekordbox USB or SD drive, your rekordbox folder, or a collection exported as XML."
        panel.prompt = "Import"
        if let window = MacMainWindow.current {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                present(url)
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            present(url)
        }
    }

    static func present(_ url: URL) {
        guard shared.model == nil, accepts(url) else { return }
        let model = MacRekordboxFolderImport(url: url)
        shared.model = model
        model.start()
    }

    static func dismiss() {
        guard let current = shared.model else { return }
        shared.model = nil
        current.finish()
    }
}

extension MacRekordboxFolderImport: Identifiable {}

private struct MacRekordboxFolderImportPresentation: ViewModifier {
    @ObservedObject private var presenter = MacRekordboxFolderPresenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { presenter.model },
                set: { if $0 == nil { MacRekordboxFolderPresenter.dismiss() } }
            )) { model in
                MacRekordboxFolderSheet(model: model) { MacRekordboxFolderPresenter.dismiss() }
            }
    }
}

extension View {
    func macRekordboxFolderImportPresentation() -> some View {
        modifier(MacRekordboxFolderImportPresentation())
    }
}

private struct MacRekordboxFolderDrop: ViewModifier {
    let onImported: () -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: MacRekordboxFolderPresenter.accepts) else { return false }
                MacRekordboxFolderPresenter.present(url)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.scAccent, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rekordboxFolderImported)) { _ in onImported() }
    }
}

extension View {
    func macRekordboxFolderImport(onImported: @escaping () -> Void) -> some View {
        modifier(MacRekordboxFolderDrop(onImported: onImported))
    }
}
