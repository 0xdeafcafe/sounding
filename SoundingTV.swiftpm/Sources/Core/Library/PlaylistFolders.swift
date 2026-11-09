import Foundation
import Combine

enum PlaylistFolderChild: Hashable, Codable, Sendable {
    case playlist(String)
    case folder(String)

    var key: String {
        switch self {
        case .playlist(let id): "playlist:\(id)"
        case .folder(let id): "folder:\(id)"
        }
    }

    init?(key: String) {
        if key.hasPrefix("playlist:") {
            self = .playlist(String(key.dropFirst("playlist:".count)))
        } else if key.hasPrefix("folder:") {
            self = .folder(String(key.dropFirst("folder:".count)))
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let child = PlaylistFolderChild(key: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
        }
        self = child
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

struct PlaylistFolder: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var parentID: String?
    var childIDs: [PlaylistFolderChild]
    let createdAt: Date
    var modifiedAt: Date
    var isDeleted: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        parentID: String? = nil,
        childIDs: [PlaylistFolderChild] = [],
        createdAt: Date,
        modifiedAt: Date? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.childIDs = childIDs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.isDeleted = isDeleted
    }
}

struct PlaylistFolderRoute: Hashable, Sendable {
    let folderID: String
}

enum PlaylistFolderEntry: Identifiable, Hashable {
    case folder(PlaylistFolder)
    case playlist(Playlist)

    var id: String { child.key }

    var child: PlaylistFolderChild {
        switch self {
        case .folder(let folder): .folder(folder.id)
        case .playlist(let playlist): .playlist(playlist.id)
        }
    }
}

struct PlaylistFolderTree: Equatable {
    private(set) var folders: [String: PlaylistFolder] = [:]
    private(set) var parents: [String: String] = [:]
    private(set) var owners: [String: String] = [:]
    private(set) var children: [String: [PlaylistFolderChild]] = [:]
    private(set) var roots: [String] = []

    init(records: [String: PlaylistFolder] = [:]) {
        let live = records.filter { !$0.value.isDeleted }
        folders = live

        for id in live.keys {
            guard let parent = Self.effectiveParent(of: id, in: live) else { continue }
            parents[id] = parent
        }

        let byAge = live.values.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt < $1.modifiedAt
        }
        for folder in byAge {
            for case .playlist(let playlistID) in folder.childIDs {
                owners[playlistID] = folder.id
            }
        }

        for folder in live.values {
            var seen = Set<PlaylistFolderChild>()
            var ordered: [PlaylistFolderChild] = []
            for child in folder.childIDs where !seen.contains(child) {
                switch child {
                case .playlist(let id) where owners[id] == folder.id:
                    ordered.append(child)
                    seen.insert(child)
                case .folder(let id) where parents[id] == folder.id:
                    ordered.append(child)
                    seen.insert(child)
                default:
                    continue
                }
            }
            let unlisted = live.values
                .filter { parents[$0.id] == folder.id && !seen.contains(.folder($0.id)) }
                .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            ordered += unlisted.map { .folder($0.id) }
            children[folder.id] = ordered
        }

        roots = live.values
            .filter { parents[$0.id] == nil }
            .sorted(by: Self.byName)
            .map(\.id)
    }

    static func byName(_ lhs: PlaylistFolder, _ rhs: PlaylistFolder) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    private static func effectiveParent(of id: String, in live: [String: PlaylistFolder]) -> String? {
        guard let parent = live[id]?.parentID, live[parent] != nil else { return nil }
        var visited: Set<String> = [id]
        var cursor: String? = parent
        while let current = cursor {
            if visited.contains(current) { return nil }
            visited.insert(current)
            guard let next = live[current]?.parentID, live[next] != nil else { break }
            cursor = next
        }
        return parent
    }

    func ancestors(of id: String) -> [String] {
        var result: [String] = []
        var cursor = parents[id]
        while let current = cursor, !result.contains(current) {
            result.append(current)
            cursor = parents[current]
        }
        return result
    }

    func isDescendant(_ id: String, of ancestor: String) -> Bool {
        ancestors(of: id).contains(ancestor)
    }
}

@MainActor
final class PlaylistFolderStore: ObservableObject {
    static let shared = PlaylistFolderStore()

    @Published private(set) var tree = PlaylistFolderTree()
    @Published private(set) var playlists: [String: Playlist] = [:]
    @Published private(set) var hasLoadedPlaylists = false

    private var records: [String: PlaylistFolder] = [:]
    private var registered: [String: Playlist] = [:]
    private let settings: SettingsStore
    private var observations: [AnyCancellable] = []
    private var reloadTask: Task<Void, Never>?

    private static let pruneGrace: TimeInterval = 24 * 60 * 60

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        adopt(settings.playlistFolders)
        observations = [
            settings.$playlistFolders
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.adopt(value) },
            LibrarySyncEngine.shared.$revision
                .removeDuplicates()
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.reloadPlaylists() },
        ]
        reloadPlaylists()
    }

    var canEdit: Bool { settings.hasActiveAccount }

    var rootFolders: [PlaylistFolder] {
        tree.roots.compactMap { tree.folders[$0] }
    }

    var allFolders: [PlaylistFolder] {
        tree.folders.values.sorted(by: PlaylistFolderTree.byName)
    }

    var isEmpty: Bool { tree.folders.isEmpty }

    func folder(_ id: String) -> PlaylistFolder? {
        tree.folders[id]
    }

    func isFolderDeleted(_ id: String) -> Bool {
        records[id]?.isDeleted == true
    }

    func playlist(_ id: String) -> Playlist? {
        playlists[id]
    }

    func parentID(of folderID: String) -> String? {
        tree.parents[folderID]
    }

    func folderID(containing playlistID: String) -> String? {
        tree.owners[playlistID].flatMap { tree.folders[$0] == nil ? nil : $0 }
    }

    func isFoldered(_ playlistID: String) -> Bool {
        folderID(containing: playlistID) != nil
    }

    func canFolder(_ playlist: Playlist) -> Bool {
        !playlist.isAlbum && playlists[playlist.id] != nil
    }

    func entries(in folderID: String) -> [PlaylistFolderEntry] {
        (tree.children[folderID] ?? []).compactMap(entry(for:))
    }

    func subfolders(of folderID: String?) -> [PlaylistFolder] {
        guard let folderID else { return rootFolders }
        return (tree.children[folderID] ?? []).compactMap {
            if case .folder(let id) = $0 { return tree.folders[id] }
            return nil
        }
    }

    func matchingFolders(_ needle: String) -> [PlaylistFolder] {
        guard !needle.isEmpty else { return rootFolders }
        return allFolders.filter { $0.name.localizedStandardContains(needle) }
    }

    func path(to folderID: String) -> [PlaylistFolder] {
        (tree.ancestors(of: folderID).reversed() + [folderID]).compactMap { tree.folders[$0] }
    }

    func summary(for folderID: String) -> String {
        let items = entries(in: folderID)
        let folders = items.filter { if case .folder = $0 { true } else { false } }.count
        let playlists = items.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if playlists > 0 || folders == 0 { parts.append(playlists == 1 ? "1 playlist" : "\(playlists) playlists") }
        return parts.joined(separator: " \u{00B7} ")
    }

    func canMove(folder folderID: String, into parentID: String?) -> Bool {
        guard tree.folders[folderID] != nil else { return false }
        guard let parentID else { return true }
        guard tree.folders[parentID] != nil, parentID != folderID else { return false }
        return !tree.isDescendant(parentID, of: folderID)
    }

    private func entry(for child: PlaylistFolderChild) -> PlaylistFolderEntry? {
        switch child {
        case .folder(let id):
            return tree.folders[id].map(PlaylistFolderEntry.folder)
        case .playlist(let id):
            return playlists[id].map(PlaylistFolderEntry.playlist)
        }
    }

    @discardableResult
    func createFolder(named name: String, in parentID: String? = nil, containing playlistIDs: [String] = []) -> PlaylistFolder? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit else { return nil }
        let now = stamp()
        let parent = parentID.flatMap { tree.folders[$0] }
        var folder = PlaylistFolder(
            name: title.isEmpty ? "Untitled Folder" : title,
            parentID: parent?.id,
            createdAt: now
        )
        var changed: [PlaylistFolder] = []
        for playlistID in playlistIDs {
            if let owner = folderID(containing: playlistID), var source = records[owner] {
                source.childIDs.removeAll { $0 == .playlist(playlistID) }
                source.modifiedAt = now
                changed.append(source)
            }
            folder.childIDs.append(.playlist(playlistID))
        }
        if var parent {
            parent.childIDs.append(.folder(folder.id))
            parent.modifiedAt = now
            changed.append(parent)
        }
        changed.append(folder)
        commit(changed)
        return folder
    }

    func rename(_ folderID: String, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var folder = tree.folders[folderID], folder.name != title else { return }
        folder.name = title
        folder.modifiedAt = stamp()
        commit([folder])
    }

    func delete(_ folderID: String) {
        guard var folder = tree.folders[folderID] else { return }
        let now = stamp()
        let parentID = tree.parents[folderID]
        let released = tree.children[folderID] ?? []
        var changed: [String: PlaylistFolder] = [:]

        for case .folder(let childID) in released {
            guard var child = tree.folders[childID] else { continue }
            child.parentID = parentID
            child.modifiedAt = now
            changed[childID] = child
        }

        if let parentID, var parent = tree.folders[parentID] {
            var children = parent.childIDs
            if let index = children.firstIndex(of: .folder(folderID)) {
                children.remove(at: index)
                children.insert(contentsOf: released, at: index)
            } else {
                children += released
            }
            parent.childIDs = children
            parent.modifiedAt = now
            changed[parentID] = parent
        }

        folder.isDeleted = true
        folder.childIDs = []
        folder.modifiedAt = now
        changed[folderID] = folder
        commit(Array(changed.values))
    }

    func movePlaylist(_ playlistID: String, to folderID: String?, before target: PlaylistFolderChild? = nil) {
        guard canEdit else { return }
        let now = stamp()
        let current = self.folderID(containing: playlistID)
        var changed: [String: PlaylistFolder] = [:]
        let child = PlaylistFolderChild.playlist(playlistID)

        if let current, current != folderID, var source = tree.folders[current] {
            source.childIDs.removeAll { $0 == child }
            source.modifiedAt = now
            changed[current] = source
        }

        if let folderID, var destination = tree.folders[folderID] {
            destination.childIDs.removeAll { $0 == child }
            destination.childIDs.insert(child, at: insertionIndex(in: destination.childIDs, before: target))
            destination.modifiedAt = now
            changed[folderID] = destination
        }
        commit(Array(changed.values))
    }

    @discardableResult
    func moveFolder(_ folderID: String, to parentID: String?, before target: PlaylistFolderChild? = nil) -> Bool {
        guard canMove(folder: folderID, into: parentID), var folder = tree.folders[folderID] else { return false }
        let now = stamp()
        let current = tree.parents[folderID]
        var changed: [String: PlaylistFolder] = [:]
        let child = PlaylistFolderChild.folder(folderID)

        if let current, current != parentID, var source = tree.folders[current] {
            source.childIDs.removeAll { $0 == child }
            source.modifiedAt = now
            changed[current] = source
        }

        if let parentID, var destination = tree.folders[parentID] {
            destination.childIDs.removeAll { $0 == child }
            destination.childIDs.insert(child, at: insertionIndex(in: destination.childIDs, before: target))
            destination.modifiedAt = now
            changed[parentID] = destination
        }

        if folder.parentID != parentID {
            folder.parentID = parentID
            folder.modifiedAt = now
            changed[folderID] = folder
        }
        commit(Array(changed.values))
        return true
    }

    func move(_ child: PlaylistFolderChild, to folderID: String?, before target: PlaylistFolderChild? = nil) {
        switch child {
        case .playlist(let id): movePlaylist(id, to: folderID, before: target)
        case .folder(let id): moveFolder(id, to: folderID, before: target)
        }
    }

    func reorder(in folderID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var folder = tree.folders[folderID] else { return }
        var visible = entries(in: folderID).map(\.child)
        visible.move(fromOffsets: source, toOffset: destination)
        let hidden = folder.childIDs.filter { !visible.contains($0) }
        let next = visible + hidden
        guard next != folder.childIDs else { return }
        folder.childIDs = next
        folder.modifiedAt = stamp()
        commit([folder])
    }

    func register(_ playlist: Playlist) {
        guard playlists[playlist.id] == nil else { return }
        registered[playlist.id] = playlist
        playlists[playlist.id] = playlist
    }

    func forget(_ playlistID: String) {
        registered[playlistID] = nil
        playlists[playlistID] = nil
        let child = PlaylistFolderChild.playlist(playlistID)
        let now = stamp()
        let changed: [PlaylistFolder] = tree.folders.values.compactMap { folder in
            guard folder.childIDs.contains(child) else { return nil }
            var next = folder
            next.childIDs.removeAll { $0 == child }
            next.modifiedAt = now
            return next
        }
        commit(changed)
    }

    private func insertionIndex(in children: [PlaylistFolderChild], before target: PlaylistFolderChild?) -> Int {
        guard let target, let index = children.firstIndex(of: target) else { return children.endIndex }
        return index
    }

    private func stamp() -> Date {
        let newest = records.values.map(\.modifiedAt).max() ?? .distantPast
        let now = Date()
        return now > newest ? now : newest.addingTimeInterval(0.001)
    }

    private func commit(_ folders: [PlaylistFolder]) {
        guard canEdit, !folders.isEmpty else { return }
        var next = records
        for folder in folders { next[folder.id] = folder }
        records = next
        tree = PlaylistFolderTree(records: next)
        let encoder = JSONEncoder()
        var stored = settings.playlistFolders
        for folder in folders {
            guard let payload = try? encoder.encode(folder) else { continue }
            stored[folder.id] = SyncedRecord(
                modifiedAtMillis: Int64(folder.modifiedAt.timeIntervalSince1970 * 1000),
                writerId: settings.writerIdForSync,
                payload: payload
            )
        }
        settings.setPlaylistFolders(stored)
    }

    private func adopt(_ stored: [String: SyncedRecord]) {
        let decoder = JSONDecoder()
        var next: [String: PlaylistFolder] = [:]
        for (id, record) in stored {
            guard let folder = try? decoder.decode(PlaylistFolder.self, from: record.payload), folder.id == id else { continue }
            next[id] = folder
        }
        guard next != records else { return }
        records = next
        let resolved = PlaylistFolderTree(records: next)
        if resolved != tree { tree = resolved }
    }

    func reloadPlaylists() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let total = await LibraryDB.playlistCount()
            let page = await LibraryDB.allPlaylists(offset: 0, limit: max(total, 1))
            guard !Task.isCancelled, let self else { return }
            var index: [String: Playlist] = [:]
            for playlist in page.playlists where index[playlist.id] == nil {
                index[playlist.id] = playlist
            }
            registered = registered.filter { index[$0.key] == nil }
            for (id, playlist) in registered { index[id] = playlist }
            playlists = index
            hasLoadedPlaylists = true
            pruneMissingPlaylists()
        }
    }

    private func pruneMissingPlaylists() {
        let engine = LibrarySyncEngine.shared
        guard canEdit, !playlists.isEmpty,
              !engine.isAwaitingFirstSync(.ownPlaylists),
              !engine.isAwaitingFirstSync(.likedPlaylists) else { return }
        let cutoff = Date().addingTimeInterval(-Self.pruneGrace)
        var changed: [PlaylistFolder] = []
        for folder in tree.folders.values where folder.modifiedAt < cutoff {
            let kept = folder.childIDs.filter {
                if case .playlist(let id) = $0 { return playlists[id] != nil }
                return true
            }
            guard kept != folder.childIDs else { continue }
            var next = folder
            next.childIDs = kept
            next.modifiedAt = stamp()
            changed.append(next)
        }
        commit(changed)
    }
}
