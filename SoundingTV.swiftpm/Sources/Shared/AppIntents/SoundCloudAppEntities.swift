import AppIntents
import Foundation

extension Track: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Track")
    }

    static let defaultQuery = TrackEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(user.displayName)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

struct TrackEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Track.ID]) async throws -> [Track] {
        guard !identifiers.isEmpty else { return [] }
        return try await SoundCloudAPI.shared.getTracks(ids: identifiers)
    }

    @MainActor
    func entities(matching string: String) async throws -> [Track] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await SoundCloudAPI.shared.searchTracks(query: query).collection
    }
}

extension Playlist: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist")
    }

    static let defaultQuery = PlaylistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(user.displayName)",
            image: artworkURL.map { .init(url: $0) }
        )
    }
}

struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Playlist.ID]) async throws -> [Playlist] {
        var results: [Playlist] = []
        for id in identifiers {
            if let playlist = try? await SoundCloudAPI.shared.getPlaylist(id: id) {
                results.append(playlist)
            }
        }
        return results
    }

    @MainActor
    func entities(matching string: String) async throws -> [Playlist] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await SoundCloudAPI.shared.searchPlaylists(query: query).collection
    }
}

extension User: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Artist")
    }

    static let defaultQuery = ArtistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        let handle: LocalizedStringResource? = username == displayName ? nil : "@\(username)"
        return DisplayRepresentation(
            title: "\(displayName)",
            subtitle: handle,
            image: avatarURL.map { .init(url: $0) }
        )
    }
}

struct ArtistEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [User.ID]) async throws -> [User] {
        var results: [User] = []
        for id in identifiers {
            if let user = try? await SoundCloudAPI.shared.getUser(id: id) {
                results.append(user)
            }
        }
        return results
    }

    @MainActor
    func entities(matching string: String) async throws -> [User] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await SoundCloudAPI.shared.searchUsers(query: query).collection
    }
}
