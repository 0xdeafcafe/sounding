import Combine
import Foundation
import WatchConnectivity
import os

@MainActor
final class WatchOfflineStore: ObservableObject {
    static let shared = WatchOfflineStore()

    private struct Index: Codable {
        var tracks: [WatchOfflineTrack]
        var manifest: WatchOfflineManifest?
        var confirmedAtMillis: Int64?
    }

    @Published private(set) var tracks: [String: WatchOfflineTrack] = [:]
    @Published private(set) var manifest: WatchOfflineManifest?
    @Published private(set) var confirmedAt: Date?

    nonisolated static var rootDirectory: URL {
        (FileManager.default.soundingDirectory(.applicationSupportDirectory) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("WatchOffline", isDirectory: true)
    }

    nonisolated static var audioDirectory: URL {
        rootDirectory.appendingPathComponent("Audio", isDirectory: true)
    }

    private nonisolated static var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            tracks = Dictionary(index.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            manifest = index.manifest
            confirmedAt = index.confirmedAtMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        }
        dropMissingFiles()
        enforceExpiry()
    }

    var isEmpty: Bool { tracks.isEmpty }

    var usedBytes: Int64 { tracks.values.reduce(Int64(0)) { $0 + $1.bytes } }

    var budgetBytes: Int64 { manifest?.budgetBytes ?? WatchStorageBudget.standard.bytes }

    var collections: [WatchOfflineCollection] {
        (manifest?.collections ?? []).compactMap { collection in
            let present = collection.trackIDs.filter { tracks[$0] != nil }
            guard !present.isEmpty else { return nil }
            var copy = collection
            copy.trackIDs = present
            return copy
        }
    }

    var allTracks: [WatchOfflineTrack] {
        tracks.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func tracks(in collection: WatchOfflineCollection) -> [WatchOfflineTrack] {
        collection.trackIDs.compactMap { tracks[$0] }
    }

    func fileURL(for track: WatchOfflineTrack) -> URL? {
        guard isPlayable(track) else { return nil }
        let url = Self.audioDirectory.appendingPathComponent(track.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isPlayable(_ track: WatchOfflineTrack) -> Bool {
        guard tracks[track.id] != nil else { return false }
        return track.source == .file || !WatchOfflinePolicy.isExpired(confirmedAt: confirmedAt)
    }

    nonisolated static func adopt(_ file: WCSessionFile) -> WatchOfflineTrack? {
        guard WatchLinkCodec.kind(of: file.metadata ?? [:]) == .offlineFile,
              let track = WatchLinkCodec.payload(WatchOfflineTrack.self, from: file.metadata ?? [:]),
              WatchOfflinePolicy.isPlayable(fileExtension: track.fileExtension) else { return nil }
        let manager = FileManager.default
        let destination = audioDirectory.appendingPathComponent(track.fileName)
        do {
            try manager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            var root = rootDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: file.fileURL, to: destination)
        } catch {
            return nil
        }
        var adopted = track
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            adopted.bytes = Int64(size)
        }
        return adopted
    }

    func didAdopt(_ track: WatchOfflineTrack) {
        let planned = manifest?.plannedIDs ?? []
        let isWanted = manifest.map { $0.keeps(track, planned: planned) } ?? true
        let projected = usedBytes - (tracks[track.id]?.bytes ?? 0) + track.bytes
        guard isWanted, projected <= budgetBytes else {
            deleteFile(track)
            publishInventory()
            return
        }
        tracks[track.id] = track
        save()
        publishInventory()
    }

    func apply(_ next: WatchOfflineManifest) {
        let refreshesConfirmation = next.isSoundCloudAuthoritative
            && (confirmedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true)
        guard next != manifest || refreshesConfirmation else { return }
        manifest = next
        if next.isSoundCloudAuthoritative { confirmedAt = Date() }
        let planned = next.plannedIDs
        for track in Array(tracks.values) where !next.keeps(track, planned: planned) {
            deleteFile(track)
            tracks[track.id] = nil
        }
        for planned in next.tracks where tracks[planned.id] != nil {
            var updated = planned
            updated.bytes = tracks[planned.id]?.bytes ?? planned.bytes
            tracks[planned.id] = updated
        }
        save()
        publishInventory()
    }

    func remove(_ track: WatchOfflineTrack) {
        deleteFile(track)
        tracks[track.id] = nil
        save()
        publishInventory()
        WatchLinkClient.shared.sendReliably(WatchCommand(kind: .offlineRemove, trackId: track.id))
    }

    func remove(_ collection: WatchOfflineCollection) {
        let others = Set((manifest?.collections ?? []).filter { $0.id != collection.id }.flatMap(\.trackIDs))
        for id in collection.trackIDs where !others.contains(id) {
            if let track = tracks[id] { deleteFile(track) }
            tracks[id] = nil
        }
        if var updated = manifest {
            updated.collections.removeAll { $0.id == collection.id }
            manifest = updated
        }
        save()
        publishInventory()
        WatchLinkClient.shared.sendReliably(WatchCommand(kind: .offlineRemove, collectionId: collection.id))
    }

    func enforceExpiry() {
        guard WatchOfflinePolicy.isExpired(confirmedAt: confirmedAt) else { return }
        let expired = tracks.values.filter { $0.source == .soundCloud }
        guard !expired.isEmpty else { return }
        for track in expired {
            deleteFile(track)
            tracks[track.id] = nil
        }
        save()
        publishInventory()
    }

    func publishInventory() {
        WatchLinkClient.shared.publishOfflineInventory(
            WatchOfflineInventory(
                trackIDs: tracks.keys.sorted(),
                usedBytes: usedBytes,
                updatedAtMillis: WatchLinkCodec.nowMillis()
            )
        )
    }

    private func dropMissingFiles() {
        let manager = FileManager.default
        let missing = tracks.values.filter {
            !manager.fileExists(atPath: Self.audioDirectory.appendingPathComponent($0.fileName).path)
        }
        guard !missing.isEmpty else { return }
        for track in missing { tracks[track.id] = nil }
        save()
    }

    private func deleteFile(_ track: WatchOfflineTrack) {
        try? FileManager.default.removeItem(at: Self.audioDirectory.appendingPathComponent(track.fileName))
    }

    private func save() {
        let index = Index(
            tracks: Array(tracks.values),
            manifest: manifest,
            confirmedAtMillis: confirmedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
        guard let data = try? JSONEncoder().encode(index) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            Log.link.error("[WatchOffline] index save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
