import Foundation
import Combine

@MainActor
final class CollectionRelatedModel: ObservableObject {
    enum Part: Hashable {
        case artist
        case moreByArtist
        case similar
    }

    private struct Stamped<Value> {
        let savedAt: Date
        let value: Value

        func fresh(within lifetime: TimeInterval) -> Value? {
            Date().timeIntervalSince(savedAt) < lifetime ? value : nil
        }
    }

    private static let lifetime: TimeInterval = 15 * 60
    private static var others: [String: Stamped<[Playlist]>] = [:]
    private static var related: [String: Stamped<[Track]>] = [:]
    private static var artists: [String: Stamped<User>] = [:]
    private static var pausedUntil: Date?

    @Published private(set) var moreByArtist: [Playlist] = []
    @Published private(set) var similar: [Track] = []
    @Published private(set) var artist: User?
    @Published private(set) var finished: Set<Part> = []

    private var playlistID: String?
    private var requested: Set<Part> = []

    func hasFinished(_ part: Part) -> Bool {
        finished.contains(part)
    }

    func prepare(for playlist: Playlist) {
        guard playlistID != playlist.id else { return }
        playlistID = playlist.id
        requested = []
        finished = []
        moreByArtist = []
        similar = []
        artist = playlist.user
        if let cached = Self.others[playlist.id]?.fresh(within: Self.lifetime) {
            moreByArtist = cached
            finished.insert(.moreByArtist)
        }
        if let cached = Self.related[playlist.id]?.fresh(within: Self.lifetime) {
            similar = cached
            finished.insert(.similar)
        }
        if let cached = Self.artists[playlist.user.id]?.fresh(within: Self.lifetime) {
            artist = cached
            finished.insert(.artist)
        }
    }

    func load(_ part: Part, for playlist: Playlist, tracks: [Track]) async {
        prepare(for: playlist)
        guard !finished.contains(part), !requested.contains(part) else { return }
        requested.insert(part)
        defer {
            if playlistID == playlist.id { finished.insert(part) }
        }
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        guard !playlist.permalinkURL.isFileURL, !Self.isPaused else { return }

        switch part {
        case .artist:
            guard let user = await Self.fullUser(playlist.user) else { return }
            Self.artists[playlist.user.id] = Stamped(savedAt: Date(), value: user)
            if playlistID == playlist.id { artist = user }
        case .moreByArtist:
            guard let others = await Self.otherCollections(by: playlist) else { return }
            Self.others[playlist.id] = Stamped(savedAt: Date(), value: others)
            if playlistID == playlist.id { moreByArtist = others }
        case .similar:
            guard let seed = Self.seed(from: tracks) else { return }
            let excluded = Set(playlist.trackIDs ?? tracks.map(\.id))
            guard let found = await Self.relatedTracks(to: seed, excluding: excluded) else { return }
            Self.related[playlist.id] = Stamped(savedAt: Date(), value: found)
            if playlistID == playlist.id { similar = found }
        }
    }

    private static var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    private static func note(_ error: Error) {
        if let apiError = error as? APIError, case .rateLimited(let resetAt) = apiError {
            pausedUntil = resetAt ?? Date().addingTimeInterval(15 * 60)
        }
    }

    private static func seed(from tracks: [Track]) -> Track? {
        let remote = tracks.filter { !$0.isLocal }
        return remote.max { ($0.playbackCount ?? 0) < ($1.playbackCount ?? 0) } ?? remote.first
    }

    private static func fullUser(_ user: User) async -> User? {
        guard user.description == nil else { return user }
        do {
            return try await SoundCloudAPI.shared.getUser(id: user.id)
        } catch {
            note(error)
            return nil
        }
    }

    private static func otherCollections(by playlist: Playlist) async -> [Playlist]? {
        do {
            let page = try await SoundCloudAPI.shared.getUserPlaylists(userId: playlist.user.id, limit: 20)
            let others = page.collection.filter { $0.id != playlist.id && $0.totalTrackCount > 0 }
            guard playlist.isAlbum else { return others }
            return others.filter(\.isAlbum) + others.filter { !$0.isAlbum }
        } catch {
            note(error)
            return nil
        }
    }

    private static func relatedTracks(to seed: Track, excluding excluded: Set<String>) async -> [Track]? {
        do {
            let page = try await SoundCloudAPI.shared.getRelatedTracks(trackID: seed.id, limit: 16)
            var seen = excluded
            return page.collection.filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
        } catch {
            note(error)
            return nil
        }
    }
}
