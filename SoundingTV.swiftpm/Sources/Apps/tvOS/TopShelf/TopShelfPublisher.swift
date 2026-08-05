import Foundation
import TVServices

@MainActor
enum TopShelfPublisher {

    private enum Shelf: Int, CaseIterable {
        case recents = 0
        case likes
        case playlists
        case stream

        var kind: String {
            switch self {
            case .recents:   return TopShelfStore.recentsKind
            case .likes:     return "likes"
            case .playlists: return "playlists"
            case .stream:    return "stream"
            }
        }

        var title: String {
            switch self {
            case .recents:   return TopShelfStore.recentsTitle
            case .likes:     return "Your Likes"
            case .playlists: return "Your Playlists"
            case .stream:    return "From Your Stream"
            }
        }

        func entryId(_ rawId: String) -> String {
            self == .recents ? rawId : "\(kind):\(rawId)"
        }

        init?(kind: String) {
            switch kind {
            case TopShelfStore.recentsKind, "Recently Played", "Continue Listening":
                self = .recents
            case "likes", "Liked Tracks", "Your Likes":
                self = .likes
            case "playlists", "Your Playlists":
                self = .playlists
            case "stream", "From Your Stream":
                self = .stream
            default:
                return nil
            }
        }
    }

    private static let recentsLimit = TopShelfStore.maxEntriesPerSection

    private static let playlistRefreshInterval: TimeInterval = 30 * 60
    private static var lastPlaylistFetch: Date?
    private static var playlistFetch: Task<Void, Never>?

    private static func entry(for track: Track, shelf: Shelf, progress: Double = 0) -> TopShelfEntry {
        TopShelfEntry(
            id: shelf.entryId(track.id),
            title: track.title,
            subtitle: track.user.displayName,
            artworkURL: TopShelfStore.artwork(track.artworkURL, at: .screen1x),
            artworkURL2x: TopShelfStore.artwork(track.artworkURL, at: .screen2x),
            progress: progress,
            actionURL: TopShelfStore.playURL(trackId: track.id),
            shape: .square
        )
    }

    private static func entry(for playlist: Playlist) -> TopShelfEntry {
        let firstTrack = playlist.tracks?.first
        let count = playlist.trackCount
        return TopShelfEntry(
            id: Shelf.playlists.entryId(playlist.id),
            title: playlist.title,
            subtitle: count == 1 ? "1 track" : "\(count) tracks",
            artworkURL: TopShelfStore.artwork(playlistArtwork(playlist), at: .screen1x),
            artworkURL2x: TopShelfStore.artwork(playlistArtwork(playlist), at: .screen2x),
            actionURL: TopShelfStore.playlistURL(id: playlist.id, firstTrackId: firstTrack?.id),
            shape: .poster
        )
    }

    private static func playlistArtwork(_ playlist: Playlist) -> URL? {
        playlist.artworkURL ?? playlist.tracks?.first(where: { $0.artworkURL != nil })?.artworkURL
    }

    static func publish(stream: [Track], liked: [Track]) {
        guard AuthenticationService.shared.isAuthenticated else {
            Log.topShelf.info("publish() while signed out — clearing instead")
            clear()
            return
        }

        var sections = loadSections()

        if let index = sections.firstIndex(where: { $0.kind == Shelf.recents.kind }) {
            sections[index] = TopShelfSection(
                kind: Shelf.recents.kind,
                title: Shelf.recents.title,
                entries: stampCurrentProgress(sections[index].entries)
            )
        }

        replace(&sections, Shelf.likes, with: liked.map { entry(for: $0, shelf: .likes) })
        replace(&sections, Shelf.stream, with: stream.map { entry(for: $0, shelf: .stream) })

        write(sections)
        refreshPlaylistsIfStale()
    }

    static func notePlayed(_ track: Track, progress: Double = 0) {
        guard AuthenticationService.shared.isAuthenticated else { return }

        var sections = loadSections()
        var recents = sections.first { $0.kind == Shelf.recents.kind }?.entries ?? []

        recents.removeAll { $0.id == Shelf.recents.entryId(track.id) }
        recents.insert(entry(for: track, shelf: .recents, progress: progress), at: 0)
        recents = Array(recents.prefix(recentsLimit))

        replace(&sections, .recents, with: recents)
        write(sections)
    }

    static func clear() {
        playlistFetch?.cancel()
        playlistFetch = nil
        lastPlaylistFetch = nil
        write([], isSignedIn: false)
    }

    private static func refreshPlaylistsIfStale() {
        if let last = lastPlaylistFetch,
           Date().timeIntervalSince(last) < playlistRefreshInterval {
            return
        }
        guard playlistFetch == nil else { return }

        playlistFetch = Task { @MainActor in
            defer { playlistFetch = nil }

            guard let user = await AuthenticationService.shared.waitForCurrentUser() else { return }
            guard !Task.isCancelled else { return }

            do {
                let page = try await SoundCloudAPI.shared.getUserPlaylists(
                    userId: user.id,
                    limit: TopShelfStore.maxEntriesPerSection
                )
                guard !Task.isCancelled,
                      AuthenticationService.shared.isAuthenticated else { return }

                lastPlaylistFetch = Date()

                var sections = loadSections()
                replace(&sections, .playlists, with: page.collection.map { entry(for: $0) })
                write(sections)
            } catch {
                Log.topShelf.info("Playlist shelf refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func loadSections() -> [TopShelfSection] {
        (TopShelfStore.load()?.sections ?? []).compactMap { section in
            guard let shelf = Shelf(kind: section.kind) else {
                Log.topShelf.info("Dropping unrecognised shelf '\(section.kind, privacy: .public)'")
                return nil
            }
            guard section.kind != shelf.kind || section.title != shelf.title else { return section }
            return TopShelfSection(kind: shelf.kind, title: shelf.title, entries: section.entries)
        }
    }

    private static func replace(_ sections: inout [TopShelfSection], _ shelf: Shelf, with entries: [TopShelfEntry]) {
        let index = sections.firstIndex { $0.kind == shelf.kind }

        guard !entries.isEmpty else {
            if let index { sections.remove(at: index) }
            return
        }

        if entries.count > TopShelfStore.maxEntriesPerSection {
            Log.topShelf.info("\(shelf.title, privacy: .public): truncating \(entries.count) items to \(TopShelfStore.maxEntriesPerSection)")
        }

        let section = TopShelfSection(
            kind: shelf.kind,
            title: shelf.title,
            entries: Array(entries.prefix(TopShelfStore.maxEntriesPerSection))
        )
        if let index {
            sections[index] = section
        } else {
            sections.append(section)
        }
    }

    private static func stampCurrentProgress(_ entries: [TopShelfEntry]) -> [TopShelfEntry] {
        let player = PlayerService.shared
        guard let current = player.currentTrack else { return entries }
        let progress = player.progress
        guard progress > 0 else { return entries }

        return entries.map { entry in
            guard entry.id == Shelf.recents.entryId(current.id) else { return entry }
            var updated = entry
            updated.progress = min(max(progress, 0), 1)
            return updated
        }
    }

    private static func write(_ sections: [TopShelfSection], isSignedIn: Bool = true) {
        let ordered = sections
            .compactMap { section -> (Int, TopShelfSection)? in
                guard !section.entries.isEmpty,
                      let shelf = Shelf(kind: section.kind) else { return nil }
                return (shelf.rawValue, section)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .prefix(TopShelfStore.maxSections)

        if ordered.count < sections.count {
            Log.topShelf.info("Publishing \(ordered.count) of \(sections.count) shelves — the rest were empty, unknown, or past the cap")
        }

        let snapshot = TopShelfSnapshot(sections: Array(ordered), generatedAt: Date(), isSignedIn: isSignedIn)
        guard TopShelfStore.save(snapshot) else { return }

        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
