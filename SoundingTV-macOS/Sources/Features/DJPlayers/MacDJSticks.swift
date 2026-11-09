import AppKit
import Foundation

struct MacStickVolume: Identifiable {
    let id: String
    let name: String
    let rootPath: String
    let library: DJStickLibrary

    var trackCount: Int { library.tracks.count }
}

final class MacDJSticksSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [(id: String, path: String)] = []
    private var generation = 0

    func update(roots: [(id: String, path: String)], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.roots = roots
        self.generation = generation
    }

    func read() -> (roots: [(id: String, path: String)], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (roots, generation)
    }
}

@MainActor
final class MacDJSticks: ObservableObject {
    static let shared = MacDJSticks()

    @Published private(set) var volumes: [MacStickVolume] = []
    @Published private(set) var generation = 0

    nonisolated let snapshot = MacDJSticksSnapshot()

    private let defaults: UserDefaults
    private let io: DJStickIO
    private let cache: DJStickLibraryCache
    private var access: [String: URL] = [:]
    private var observers: [NSObjectProtocol] = []
    private var signature = ""
    private var isFixture = false

    private enum Key {
        static let bookmarks = "djSticks.bookmarks"
    }

    init(defaults: UserDefaults = .standard, io: DJStickIO = DJStickPOSIXIO(), cache: DJStickLibraryCache = .shared) {
        self.defaults = defaults
        self.io = io
        self.cache = cache
    }

    func start() {
        guard observers.isEmpty, !isFixture else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        Task { await refresh() }
    }

    func volume(id: String) -> MacStickVolume? {
        volumes.first { $0.id == id }
    }

    func refresh() async {
        guard !isFixture else { return }
        var found: [MacStickVolume] = []
        let stored = bookmarks()
        for (id, data) in stored.sorted(by: { $0.key < $1.key }) {
            guard let url = resolve(id: id, bookmark: data) else { continue }
            let root = url.path
            guard let library = await cache.library(volumeKey: id, root: root, io: io) else { continue }
            found.append(MacStickVolume(id: id, name: displayName(for: url), rootPath: root, library: library))
        }
        for id in access.keys where !found.contains(where: { $0.id == id }) {
            access[id]?.stopAccessingSecurityScopedResource()
            access[id] = nil
        }
        let next = found.map { "\($0.id)|\($0.rootPath)|\($0.trackCount)" }.joined(separator: ";")
        guard next != signature else { return }
        signature = next
        volumes = found
        generation += 1
        snapshot.update(roots: found.map { ($0.id, $0.rootPath) }, generation: generation)
    }

    @discardableResult
    func addStick() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.message = "Choose a CDJ stick."
        panel.prompt = "Allow Access"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let accepted = await allow(url)
        if !accepted {
            let alert = NSAlert()
            alert.messageText = "No rekordbox Library on “\(url.lastPathComponent)”"
            alert.informativeText = "Choose the top level of a stick exported from rekordbox."
            alert.runModal()
        }
        return accepted
    }

    func allow(_ url: URL) async -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard DJStickLayout.isStick(root: url.path, io: io) else { return false }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            ?? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        var stored = bookmarks()
        stored[Self.identity(of: url)] = data
        defaults.set(stored, forKey: Key.bookmarks)
        await refresh()
        return true
    }

    func forget(id: String) async {
        var stored = bookmarks()
        stored[id] = nil
        defaults.set(stored, forKey: Key.bookmarks)
        access[id]?.stopAccessingSecurityScopedResource()
        access[id] = nil
        await cache.forget(volumeKey: id)
        await refresh()
    }

    private func bookmarks() -> [String: Data] {
        defaults.dictionary(forKey: Key.bookmarks) as? [String: Data] ?? [:]
    }

    private func resolve(id: String, bookmark: Data) -> URL? {
        if let url = access[id] { return url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        access[id] = url
        return url
    }

    private func displayName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
    }

    static func identity(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? url.path
    }

    #if DEBUG
    func installFixture(_ volumes: [MacStickVolume]) {
        isFixture = true
        self.volumes = volumes
        generation += 1
        snapshot.update(roots: volumes.map { ($0.id, $0.rootPath) }, generation: generation)
    }
    #endif
}

struct MacDJPlayersStickCatalog: DJPlayersStickCatalog {
    let snapshot: MacDJSticksSnapshot
    let cache: DJStickLibraryCache

    @MainActor
    init(sticks: MacDJSticks = .shared, cache: DJStickLibraryCache = .shared) {
        snapshot = sticks.snapshot
        self.cache = cache
    }

    func generation() async -> Int {
        snapshot.read().generation
    }

    func candidates(rekordboxId: UInt32) async -> [DJPlayersStickCandidate] {
        var found: [DJPlayersStickCandidate] = []
        for root in snapshot.read().roots {
            guard let library = await cache.library(volumeKey: root.id, root: root.path),
                  let track = library.track(id: rekordboxId) else { continue }
            found.append(DJPlayersStickCandidate(
                volume: root.id,
                title: track.title,
                artist: track.artist.isEmpty ? nil : track.artist,
                durationSeconds: track.durationSeconds,
                bpm: track.bpm,
                isrc: track.isrc
            ))
        }
        return found
    }
}
