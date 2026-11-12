import Foundation

extension Notification.Name {
    static let soundingDataLocationDidChange = Notification.Name("red.forbes.sounding.data.locationDidChange")
    static let soundingDataDidChangeOnDisk = Notification.Name("red.forbes.sounding.data.didChangeOnDisk")
}

enum SoundingDataArea: String, CaseIterable, Sendable {
    case analysis = "Analysis"
    case insights = "Insights"
    case mixHistory = "Mix History"
    case autoMixRatings = "Auto Mix Ratings"
    case setlists = "Setlists"
}

struct SoundingDataManifest: Codable, Equatable, Sendable {
    var format: Int
    var id: String
    var createdAt: Date
}

enum SoundingDataDevice {
    static let defaultsKey = "red.forbes.sounding.data.deviceId"

    static func id(defaults: UserDefaults = .sounding) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

final class SoundingDataLocation: @unchecked Sendable {
    static let shared = SoundingDataLocation()

    static let areaKey = "area"
    static let folderName = "Sounding Data"
    static let offlineFolderName = "Sounding Data (Offline)"
    static let manifestName = "Sounding Data.manifest"
    static let bookmarkKey = "red.forbes.sounding.data.locationBookmark"
    static let pathKey = "red.forbes.sounding.data.locationPath"

    enum Status: Equatable, Sendable {
        case standard
        case custom(URL)
        case unavailable(URL)
    }

    enum AdoptMode: Sendable {
        case move
        case useExisting
    }

    static var supportsCustomLocation: Bool {
        #if os(macOS) || os(iOS)
        return true
        #else
        return false
        #endif
    }

    let standardRoot: URL
    let offlineRoot: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var currentStatus: Status = .standard
    private var currentRoot: URL
    private var scopedURL: URL?
    private var currentPresenter: SoundingDataPresenter?
    private var monitoring = false

    init(defaults: UserDefaults = .sounding, standardRoot: URL? = nil) {
        self.defaults = defaults
        let base = standardRoot?.deletingLastPathComponent() ?? AppDataDirectory.root
        self.standardRoot = standardRoot ?? base.appendingPathComponent(Self.folderName, isDirectory: true)
        offlineRoot = base.appendingPathComponent(Self.offlineFolderName, isDirectory: true)
        currentRoot = self.standardRoot
        resolve(posting: false)
    }

    var root: URL {
        lock.withLock { currentRoot }
    }

    var status: Status {
        lock.withLock { currentStatus }
    }

    var presenter: NSFilePresenter? {
        lock.withLock { currentPresenter }
    }

    func directory(_ area: SoundingDataArea) -> URL {
        let url = root.appendingPathComponent(area.rawValue, isDirectory: true)
        AppDataDirectory.prepare(url)
        return url
    }

    // MARK: Resolution

    func refresh() {
        resolve(posting: true)
    }

    private func resolve(posting: Bool) {
        let previous = lock.withLock { (currentStatus, currentRoot) }
        var nextStatus: Status = .standard
        var nextRoot = standardRoot
        var nextScoped: URL?

        if Self.supportsCustomLocation, let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let chosen = try? URL(resolvingBookmarkData: bookmark, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let accessing = chosen.startAccessingSecurityScopedResource()
                let libraryRoot = Self.libraryRoot(forChosen: chosen)
                if Self.isUsable(libraryRoot) {
                    nextStatus = .custom(libraryRoot)
                    nextRoot = libraryRoot
                    nextScoped = accessing ? chosen : nil
                    if stale, let fresh = try? chosen.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        defaults.set(fresh, forKey: Self.bookmarkKey)
                    }
                } else {
                    if accessing { chosen.stopAccessingSecurityScopedResource() }
                    nextStatus = .unavailable(libraryRoot)
                    nextRoot = offlineRoot
                }
            } else {
                let remembered = defaults.string(forKey: Self.pathKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
                nextStatus = .unavailable(remembered ?? standardRoot)
                nextRoot = offlineRoot
            }
        }

        AppDataDirectory.prepare(nextRoot)
        Self.writeManifestIfNeeded(in: nextRoot)

        let oldScoped: URL? = lock.withLock {
            let old = scopedURL
            currentStatus = nextStatus
            currentRoot = nextRoot
            scopedURL = nextScoped
            return old
        }
        if let oldScoped, oldScoped != nextScoped { oldScoped.stopAccessingSecurityScopedResource() }
        installPresenter(for: nextRoot)

        if case .custom(let customRoot) = nextStatus, case .unavailable = previous.0 {
            Task.detached(priority: .utility) { [offlineRoot] in
                _ = await SoundingDataTransfer.transfer(from: offlineRoot, to: customRoot, progress: nil)
                NotificationCenter.default.post(name: .soundingDataLocationDidChange, object: nil)
            }
        }
        if case .unavailable = nextStatus { startMonitoring() }
        if posting, previous.0 != nextStatus || previous.1 != nextRoot {
            NotificationCenter.default.post(name: .soundingDataLocationDidChange, object: nil)
        }
    }

    private func installPresenter(for root: URL) {
        #if os(macOS) || os(iOS)
        let (old, needsNew): (SoundingDataPresenter?, Bool) = lock.withLock {
            (currentPresenter, currentPresenter?.presentedItemURL != root)
        }
        guard needsNew else { return }
        if let old { NSFileCoordinator.removeFilePresenter(old) }
        let presenter = SoundingDataPresenter(root: root)
        NSFileCoordinator.addFilePresenter(presenter)
        lock.withLock { currentPresenter = presenter }
        #endif
    }

    private func startMonitoring() {
        let shouldStart: Bool = lock.withLock {
            guard !monitoring else { return false }
            monitoring = true
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(30))
                guard case .unavailable = self.status else { break }
                self.refresh()
            }
            self?.lock.withLock { self?.monitoring = false }
        }
    }

    // MARK: Choosing

    func choose(_ chosen: URL, mode: AdoptMode, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let accessing = chosen.startAccessingSecurityScopedResource()
        defer { if accessing { chosen.stopAccessingSecurityScopedResource() } }
        let bookmark = try chosen.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        let destination = Self.libraryRoot(forChosen: chosen)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root
        if mode == .move, source.standardizedFileURL != destination.standardizedFileURL {
            let result = await SoundingDataTransfer.transfer(from: source, to: destination, progress: progress)
            if !result.failed.isEmpty { throw SoundingDataTransfer.Failure(count: result.failed.count) }
        }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(destination.path, forKey: Self.pathKey)
        refresh()
        NotificationCenter.default.post(name: .soundingDataLocationDidChange, object: nil)
    }

    func resetToStandard(mode: AdoptMode, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let source = root
        if mode == .move, source.standardizedFileURL != standardRoot.standardizedFileURL {
            let result = await SoundingDataTransfer.transfer(from: source, to: standardRoot, progress: progress)
            if !result.failed.isEmpty { throw SoundingDataTransfer.Failure(count: result.failed.count) }
        }
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
        refresh()
        NotificationCenter.default.post(name: .soundingDataLocationDidChange, object: nil)
    }

    static func containsData(_ chosen: URL) -> Bool {
        let root = libraryRoot(forChosen: chosen)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestName).path) { return true }
        return SoundingDataArea.allCases.contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.rawValue, isDirectory: true).path)
        }
    }

    static func libraryRoot(forChosen chosen: URL) -> URL {
        if chosen.lastPathComponent == folderName { return chosen }
        if FileManager.default.fileExists(atPath: chosen.appendingPathComponent(manifestName).path) { return chosen }
        return chosen.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func isUsable(_ root: URL) -> Bool {
        let parent = root.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: root.path)
        }
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)) != nil
    }

    private static func writeManifestIfNeeded(in root: URL) {
        let url = root.appendingPathComponent(manifestName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let manifest = SoundingDataManifest(format: Int(SoundingDataFormat.version), id: UUID().uuidString, createdAt: Date())
        guard let data = try? SoundingDataFormat.encode(manifest, kind: .manifest) else { return }
        try? SoundingDataFiles.writeAtomically(data, to: url)
    }

    private static var bookmarkOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolveOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
}

// MARK: - Transfer

enum SoundingDataTransfer {
    struct Failure: LocalizedError {
        let count: Int
        var errorDescription: String? { count == 1 ? "1 file couldn't be moved." : "\(count) files couldn't be moved." }
    }

    struct Result: Equatable, Sendable {
        var copied = 0
        var skipped = 0
        var failed: [String] = []
    }

    static func transfer(from source: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async -> Result {
        await Task.detached(priority: .utility) {
            transferNow(from: source, to: destination, progress: progress)
        }.value
    }

    static func transferNow(from source: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) -> Result {
        var result = Result()
        let files = regularFiles(in: source)
        guard !files.isEmpty else {
            progress?(1)
            return result
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var verified: [URL] = []
        for (index, file) in files.enumerated() {
            defer { progress?(Double(index + 1) / Double(files.count)) }
            let relative = String(file.path.dropFirst(source.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty, let data = try? Data(contentsOf: file) else {
                result.failed.append(relative)
                continue
            }
            if relative == SoundingDataLocation.manifestName,
               FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path) {
                verified.append(file)
                result.skipped += 1
                continue
            }
            var target = destination.appendingPathComponent(relative)
            if case .data(let existing) = SoundingDataFiles.read(target) {
                if existing == data {
                    verified.append(file)
                    result.skipped += 1
                    continue
                }
                var attempt = 0
                repeat {
                    target = SoundingDataFiles.movedCopyName(for: destination.appendingPathComponent(relative), attempt: attempt)
                    attempt += 1
                } while FileManager.default.fileExists(atPath: target.path)
            }
            do {
                try SoundingDataFiles.write(data, to: target)
                if case .data(let written) = SoundingDataFiles.read(target), written == data {
                    verified.append(file)
                    result.copied += 1
                } else {
                    result.failed.append(relative)
                }
            } catch {
                result.failed.append(relative)
            }
        }
        for file in verified { SoundingDataFiles.remove(file) }
        pruneEmptyDirectories(in: source)
        return result
    }

    static func regularFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !SoundingDataFiles.isTemporary(url.lastPathComponent) else { continue }
            out.append(url.standardizedFileURL)
        }
        return out.sorted { $0.path < $1.path }
    }

    static func pruneEmptyDirectories(in root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            directories.append(url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
