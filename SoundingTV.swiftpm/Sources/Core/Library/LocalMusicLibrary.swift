import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import CoreServices
#endif

struct MusicFolder: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var bookmark: Data
    let addedAt: Date
    var lastScannedAt: Date?
    var files: [LocalMusicFileEntry]
}

enum LocalMusicError: Error, LocalizedError {
    case folderUnavailable
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .folderUnavailable: return "This folder isn't available. Check Music Folders in Settings."
        case .fileMissing: return "This file is no longer in its folder."
        }
    }
}

struct LocalMusicScanProgress: Equatable, Sendable {
    let done: Int
    let total: Int
}

final class LocalMusicAccess: @unchecked Sendable {
    static let shared = LocalMusicAccess()
    private let lock = NSLock()
    private var roots: [String: URL] = [:]

    func setRoot(_ url: URL?, for folderID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let old = roots[folderID], old != url { old.stopAccessingSecurityScopedResource() }
        roots[folderID] = url
    }

    func root(for folderID: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return roots[folderID]
    }

    func fileURL(for file: LocalTrackFile) -> URL? {
        root(for: file.folderID)?.appendingPathComponent(file.relativePath)
    }
}

@MainActor
final class LocalMusicLibrary: ObservableObject {
    static let shared = LocalMusicLibrary()

    @Published private(set) var folders: [MusicFolder] = []
    @Published private(set) var scanningFolderIDs: Set<String> = []
    @Published private(set) var unavailableFolderIDs: Set<String> = []
    @Published private(set) var tracksByFolder: [String: [Track]] = [:]
    @Published private(set) var scanProgress: [String: LocalMusicScanProgress] = [:]

    private let directory: URL
    private let access: LocalMusicAccess
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var pendingDownloadRescans: [String: Int] = [:]
    private var watchers: [String: LocalMusicFolderWatcher] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private var isFixture = false

    nonisolated static var displayName: String {
        #if os(macOS)
        "On This Mac"
        #else
        "Files"
        #endif
    }

    nonisolated static var isSupported: Bool {
        #if os(tvOS) || os(watchOS)
        false
        #else
        true
        #endif
    }

    init(directory: URL = LocalMusicLibrary.defaultDirectory(), access: LocalMusicAccess = .shared) {
        self.directory = directory
        self.access = access
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        guard Self.isSupported else { return }
        #if DEBUG
        if let fixture = Self.fixtureFolders() {
            folders = fixture
            isFixture = true
            rebuildTracks()
            return
        }
        #endif
        load()
        for folder in folders { activate(folder) }
        rebuildTracks()
        observeForeground()
    }

    static func defaultDirectory() -> URL {
        AppDataDirectory.folder("LocalMusic")
    }

    var artworkDirectory: URL { directory.appendingPathComponent("Artwork", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("folders.json") }

    var allTracks: [Track] { folders.flatMap { tracksByFolder[$0.id] ?? [] } }

    func tracks(in folderID: String) -> [Track] { tracksByFolder[folderID] ?? [] }

    func folder(id: String) -> MusicFolder? { folders.first { $0.id == id } }

    func isScanning(_ folderID: String) -> Bool { scanningFolderIDs.contains(folderID) }

    func queueSource(for folder: MusicFolder) -> PlaybackQueueSource {
        PlaybackQueueSource(id: "folder:\(folder.id)", kind: .other, title: folder.name)
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(at url: URL) throws -> MusicFolder {
        guard Self.isSupported else { throw LocalMusicError.folderUnavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? Self.bookmark(for: url) else { throw LocalMusicError.folderUnavailable }
        if let existing = folders.first(where: { Self.resolve($0.bookmark)?.url.standardizedFileURL == url.standardizedFileURL }) {
            rescan(existing.id)
            return existing
        }
        let folder = MusicFolder(
            id: UUID().uuidString,
            name: FileManager.default.displayName(atPath: url.path),
            bookmark: bookmark,
            addedAt: Date(),
            lastScannedAt: nil,
            files: []
        )
        folders.append(folder)
        save()
        activate(folder)
        rescan(folder.id)
        return folder
    }

    func removeFolder(_ folderID: String) {
        scanTasks[folderID]?.cancel()
        scanTasks[folderID] = nil
        watchers[folderID] = nil
        access.setRoot(nil, for: folderID)
        if let folder = folder(id: folderID) {
            for entry in folder.files where entry.hasArtwork {
                let id = LocalMusicScanner.trackID(folderID: folderID, relativePath: entry.relativePath)
                try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent("\(id).jpg"))
            }
        }
        folders.removeAll { $0.id == folderID }
        tracksByFolder[folderID] = nil
        unavailableFolderIDs.remove(folderID)
        scanningFolderIDs.remove(folderID)
        scanProgress[folderID] = nil
        save()
    }

    func rescanAll() {
        for folder in folders { rescan(folder.id) }
    }

    func rescan(_ folderID: String) {
        guard !isFixture, let folder = folder(id: folderID) else { return }
        if access.root(for: folderID) == nil { activate(folder) }
        guard let root = access.root(for: folderID) else {
            unavailableFolderIDs.insert(folderID)
            return
        }
        scanTasks[folderID]?.cancel()
        scanningFolderIDs.insert(folderID)
        let previous = folder.files
        let artwork = artworkDirectory
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.scanningFolderIDs.contains(folderID) else { return }
                self.scanProgress[folderID] = LocalMusicScanProgress(done: done, total: total)
            }
        }
        scanTasks[folderID] = Task { [weak self] in
            let entries = await Task.detached(priority: .utility) {
                await LocalMusicScanner.scan(folderID: folderID, folderURL: root, previous: previous, artworkDirectory: artwork, progress: report)
            }.value
            guard !Task.isCancelled else { return }
            self?.finishScan(folderID: folderID, entries: entries, root: root)
        }
    }

    private func finishScan(folderID: String, entries: [LocalMusicFileEntry], root: URL) {
        scanTasks[folderID] = nil
        scanningFolderIDs.remove(folderID)
        scanProgress[folderID] = nil
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].files = entries
        folders[index].lastScannedAt = Date()
        save()
        rebuildTracks(folderID: folderID)
        requestDownloads(for: entries.filter { !$0.isDownloaded }, root: root, folderID: folderID)
    }

    // MARK: - Playback

    func playableURL(for track: Track) async throws -> URL {
        guard let file = track.localFile else { throw LocalMusicError.fileMissing }
        if RemoteLocalMusic.isRemote(file) { return try await RemoteLocalMusic.shared.playableURL(for: track) }
        if access.root(for: file.folderID) == nil, let folder = folder(id: file.folderID) { activate(folder) }
        guard let url = access.fileURL(for: file) else { throw LocalMusicError.folderUnavailable }
        if Self.isDownloaded(url) { return url }
        let coordinated = await Task.detached(priority: .userInitiated) { () -> URL? in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var result: URL?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                result = FileManager.default.isReadableFile(atPath: readURL.path) ? url : nil
            }
            return result
        }.value
        guard let coordinated else { throw LocalMusicError.fileMissing }
        return coordinated
    }

    nonisolated static func readyFileURL(for track: Track) -> URL? {
        if let file = track.localFile, RemoteLocalMusic.isRemote(file) { return RemoteLocalMusic.cachedFileURL(for: file) }
        guard let file = track.localFile, let url = LocalMusicAccess.shared.fileURL(for: file),
              isDownloaded(url) else { return nil }
        return url
    }

    nonisolated static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true {
            return values?.ubiquitousItemDownloadingStatus != .notDownloaded
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tracks

    private func rebuildTracks(folderID: String? = nil) {
        let targets = folderID.map { id in folders.filter { $0.id == id } } ?? folders
        for folder in targets {
            let root = access.root(for: folder.id)
            tracksByFolder[folder.id] = folder.files.compactMap { entry in
                Self.makeTrack(entry: entry, folder: folder, root: root, artworkDirectory: artworkDirectory)
            }
        }
    }

    static func makeTrack(entry: LocalMusicFileEntry, folder: MusicFolder, root: URL?, artworkDirectory: URL) -> Track? {
        let id = LocalMusicScanner.trackID(folderID: folder.id, relativePath: entry.relativePath)
        let fileURL = (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(entry.relativePath)
        return makeTrack(
            id: id,
            title: entry.title,
            artist: entry.artist ?? folder.name,
            album: entry.album,
            genre: entry.genre,
            duration: entry.duration,
            modifiedAt: entry.addedAt ?? entry.modifiedAt,
            fileURL: fileURL,
            ownerURL: root ?? fileURL,
            artworkURL: entry.hasArtwork ? artworkDirectory.appendingPathComponent("\(id).jpg") : nil,
            localFile: LocalTrackFile(folderID: folder.id, relativePath: entry.relativePath)
        )
    }

    static func makeTrack(
        id: String,
        title: String,
        artist: String,
        album: String?,
        genre: String?,
        duration: Double,
        modifiedAt: Date,
        fileURL: URL,
        ownerURL: URL,
        artworkURL: URL?,
        localFile: LocalTrackFile
    ) -> Track? {
        let artistID = LocalMusicScanner.trackID(folderID: "artist", relativePath: artist.lowercased())
        let extensionName = fileURL.pathExtension.lowercased()
        let user: [String: Any] = [
            "id": Int(artistID) ?? -1,
            "username": artist,
            "permalink": artist,
            "permalink_url": ownerURL.absoluteString,
            "track_count": 0, "playlist_count": 0, "followers_count": 0, "followings_count": 0,
        ]
        var json: [String: Any] = [
            "id": Int(id) ?? -1,
            "title": title,
            "permalink_url": fileURL.absoluteString,
            "created_at": modifiedAt.timeIntervalSince1970,
            "user": user,
            "likes_count": 0, "reposts_count": 0,
            "media": ["transcodings": [[
                "url": fileURL.absoluteString,
                "preset": "local_\(extensionName)",
                "duration": Int(duration * 1000),
                "quality": "hq",
                "snipped": false,
                "format": ["protocol": "progressive", "mime_type": mimeType(forExtension: extensionName)],
            ]]],
            "sounding_local_file": ["folderID": localFile.folderID, "relativePath": localFile.relativePath],
        ]
        if let artworkURL { json["artwork_url"] = artworkURL.absoluteString }
        if let genre { json["genre"] = genre }
        if let album { json["publisher_metadata"] = ["album_title": album] }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Track.self, from: data)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "alac": return "audio/alac"
        case "flac": return "audio/flac"
        case "wav", "wave": return "audio/wav"
        case "aif", "aiff", "aifc": return "audio/aiff"
        default: return "audio/x-caf"
        }
    }

    // MARK: - Access

    private func activate(_ folder: MusicFolder) {
        guard let resolved = Self.resolve(folder.bookmark) else {
            unavailableFolderIDs.insert(folder.id)
            return
        }
        _ = resolved.url.startAccessingSecurityScopedResource()
        access.setRoot(resolved.url, for: folder.id)
        unavailableFolderIDs.remove(folder.id)
        if resolved.isStale, let fresh = try? Self.bookmark(for: resolved.url),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = fresh
            save()
        }
        watchers[folder.id] = LocalMusicFolderWatcher(url: resolved.url) { [weak self] in
            Task { @MainActor in self?.rescan(folder.id) }
        }
    }

    nonisolated static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    nonisolated static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (url, stale)
    }

    private func requestDownloads(for entries: [LocalMusicFileEntry], root: URL, folderID: String) {
        guard !entries.isEmpty else {
            pendingDownloadRescans[folderID] = nil
            return
        }
        Task.detached(priority: .utility) {
            for entry in entries {
                try? FileManager.default.startDownloadingUbiquitousItem(at: root.appendingPathComponent(entry.relativePath))
            }
        }
        let attempt = pendingDownloadRescans[folderID, default: 0]
        guard attempt < 4 else { return }
        pendingDownloadRescans[folderID] = attempt + 1
        let delay = [15.0, 45.0, 120.0, 300.0][attempt]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.rescan(folderID)
        }
    }

    private func observeForeground() {
        #if canImport(UIKit) && !os(watchOS)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pendingDownloadRescans.removeAll()
                self?.rescanAll()
            }
        }
        #endif
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MusicFolder].self, from: data) else { return }
        folders = decoded
    }

    private func save() {
        guard !isFixture else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

#if DEBUG
extension LocalMusicLibrary {
    static func fixtureFolders() -> [MusicFolder]? {
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_LOCAL_MUSIC_FIXTURE"]?.lowercased() {
        case "empty": return []
        case "loaded", "1":
            let base = Date(timeIntervalSince1970: 1_790_000_000)
            func entry(_ path: String, _ title: String, _ artist: String, _ genre: String, _ seconds: Double, downloaded: Bool = true) -> LocalMusicFileEntry {
                LocalMusicFileEntry(
                    relativePath: path, fileSize: Int64(seconds * 40_000), modifiedAt: base.addingTimeInterval(-seconds),
                    title: title, artist: artist, album: nil, genre: genre, duration: seconds,
                    hasArtwork: false, isDownloaded: downloaded
                )
            }
            let crate = [
                entry("Warmup/First Light.flac", "First Light", "Night Tapes", "Deep House", 372),
                entry("Warmup/Neon Weather.m4a", "Neon Weather", "Maya Sol", "House", 401),
                entry("Peak/After Hours.aiff", "After Hours", "Glass District", "Tech House", 428),
                entry("Peak/Open Water.mp3", "Open Water", "Low Sun", "Melodic Techno", 455),
                entry("Peak/Parallel Lines.wav", "Parallel Lines", "Juno Vale", "Techno", 389),
                entry("Closing/Home Signal.flac", "Home Signal", "Soft Static", "Ambient", 512),
            ]
            let edits = [
                entry("Glue (Club Edit).m4a", "Glue (Club Edit)", "Night Tapes", "House", 318),
                entry("Copper Wire.mp3", "Copper Wire", "Maya Sol", "Garage", 0, downloaded: false),
            ]
            return [
                MusicFolder(id: "fixture-dj", name: "DJ Folder", bookmark: Data(), addedAt: base, lastScannedAt: base, files: crate),
                MusicFolder(id: "fixture-edits", name: "Edits", bookmark: Data(), addedAt: base, lastScannedAt: base, files: edits),
            ]
        default: return nil
        }
    }
}
#endif

final class LocalMusicFolderWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "red.forbes.sounding.localmusic.watch", qos: .utility)
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #else
    private var source: DispatchSourceFileSystemObject?
    #endif

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        #if os(macOS)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil, LocalMusicFolderWatcher.callback, &context,
            [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
        #else
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        #endif
    }

    deinit {
        #if os(macOS)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        #else
        source?.cancel()
        #endif
    }

    #if os(macOS)
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<LocalMusicFolderWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
    }
    #endif

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
