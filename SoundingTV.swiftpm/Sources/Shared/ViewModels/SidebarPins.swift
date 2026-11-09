#if os(iOS) || os(macOS)
import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

struct SidebarPin: Codable, Hashable, Sendable {
    let target: PlaylistFolderChild
    var position: Double
    var modifiedAt: Date
    var isDeleted: Bool
}

enum SidebarPinItem: Identifiable, Hashable {
    case playlist(Playlist)
    case folder(PlaylistFolder)

    var id: String { target.key }

    var target: PlaylistFolderChild {
        switch self {
        case .playlist(let playlist): .playlist(playlist.id)
        case .folder(let folder): .folder(folder.id)
        }
    }

    var title: String {
        switch self {
        case .playlist(let playlist): playlist.title
        case .folder(let folder): folder.name
        }
    }

    var symbol: String {
        switch self {
        case .playlist: SidebarSymbol.pinnedPlaylist
        case .folder: SidebarSymbol.folder
        }
    }
}

@MainActor
final class SidebarPins: ObservableObject {
    static let shared = SidebarPins()

    @Published private(set) var pins: [PlaylistFolderChild] = []

    private var records: [String: SidebarPin] = [:]
    private var draggedPin: PlaylistFolderChild?
    private let settings: SettingsStore
    private var observations: [AnyCancellable] = []

    static var isAvailable: Bool {
        #if os(macOS)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        adopt(settings.sidebarPins)
        let center = PlaylistEditCenter.shared
        observations = [
            settings.$sidebarPins
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.adopt(value) },
            center.$deletedIDs
                .combineLatest(center.$busyIDs)
                .receive(on: RunLoop.main)
                .sink { [weak self] deleted, busy in self?.dropDeletedPlaylists(deleted.subtracting(busy)) },
            PlaylistFolderStore.shared.$tree
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.dropDeletedFolders() },
        ]
    }

    var canEdit: Bool { settings.hasActiveAccount }

    var pinnedPlaylistIDs: Set<String> {
        Set(pins.compactMap { target -> String? in
            if case .playlist(let id) = target { return id }
            return nil
        })
    }

    var pinnedFolderIDs: Set<String> {
        Set(pins.compactMap { target -> String? in
            if case .folder(let id) = target { return id }
            return nil
        })
    }

    func sidebarPlaylistIDs(in store: PlaylistFolderStore) -> Set<String> {
        var ids = pinnedPlaylistIDs
        for folderID in pinnedFolderIDs {
            for case .playlist(let id) in store.tree.children[folderID] ?? [] {
                ids.insert(id)
            }
        }
        return ids
    }

    func isPinned(_ target: PlaylistFolderChild) -> Bool {
        pins.contains(target)
    }

    func canPin(_ playlist: Playlist) -> Bool {
        canEdit && !playlist.isAlbum && PlaylistFolderStore.shared.playlist(playlist.id) != nil
            && !PlaylistEditCenter.shared.deletedIDs.contains(playlist.id)
    }

    func items(in store: PlaylistFolderStore) -> [SidebarPinItem] {
        let deleted = PlaylistEditCenter.shared.deletedIDs
        return pins.compactMap { target -> SidebarPinItem? in
            switch target {
            case .playlist(let id):
                guard !deleted.contains(id) else { return nil }
                return store.playlist(id).map(SidebarPinItem.playlist)
            case .folder(let id):
                return store.folder(id).map(SidebarPinItem.folder)
            }
        }
    }

    func pin(_ target: PlaylistFolderChild) {
        guard canEdit, !isPinned(target) else { return }
        let last = pins.last.flatMap { records[$0.key]?.position } ?? 0
        commit([SidebarPin(target: target, position: last + 1, modifiedAt: stamp(), isDeleted: false)])
    }

    func unpin(_ target: PlaylistFolderChild) {
        guard var record = records[target.key], !record.isDeleted else { return }
        record.isDeleted = true
        record.modifiedAt = stamp()
        commit([record])
    }

    func toggle(_ target: PlaylistFolderChild) {
        if isPinned(target) { unpin(target) } else { pin(target) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = pins
        next.move(fromOffsets: source, toOffset: destination)
        setOrder(next)
    }

    func move(_ target: PlaylistFolderChild, before anchor: PlaylistFolderChild?) {
        guard isPinned(target), target != anchor else { return }
        var next = pins.filter { $0 != target }
        if let anchor, let index = next.firstIndex(of: anchor) {
            next.insert(target, at: index)
        } else {
            next.append(target)
        }
        setOrder(next)
    }

    func setOrder(_ order: [PlaylistFolderChild]) {
        let known = order.filter { pins.contains($0) }
        let next = known + pins.filter { !known.contains($0) }
        guard next != pins else { return }
        let now = stamp()
        var changed: [SidebarPin] = []
        for (index, target) in next.enumerated() {
            guard var record = records[target.key] else { continue }
            let position = Double(index + 1)
            guard record.position != position else { continue }
            record.position = position
            record.modifiedAt = now
            changed.append(record)
        }
        commit(changed)
    }

    func dragPayload(_ target: PlaylistFolderChild) -> PlaylistReference {
        draggedPin = target
        return PlaylistReference(child: target)
    }

    func acceptDrop(_ children: [PlaylistFolderChild], before anchor: PlaylistFolderChild?) -> Bool {
        guard canEdit else { return false }
        var handled = false
        for child in children where child != anchor {
            if !isPinned(child) {
                if case .playlist(let id) = child, PlaylistFolderStore.shared.playlist(id) == nil { continue }
                if case .folder(let id) = child, PlaylistFolderStore.shared.folder(id) == nil { continue }
                pin(child)
            }
            move(child, before: anchor)
            handled = true
        }
        draggedPin = nil
        return handled
    }

    func acceptDragOut(_ children: [PlaylistFolderChild]) -> Bool {
        guard let dragged = draggedPin, children.contains(dragged) else { return false }
        draggedPin = nil
        unpin(dragged)
        return true
    }

    private func dropDeletedPlaylists(_ ids: Set<String>) {
        for id in ids where isPinned(.playlist(id)) {
            unpin(.playlist(id))
        }
    }

    private func dropDeletedFolders() {
        let store = PlaylistFolderStore.shared
        for id in pinnedFolderIDs where store.isFolderDeleted(id) {
            unpin(.folder(id))
        }
    }

    private func stamp() -> Date {
        let newest = records.values.map(\.modifiedAt).max() ?? .distantPast
        let now = Date()
        return now > newest ? now : newest.addingTimeInterval(0.001)
    }

    private func commit(_ changed: [SidebarPin]) {
        guard canEdit, !changed.isEmpty else { return }
        var next = records
        for pin in changed { next[pin.target.key] = pin }
        apply(next)
        let encoder = JSONEncoder()
        var stored = settings.sidebarPins
        for pin in changed {
            guard let payload = try? encoder.encode(pin) else { continue }
            stored[pin.target.key] = SyncedRecord(
                modifiedAtMillis: Int64(pin.modifiedAt.timeIntervalSince1970 * 1000),
                writerId: settings.writerIdForSync,
                payload: payload
            )
        }
        settings.setSidebarPins(stored)
    }

    private func adopt(_ stored: [String: SyncedRecord]) {
        let decoder = JSONDecoder()
        var next: [String: SidebarPin] = [:]
        for (key, record) in stored {
            guard let pin = try? decoder.decode(SidebarPin.self, from: record.payload), pin.target.key == key else { continue }
            next[key] = pin
        }
        guard next != records else { return }
        apply(next)
    }

    private func apply(_ next: [String: SidebarPin]) {
        records = next
        let ordered = next.values
            .filter { !$0.isDeleted }
            .sorted { $0.position == $1.position ? $0.target.key < $1.target.key : $0.position < $1.position }
            .map(\.target)
        if ordered != pins { pins = ordered }
    }
}

struct SidebarPinButton: View {
    let target: PlaylistFolderChild
    var playlist: Playlist?

    @ObservedObject private var pins = SidebarPins.shared
    @ObservedObject private var store = PlaylistFolderStore.shared

    init(playlist: Playlist) {
        self.target = .playlist(playlist.id)
        self.playlist = playlist
    }

    init(folder: PlaylistFolder) {
        self.target = .folder(folder.id)
        self.playlist = nil
    }

    var body: some View {
        if SidebarPins.isAvailable, isAvailable {
            if pins.isPinned(target) {
                Button {
                    withAnimation(.snappy) { pins.unpin(target) }
                } label: {
                    Label("Unpin from Sidebar", systemImage: "pin.slash")
                }
            } else {
                Button {
                    withAnimation(.snappy) { pins.pin(target) }
                } label: {
                    Label("Pin to Sidebar", systemImage: "pin")
                }
            }
        }
    }

    private var isAvailable: Bool {
        if pins.isPinned(target) { return true }
        if let playlist { return pins.canPin(playlist) }
        return pins.canEdit
    }
}
#endif
