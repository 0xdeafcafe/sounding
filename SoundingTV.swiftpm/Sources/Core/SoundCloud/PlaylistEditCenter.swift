import Foundation
import Combine

struct PlaylistDraft: Equatable {
    var title: String
    var description: String
    var isPrivate: Bool
    var tracks: [Track]

    init(playlist: Playlist, tracks: [Track]) {
        title = playlist.title
        description = playlist.description ?? ""
        isPrivate = playlist.isPrivate
        self.tracks = tracks
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    func differs(from playlist: Playlist, tracks original: [Track]) -> Bool {
        trimmedTitle != playlist.title
            || trimmedDescription != (playlist.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || isPrivate != playlist.isPrivate
            || tracks.map(\.id) != original.map(\.id)
    }

    static func == (lhs: PlaylistDraft, rhs: PlaylistDraft) -> Bool {
        lhs.title == rhs.title && lhs.description == rhs.description
            && lhs.isPrivate == rhs.isPrivate && lhs.tracks.map(\.id) == rhs.tracks.map(\.id)
    }
}

@MainActor
final class PlaylistEditCenter: ObservableObject {
    static let shared = PlaylistEditCenter()

    struct Snapshot: Equatable {
        let playlist: Playlist
        let tracks: [Track]?
        let revision: Int

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.revision == rhs.revision && lhs.playlist.id == rhs.playlist.id
        }
    }

    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var deletedIDs: Set<String> = []
    @Published private(set) var busyIDs: Set<String> = []

    private var revision = 0

    func isOwned(_ playlist: Playlist) -> Bool {
        playlist.isOwned(by: SoundCloudAPI.credentials?.currentUser?.id)
    }

    func current(_ playlist: Playlist) -> Playlist {
        snapshots[playlist.id]?.playlist ?? playlist
    }

    func isBusy(_ playlist: Playlist) -> Bool {
        busyIDs.contains(playlist.id)
    }

    func save(_ draft: PlaylistDraft, playlist: Playlist, tracks: [Track]) async throws {
        guard draft.differs(from: playlist, tracks: tracks) else { return }
        let reordered = draft.tracks.map(\.id) != tracks.map(\.id)
        try await commit(
            playlist: playlist,
            tracks: tracks,
            title: draft.trimmedTitle,
            description: draft.trimmedDescription,
            sharing: draft.isPrivate ? "private" : "public",
            newTracks: reordered ? draft.tracks : nil
        )
    }

    func remove(_ trackIDs: Set<String>, from playlist: Playlist, tracks: [Track]) async throws {
        let remaining = tracks.filter { !trackIDs.contains($0.id) }
        guard remaining.count != tracks.count else { return }
        try await commit(playlist: playlist, tracks: tracks, newTracks: remaining)
    }

    func reorder(_ reordered: [Track], in playlist: Playlist, tracks: [Track]) async throws {
        guard reordered.map(\.id) != tracks.map(\.id) else { return }
        try await commit(playlist: playlist, tracks: tracks, newTracks: reordered)
    }

    func setPrivate(_ isPrivate: Bool, playlist: Playlist) async throws {
        guard isPrivate != playlist.isPrivate else { return }
        try await commit(playlist: playlist, tracks: nil, sharing: isPrivate ? "private" : "public")
    }

    func delete(_ playlist: Playlist) async throws {
        guard isOwned(playlist), !busyIDs.contains(playlist.id) else { return }
        busyIDs.insert(playlist.id)
        defer { busyIDs.remove(playlist.id) }
        deletedIDs.insert(playlist.id)
        let hook = SoundCloudAPI.libraryActionHook
        let token = hook?.begin(.deletePlaylist(playlist))
        do {
            try await SoundCloudAPI.shared.deletePlaylist(id: playlist.id)
            if let token { hook?.finish(token, succeeded: true) }
            PlaylistFolderStore.shared.forget(playlist.id)
        } catch {
            if let token { hook?.finish(token, succeeded: false) }
            deletedIDs.remove(playlist.id)
            throw error
        }
    }

    private func commit(
        playlist: Playlist,
        tracks: [Track]?,
        title: String? = nil,
        description: String? = nil,
        sharing: String? = nil,
        newTracks: [Track]? = nil
    ) async throws {
        guard isOwned(playlist), !busyIDs.contains(playlist.id) else { return }
        busyIDs.insert(playlist.id)
        defer { busyIDs.remove(playlist.id) }

        var newIDs: [String]?
        if let newTracks {
            let loaded = tracks ?? []
            let manifest = try await Self.manifest(for: playlist, loaded: loaded)
            newIDs = Self.merge(manifest: manifest, loaded: loaded.map(\.id), reordered: newTracks.map(\.id))
        }
        let edited = playlist.applying(
            title: title,
            description: description,
            sharing: sharing,
            trackIDs: newIDs,
            tracks: newTracks,
            previous: tracks ?? playlist.loadedTracks
        )
        publish(edited, tracks: newTracks)
        let hook = SoundCloudAPI.libraryActionHook
        let token = hook?.begin(.updatePlaylist(edited, trackIDs: newIDs))
        do {
            _ = try await SoundCloudAPI.shared.updatePlaylist(
                id: playlist.id,
                title: title,
                description: description,
                sharing: sharing,
                trackIDs: newIDs
            )
            if let token { hook?.finish(token, succeeded: true) }
        } catch {
            if let token { hook?.finish(token, succeeded: false) }
            publish(playlist, tracks: newTracks == nil ? nil : tracks)
            throw error
        }
    }

    private func publish(_ playlist: Playlist, tracks: [Track]?) {
        revision += 1
        snapshots[playlist.id] = Snapshot(playlist: playlist, tracks: tracks, revision: revision)
    }

    private static func manifest(for playlist: Playlist, loaded: [Track]) async throws -> [String] {
        if let ids = playlist.trackIDs, !ids.isEmpty { return ids }
        if loaded.count >= playlist.totalTrackCount { return loaded.map(\.id) }
        let full = try await SoundCloudAPI.shared.getPlaylist(id: playlist.id)
        return full.trackIDs ?? full.loadedTracks.map(\.id)
    }

    static func merge(manifest: [String], loaded: [String], reordered: [String]) -> [String] {
        let shown = Set(loaded)
        var queue = reordered[...]
        var result: [String] = []
        for id in manifest {
            if shown.contains(id) {
                if let next = queue.popFirst() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        result.append(contentsOf: queue)
        return result
    }
}

enum PlaylistEditCopy {
    static let deleteTitle = "Delete Playlist?"
    static let deleteMessage = "This deletes it from SoundCloud for everyone."
}

extension Playlist {
    func applying(
        title: String?,
        description: String?,
        sharing: String?,
        trackIDs: [String]?,
        tracks newTracks: [Track]?,
        previous: [Track]
    ) -> Playlist {
        let encoder = LikesSyncEngine.makeEncoder()
        guard let data = try? encoder.encode(self),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return self }
        if let title, !title.isEmpty { json["title"] = title }
        if let description { json["description"] = description.isEmpty ? NSNull() : description }
        if let sharing { json["sharing"] = sharing }
        if let trackIDs {
            var hydrated: [String: Track] = [:]
            for track in loadedTracks + previous + (newTracks ?? []) { hydrated[track.id] = track }
            var entries: [Any] = []
            for id in trackIDs {
                if let track = hydrated[id],
                   let encoded = try? encoder.encode(track),
                   let object = try? JSONSerialization.jsonObject(with: encoded) {
                    entries.append(object)
                } else if let numeric = Int(id) {
                    entries.append(["id": numeric, "kind": "track"])
                }
            }
            json["tracks"] = entries
            json["track_count"] = trackIDs.count
            let kept = Set(trackIDs)
            let removed = previous.filter { !kept.contains($0.id) }.reduce(0) { $0 + $1.duration }
            json["duration"] = Int(max(0, duration - removed) * 1000)
        }
        guard let edited = try? JSONSerialization.data(withJSONObject: json) else { return self }
        return (try? LikesSyncEngine.makeDecoder().decode(Playlist.self, from: edited)) ?? self
    }
}
