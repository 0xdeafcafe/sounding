import Foundation
import Combine
import CryptoKit

struct DuplicateDecisions: Codable, Equatable, Sendable {
    var hidden: Set<String> = []
    var dismissed: [Set<String>] = []

    func isDismissed(_ ids: Set<String>) -> Bool {
        dismissed.contains { ids.isSubset(of: $0) }
    }
}

struct DuplicateImportNotice: Identifiable, Equatable, Sendable {
    let folderID: String
    let folderName: String
    let groupCount: Int

    var id: String { "\(folderID)|\(groupCount)" }

    var title: String {
        groupCount == 1 ? "1 Possible Duplicate" : "\(groupCount) Possible Duplicates"
    }

    var message: String {
        "Some tracks in “\(folderName)” are already in your library."
    }
}

struct DuplicateLocalFile: Sendable {
    let url: URL?
    let size: Int64
}

@MainActor
final class LibraryDuplicates: ObservableObject {
    static let shared = LibraryDuplicates()
    static let storageKey = "red.forbes.sounding.synced.libraryDuplicates.v1"

    private static let likesCeiling = 25_000
    private nonisolated static let fingerprintChunk = 262_144
    private nonisolated static let losslessExtensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "alac"]

    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var decisions = DuplicateDecisions()
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published var importNotice: DuplicateImportNotice?

    private var allGroups: [DuplicateGroup] = []
    private var tracksByID: [String: Track] = [:]
    private var pendingImports: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var checkTask: Task<Void, Never>?
    private var started = false
    private let defaults: UserDefaults
    private var storedData: Data?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .sounding) {
        self.defaults = defaults
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var count: Int { groups.count }

    var hiddenIDs: Set<String> { decisions.hidden }

    var hiddenTracks: [Track] {
        decisions.hidden.compactMap { tracksByID[$0] }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func track(_ id: String) -> Track? { tracksByID[id] }

    func isHidden(_ track: Track) -> Bool { decisions.hidden.contains(track.id) }

    func visible(_ tracks: [Track]) -> [Track] {
        let hidden = decisions.hidden
        guard !hidden.isEmpty else { return tracks }
        return tracks.filter { !hidden.contains($0.id) }
    }

    func keep(_ id: String, in group: DuplicateGroup) {
        hide(group.memberIDs.subtracting([id]))
    }

    func hideOthers(in group: DuplicateGroup) {
        keep(group.keeperID, in: group)
    }

    func notDuplicates(_ group: DuplicateGroup) {
        var next = decisions
        next.dismissed.removeAll { $0.isSubset(of: group.memberIDs) }
        next.dismissed.append(group.memberIDs)
        save(next)
    }

    func hide(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var next = decisions
        next.hidden.formUnion(ids)
        save(next)
    }

    func unhide(_ id: String) {
        var next = decisions
        next.hidden.remove(id)
        save(next)
    }

    func unlike(_ track: Track) async -> Bool {
        guard !track.isLocal else { return false }
        do {
            try await SoundCloudAPI.shared.unlikeTrack(track)
        } catch {
            return false
        }
        hide([track.id])
        return true
    }

    func start() {
        guard !started else { return }
        started = true
        #if os(tvOS)
        RemoteLocalMusic.shared.$tracksByDevice
            .map { $0.values.reduce(0) { $0 + $1.count } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck(after: .seconds(2)) }
            .store(in: &cancellables)
        #else
        LocalMusicLibrary.shared.$tracksByFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck(after: .seconds(2)) }
            .store(in: &cancellables)
        #endif
        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard LibrarySyncEngine.shared.lastChanged.contains(.likes) else { return }
                self?.scheduleCheck(after: .seconds(5))
            }
            .store(in: &cancellables)
        LibraryIdentity.shared.$index
            .map(\.generation)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck(after: .seconds(3)) }
            .store(in: &cancellables)
    }

    func checkNow() {
        start()
        scheduleCheck(after: .zero)
    }

    func watchImport(folderID: String) {
        start()
        pendingImports.insert(folderID)
    }

    private func scheduleCheck(after delay: Duration) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.check()
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        let readyImports = pendingImports.filter { importFinished($0) }

        let local = localTracks()
        var tracks = local
        if SoundCloudCredentialSource.shared.showsSoundCloudLibrary {
            let likeCount = await LibraryDB.count(.likes)
            if likeCount > 0 {
                let likes = await LibraryDB.tracks(.likes, offset: 0, limit: min(likeCount, Self.likesCeiling)).tracks
                let localIDs = Set(local.map(\.id))
                let identity = LibraryIdentity.shared.index
                tracks += likes.filter { liked in
                    !localIDs.contains(liked.id) && identity.localCopy(of: liked).map { localIDs.contains($0.id) } != true
                }
            }
        }
        guard !Task.isCancelled else { return }

        let analysis = await AnalysisSummaryStore.summaries(for: tracks)
        guard !Task.isCancelled else { return }
        let downloaded = Set(DownloadManager.shared.entries.values.filter(\.isDownloaded).map(\.track.id))
        let files = localFiles()
        let snapshot = tracks

        let found = await Task.detached(priority: .utility) {
            let candidates = Self.candidates(tracks: snapshot, analysis: analysis, downloaded: downloaded, files: files)
            return DuplicateDetector.groups(in: candidates)
        }.value
        guard !Task.isCancelled else { return }

        let groupedIDs = Set(found.flatMap(\.memberIDs))
        var cued: [String: [CuePoint]] = [:]
        if !groupedIDs.isEmpty { cued = await CueStore.shared.cues(forTracks: Array(groupedIDs)) }
        let cuedIDs = Set(cued.filter { !$0.value.isEmpty }.keys)
        guard !Task.isCancelled else { return }

        var keptTracks: [String: Track] = [:]
        let wanted = groupedIDs.union(decisions.hidden)
        for track in tracks where wanted.contains(track.id) { keptTracks[track.id] = track }
        tracksByID = keptTracks
        allGroups = cuedIDs.isEmpty ? found : found.map { $0.markingCues(cuedIDs) }
        hasChecked = true
        publish()
        noteImports(readyImports)
    }

    private func publish() {
        let hidden = decisions.hidden
        let next = allGroups.compactMap { group -> DuplicateGroup? in
            guard let visible = group.restricted(to: group.memberIDs.subtracting(hidden)) else { return nil }
            return decisions.isDismissed(visible.memberIDs) ? nil : visible
        }
        if next != groups { groups = next }
    }

    private func importFinished(_ folderID: String) -> Bool {
        #if os(tvOS)
        return true
        #else
        let library = LocalMusicLibrary.shared
        return !library.isScanning(folderID) && library.folder(id: folderID)?.lastScannedAt != nil
        #endif
    }

    private func noteImports(_ folderIDs: Set<String>) {
        #if !os(tvOS)
        for folderID in folderIDs {
            pendingImports.remove(folderID)
            guard let folder = LocalMusicLibrary.shared.folder(id: folderID) else { continue }
            let hits = groups.filter { group in
                let inFolder = group.members.map { tracksByID[$0.id]?.localFile?.folderID == folderID }
                return inFolder.contains(true) && inFolder.contains(false)
            }
            if !hits.isEmpty {
                importNotice = DuplicateImportNotice(folderID: folderID, folderName: folder.name, groupCount: hits.count)
            }
        }
        #endif
    }

    private func localTracks() -> [Track] {
        #if os(tvOS)
        return RemoteLocalMusic.shared.allTracks
        #else
        return LocalMusicLibrary.shared.allTracks
        #endif
    }

    private func localFiles() -> [String: DuplicateLocalFile] {
        #if os(tvOS)
        return [:]
        #else
        var files: [String: DuplicateLocalFile] = [:]
        for folder in LocalMusicLibrary.shared.folders {
            let root = LocalMusicAccess.shared.root(for: folder.id)
            for entry in folder.files {
                let id = LocalMusicScanner.trackID(folderID: folder.id, relativePath: entry.relativePath)
                files[id] = DuplicateLocalFile(
                    url: entry.isDownloaded ? root?.appendingPathComponent(entry.relativePath) : nil,
                    size: entry.fileSize
                )
            }
        }
        return files
        #endif
    }

    nonisolated static func candidates(
        tracks: [Track],
        analysis: [String: AnalysisFeatureSummary],
        downloaded: Set<String>,
        files: [String: DuplicateLocalFile]
    ) -> [DuplicateCandidate] {
        var sizeCounts: [Int64: Int] = [:]
        for track in tracks where track.isLocal {
            if let size = files[track.id]?.size, size > 0 { sizeCounts[size, default: 0] += 1 }
        }

        return tracks.map { track in
            let summary = analysis[track.id]
            var alternates: [String] = []
            if let publisherArtist = track.publisher?.artist, !publisherArtist.isEmpty { alternates.append(publisherArtist) }
            if !track.isLocal, !track.user.username.isEmpty { alternates.append(track.user.username) }

            var candidate: DuplicateCandidate
            if let file = track.localFile {
                let ext = (file.relativePath as NSString).pathExtension.lowercased()
                let facts = files[track.id]
                var bitrate = 0
                if let size = facts?.size, size > 0, track.duration > 0 {
                    bitrate = Int(Double(size) * 8 / track.duration / 1000)
                }
                candidate = DuplicateCandidate(
                    id: track.id,
                    title: track.title,
                    artist: track.user.displayName,
                    alternateArtists: alternates,
                    duration: track.duration,
                    source: losslessExtensions.contains(ext) ? .localLossless : .localFile,
                    bitrate: bitrate,
                    format: ext.isEmpty ? nil : ext.uppercased()
                )
                if let url = facts?.url {
                    candidate.filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
                    if let size = facts?.size, size > 0, (sizeCounts[size] ?? 0) > 1 {
                        candidate.contentHash = fingerprint(url, size: size)
                    }
                }
            } else {
                let source: DuplicateCandidate.Source
                if downloaded.contains(track.id) {
                    source = .downloaded
                } else if track.isPreviewOnly {
                    source = .preview
                } else {
                    source = .stream
                }
                candidate = DuplicateCandidate(
                    id: track.id,
                    title: track.title,
                    artist: track.user.displayName,
                    alternateArtists: alternates,
                    duration: track.duration,
                    source: source,
                    bitrate: track.bestDecodableTranscoding?.bitrate ?? 0
                )
            }
            candidate.bpm = summary?.bpm
            candidate.key = summary?.key
            return candidate
        }
    }

    nonisolated static func fingerprint(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: fingerprintChunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(fingerprintChunk * 2) {
            do {
                try handle.seek(toOffset: UInt64(size) - UInt64(fingerprintChunk))
                if let tail = try handle.read(upToCount: fingerprintChunk) { hasher.update(data: tail) }
            } catch {
                return nil
            }
        }
        var length = size.littleEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func reload() {
        let data = defaults.data(forKey: Self.storageKey)
        guard data != storedData else { return }
        storedData = data
        let decoded = data.flatMap { try? JSONDecoder().decode(DuplicateDecisions.self, from: $0) } ?? DuplicateDecisions()
        guard decoded != decisions else { return }
        decisions = decoded
        publish()
    }

    private func save(_ next: DuplicateDecisions) {
        decisions = next
        publish()
        guard let data = try? JSONEncoder().encode(next) else { return }
        storedData = data
        defaults.set(data, forKey: Self.storageKey)
    }
}
