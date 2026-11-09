import CryptoKit
import Foundation

enum SoundingDataRead: Equatable {
    case data(Data)
    case notDownloaded
    case missing
}

enum SoundingDataFiles {
    static let temporaryMarker = ".sounding-tmp"

    static func hashName(_ text: String, length: Int = 32) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    static func shardedDirectory(in root: URL, for hash: String) -> URL {
        root.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
    }

    @discardableResult
    static func write(_ data: Data, to url: URL, presenter: NSFilePresenter? = SoundingDataLocation.shared.presenter) throws -> Bool {
        if case .data(let existing) = read(url), existing == data { return false }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            SoundingDataSelfWrites.shared.note(directory)
        }
        defer { SoundingDataSelfWrites.shared.note(url) }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try writeAtomically(data, to: target)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return true
    }

    static func writeAtomically(_ data: Data, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)\(temporaryMarker)")
        try data.write(to: temporary, options: [.withoutOverwriting])
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func needsDownload(_ url: URL) -> Bool {
        #if os(macOS) || os(iOS)
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
        guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
        #else
        return false
        #endif
    }

    static func read(_ url: URL, knownDownloaded: Bool = false) -> SoundingDataRead {
        if knownDownloaded {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return .missing }
            return .data(data)
        }
        if needsDownload(url) {
            requestDownload(url)
            return .notDownloaded
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) {
                requestDownload(url)
                return .notDownloaded
            }
            return .missing
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return .missing }
        return .data(data)
    }

    static func remove(_ url: URL, presenter: NSFilePresenter? = SoundingDataLocation.shared.presenter) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            try? FileManager.default.removeItem(at: target)
        }
        SoundingDataSelfWrites.shared.note(url)
    }

    static func requestDownload(_ url: URL) {
        #if os(macOS) || os(iOS)
        guard SoundingDataDownloadRequests.shared.shouldRequest(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        #endif
    }

    static func isTemporary(_ name: String) -> Bool {
        name.hasSuffix(temporaryMarker) || name == ".DS_Store"
    }

    static func placeholderTarget(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    struct Entry: Equatable, Sendable {
        let url: URL
        let size: Int
        let modified: Date
        let isDownloaded: Bool
        let hasUnresolvedConflicts: Bool

        init(url: URL, size: Int, modified: Date, isDownloaded: Bool, hasUnresolvedConflicts: Bool = false) {
            self.url = url
            self.size = size
            self.modified = modified
            self.isDownloaded = isDownloaded
            self.hasUnresolvedConflicts = hasUnresolvedConflicts
        }
    }

    private static var enumerationKeys: [URLResourceKey] {
        var keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        #if os(macOS) || os(iOS)
        keys += [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey]
        #endif
        return keys
    }

    static func files(in root: URL, extension pathExtension: String) -> [Entry] {
        let keys = enumerationKeys
        let keySet = Set(keys)
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        var out: [Entry] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if isTemporary(name) { continue }
            if let target = placeholderTarget(url) {
                if target.pathExtension == pathExtension {
                    requestDownload(target)
                    out.append(Entry(url: target, size: 0, modified: .distantPast, isDownloaded: false))
                }
                continue
            }
            guard url.pathExtension == pathExtension,
                  let values = try? url.resourceValues(forKeys: keySet),
                  values.isRegularFile == true else { continue }
            var downloaded = true
            var conflicted = false
            #if os(macOS) || os(iOS)
            if values.isUbiquitousItem == true {
                if let status = values.ubiquitousItemDownloadingStatus { downloaded = status == .current }
                conflicted = values.ubiquitousItemHasUnresolvedConflicts == true
            }
            #endif
            if !downloaded { requestDownload(url) }
            out.append(Entry(
                url: url,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast,
                isDownloaded: downloaded,
                hasUnresolvedConflicts: conflicted
            ))
        }
        return out
    }

    static func bytes(in root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Conflicts

    nonisolated(unsafe) private static let conflictSuffix = try? NSRegularExpression(
        pattern: #"^(.*[^ ])(?: (?:[2-9]|[1-9][0-9]+)| \([1-9][0-9]*\)| \([^()]*conflicted copy[^()]*\)| \(Moved(?: [1-9][0-9]*)?\)|\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]{7})$"#,
        options: [.caseInsensitive]
    )

    static func conflictBase(of url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let conflictSuffix,
              let match = conflictSuffix.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem) else { return nil }
        let base = String(stem[range])
        guard base != stem else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(url.pathExtension)
    }

    static func movedCopyName(for url: URL, attempt: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = attempt == 0 ? " (Moved)" : " (Moved \(attempt))"
        return url.deletingLastPathComponent().appendingPathComponent(stem + suffix).appendingPathExtension(url.pathExtension)
    }

    static func resolveConflicts(
        in entries: [Entry],
        merge: (_ current: Data, _ other: Data) -> Data?
    ) -> [Entry] {
        var survivors: [String: Entry] = [:]
        var copies: [String: (base: URL, variants: [Entry])] = [:]
        for entry in entries {
            if let base = conflictBase(of: entry.url) {
                let key = base.standardizedFileURL.path
                copies[key, default: (base, [])].variants.append(entry)
            } else {
                survivors[entry.url.standardizedFileURL.path] = entry
            }
        }
        for (key, group) in copies {
            let base = group.base
            let variants = group.variants
            var current: Data?
            switch read(base) {
            case .data(let data): current = data
            case .notDownloaded: continue
            case .missing: break
            }
            var changed = false
            var allRead = true
            for variant in variants {
                guard variant.isDownloaded, case .data(let other) = read(variant.url) else {
                    allRead = false
                    continue
                }
                if let existing = current {
                    if existing != other, let merged = merge(existing, other), merged != existing {
                        current = merged
                        changed = true
                    }
                } else {
                    current = other
                    changed = true
                }
            }
            var saved = true
            if changed, let current { saved = (try? write(current, to: base)) != nil }
            if allRead, saved, current != nil {
                for variant in variants { remove(variant.url) }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: base.path)
            survivors[key] = Entry(
                url: base,
                size: (attributes?[.size] as? NSNumber)?.intValue ?? current?.count ?? 0,
                modified: attributes?[.modificationDate] as? Date ?? .distantPast,
                isDownloaded: current != nil
            )
        }
        for entry in survivors.values where entry.isDownloaded && entry.hasUnresolvedConflicts {
            resolveVersionConflicts(at: entry.url, merge: merge)
        }
        return Array(survivors.values)
    }

    static func resolveVersionConflicts(at url: URL, merge: (_ current: Data, _ other: Data) -> Data?) {
        #if os(macOS) || os(iOS)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty,
              case .data(var current) = read(url) else { return }
        var changed = false
        for version in versions {
            if let other = try? Data(contentsOf: version.url), other != current, let merged = merge(current, other), merged != current {
                current = merged
                changed = true
            }
        }
        if changed { _ = try? write(current, to: url) }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        SoundingDataSelfWrites.shared.note(url)
        #endif
    }
}

// MARK: - Own writes

final class SoundingDataSelfWrites: @unchecked Sendable {
    static let shared = SoundingDataSelfWrites()

    struct Signature: Equatable, Sendable {
        let exists: Bool
        let isDirectory: Bool
        let size: Int
        let modified: Date?
    }

    private struct Record {
        let signature: Signature
        let at: Date
    }

    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var records: [String: Record] = [:]
    private var currentGeneration = 0

    init(lifetime: TimeInterval = 900) {
        self.lifetime = lifetime
    }

    var generation: Int {
        lock.withLock { currentGeneration }
    }

    static func signature(of url: URL) -> Signature {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return Signature(exists: false, isDirectory: false, size: 0, modified: nil)
        }
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        return Signature(
            exists: true,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: isDirectory ? nil : attributes[.modificationDate] as? Date
        )
    }

    func note(_ url: URL, now: Date = Date()) {
        let key = url.standardizedFileURL.path
        let record = Record(signature: Self.signature(of: url), at: now)
        lock.withLock {
            currentGeneration += 1
            records[key] = record
            if records.count > 4096 {
                let lifetime = lifetime
                records = records.filter { now.timeIntervalSince($0.value.at) < lifetime }
            }
        }
    }

    func isOwnChange(_ url: URL, now: Date = Date()) -> Bool {
        let key = url.standardizedFileURL.path
        guard let record = lock.withLock({ records[key] }) else { return false }
        guard now.timeIntervalSince(record.at) < lifetime else {
            lock.withLock { _ = records.removeValue(forKey: key) }
            return false
        }
        let current = Self.signature(of: url)
        if record.signature.isDirectory { return current.isDirectory }
        return current == record.signature
    }
}

final class SoundingDataDownloadRequests: @unchecked Sendable {
    static let shared = SoundingDataDownloadRequests()

    private let lock = NSLock()
    private let retryAfter: TimeInterval
    private var requested: [String: Date] = [:]

    init(retryAfter: TimeInterval = 600) {
        self.retryAfter = retryAfter
    }

    func shouldRequest(_ url: URL, now: Date = Date()) -> Bool {
        let key = url.standardizedFileURL.path
        let retryAfter = retryAfter
        return lock.withLock {
            if let last = requested[key], now.timeIntervalSince(last) < retryAfter { return false }
            requested[key] = now
            return true
        }
    }
}

// MARK: - Presenter

final class SoundingDataPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    init(root: URL) {
        presentedItemURL = root
        super.init()
    }

    func presentedSubitemDidChange(at url: URL) {
        notify(url)
    }

    func presentedSubitemDidAppear(at url: URL) {
        notify(url)
    }

    func presentedItemDidChange() {
        notify(nil)
    }

    private func notify(_ url: URL?) {
        guard let root = presentedItemURL else { return }
        var area: String?
        if let url {
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) {
                area = path.dropFirst(rootPath.count).split(separator: "/").first.map(String.init)
            }
        }
        if let name = url?.lastPathComponent, SoundingDataFiles.isTemporary(name) { return }
        if let url, SoundingDataSelfWrites.shared.isOwnChange(url) { return }
        NotificationCenter.default.post(
            name: .soundingDataDidChangeOnDisk,
            object: nil,
            userInfo: area.map { [SoundingDataLocation.areaKey: $0] }
        )
    }
}
