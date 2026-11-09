import Foundation

struct SpotlightLibraryLedger: Codable, Equatable {
    var likeIDs: Set<String> = []
    var playlistDigests: [String: String] = [:]

    static func playlistDigest(_ playlist: PlaylistEntity) -> String {
        "\(playlist.title)|\(playlist.ownerName)|\(playlist.trackCount)|\(playlist.artworkURL?.absoluteString ?? "")"
    }

    struct Plan: Equatable {
        var likesToIndex: [String]
        var likesToRemove: [String]
        var playlistsToIndex: [String]
        var playlistsToRemove: [String]
    }

    func plan(likeIDs current: [String], playlists: [PlaylistEntity]) -> Plan {
        let currentLikes = Set(current)
        let currentPlaylists = Dictionary(playlists.map { ($0.id, Self.playlistDigest($0)) }, uniquingKeysWith: { first, _ in first })
        return Plan(
            likesToIndex: current.filter { !likeIDs.contains($0) },
            likesToRemove: likeIDs.subtracting(currentLikes).sorted(),
            playlistsToIndex: playlists.map(\.id).filter { playlistDigests[$0] != currentPlaylists[$0] },
            playlistsToRemove: Set(playlistDigests.keys).subtracting(currentPlaylists.keys).sorted()
        )
    }

    private static var fileURL: URL? {
        AppDataDirectory.file("SpotlightLibraryLedger.json")
    }

    static func load() -> SpotlightLibraryLedger {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(SpotlightLibraryLedger.self, from: data) else { return .init() }
        return ledger
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func reset() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
