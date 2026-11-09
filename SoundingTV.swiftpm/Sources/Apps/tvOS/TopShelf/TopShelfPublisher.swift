import Combine
import Foundation
import TVServices
import UIKit

@MainActor
enum TopShelfPublisher {

    private enum Shelf: Int, CaseIterable {
        case recents = 0
        case likes
        case mixes

        var kind: String {
            switch self {
            case .recents: return TopShelfStore.recentsKind
            case .likes:   return TopShelfStore.likesKind
            case .mixes:   return TopShelfStore.mixesKind
            }
        }

        var title: String {
            switch self {
            case .recents: return TopShelfStore.recentsTitle
            case .likes:   return TopShelfStore.likesTitle
            case .mixes:   return TopShelfStore.mixesTitle
            }
        }

        func entryId(_ rawId: String) -> String {
            self == .recents ? rawId : "\(kind):\(rawId)"
        }

        init?(kind: String) {
            switch kind {
            case TopShelfStore.recentsKind, "Recently Played", "Continue Listening":
                self = .recents
            case TopShelfStore.likesKind, "Liked Tracks", "Your Likes":
                self = .likes
            case TopShelfStore.mixesKind, "Mixes For You":
                self = .mixes
            default:
                return nil
            }
        }
    }

    private static let reloadDelay: Duration = .milliseconds(1500)
    private static let sampleInterval: Duration = .seconds(15)

    private static var reloadTask: Task<Void, Never>?
    private static var sampler: Task<Void, Never>?
    private static var cancellables = Set<AnyCancellable>()
    private static var lastSample: (id: String, progress: Double)?

    // MARK: - Live updates

    static func start() {
        defer { scheduleReload() }
        guard cancellables.isEmpty else { return }

        let player = PlayerService.shared
        player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in Task { @MainActor in currentTrackDidChange() } }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { playing in Task { @MainActor in playbackDidToggle(playing: playing) } }
            .store(in: &cancellables)

        LikesSyncEngine.shared.$revision
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { _ in Task { @MainActor in await refreshLikes() } }
            .store(in: &cancellables)

        sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: sampleInterval)
                samplePlayback(requirePlaying: true)
            }
        }

        Task { await refreshLikes() }
    }

    static func refreshSystemContent() {
        scheduleReload()
    }

    static func flush() {
        samplePlayback(requirePlaying: false)
        publish(recents: RecentlyPlayed.shared.tracks)
        guard let pending = reloadTask else { return }
        pending.cancel()
        reloadTask = nil
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    @discardableResult
    static func refreshLikes() async -> Bool {
        guard AuthenticationService.shared.isAuthenticated else { return false }
        let tracks = await LikesSyncEngine.shared.indexedLikes(limit: TopShelfStore.maxEntriesPerSection).tracks
        guard !tracks.isEmpty, AuthenticationService.shared.isAuthenticated else { return false }
        publish(liked: tracks)
        return true
    }

    private static func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: reloadDelay)
            guard !Task.isCancelled else { return }
            reloadTask = nil
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    private static func samplePlayback(requirePlaying: Bool) {
        let player = PlayerService.shared
        guard let track = player.currentTrack, !track.isLocal else { return }
        guard !requirePlaying || player.isPlaying else { return }
        let progress = player.progress
        guard progress.isFinite, progress > 0 else { return }
        lastSample = (track.id, progress)
    }

    private static func currentTrackDidChange() {
        let currentID = PlayerService.shared.currentTrack?.id
        if let sample = lastSample, sample.id != currentID {
            noteProgress(sample.progress, trackID: sample.id)
        }
        lastSample = nil
        samplePlayback(requirePlaying: false)
    }

    private static func playbackDidToggle(playing: Bool) {
        samplePlayback(requirePlaying: false)
        guard !playing, let sample = lastSample else { return }
        noteProgress(sample.progress, trackID: sample.id)
    }

    private static func noteProgress(_ progress: Double, trackID: String) {
        guard AuthenticationService.shared.isAuthenticated else { return }
        var sections = loadSections()
        guard let index = sections.firstIndex(where: { $0.kind == Shelf.recents.kind }) else { return }
        let entryID = Shelf.recents.entryId(trackID)
        var changed = false
        let entries = sections[index].entries.map { entry -> TopShelfEntry in
            guard entry.id == entryID, abs(entry.progress - progress) >= 0.01 else { return entry }
            var updated = entry
            updated.progress = min(max(progress, 0), 1)
            changed = true
            return updated
        }
        guard changed else { return }
        sections[index] = TopShelfSection(kind: Shelf.recents.kind, title: Shelf.recents.title, entries: entries)
        write(sections)
    }

    // MARK: - Entries

    private static func art(_ url: URL?, id: String, subject: SoundingArtSubject) -> URL? {
        if let url, !url.absoluteString.contains("default_avatar") {
            let remote = TopShelfStore.artwork(url)
            return TopShelfArtwork.localURL(for: remote) ?? remote
        }
        return ShelfLineArt.fileURL(id: id, subject: subject)
    }

    private static func entry(for track: Track, shelf: Shelf, progress: Double = 0, playedAt: Date? = nil) -> TopShelfEntry {
        let artwork = art(track.artworkURL ?? track.user.avatarURL, id: track.id, subject: .track)
        return TopShelfEntry(
            id: shelf.entryId(track.id),
            title: track.title,
            subtitle: track.user.displayName,
            artworkURL: artwork,
            artworkURL2x: artwork,
            progress: progress,
            actionURL: TopShelfStore.trackURL(trackId: track.id),
            playActionURL: TopShelfStore.playURL(trackId: track.id, shelf: shelf.kind),
            shape: .square,
            kind: .track,
            duration: track.duration,
            playedAt: playedAt
        )
    }

    private static func entry(for discovery: DiscoveryEntry) -> TopShelfEntry? {
        switch discovery {
        case .playlist(let playlist):
            let artwork = art(playlist.displayArtworkURL, id: playlist.id, subject: .collection)
            let count = playlist.trackCount
            return TopShelfEntry(
                id: Shelf.mixes.entryId(playlist.id),
                title: playlist.title,
                subtitle: playlist.user.displayName.isEmpty
                    ? (count == 1 ? String(localized: "1 track") : String(localized: "\(count) tracks"))
                    : playlist.user.displayName,
                artworkURL: artwork,
                artworkURL2x: artwork,
                actionURL: TopShelfStore.playlistURL(id: playlist.id),
                playActionURL: TopShelfStore.playlistURL(id: playlist.id, play: true),
                shape: .square,
                kind: .playlist
            )
        case .station(let station):
            let url = TopShelfStore.mixURL(urn: station.id)
            let artwork = art(station.artworkURL, id: station.id, subject: .station)
            return TopShelfEntry(
                id: Shelf.mixes.entryId(station.id),
                title: station.shortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? station.title,
                subtitle: station.shortDescription.flatMap { $0.isEmpty ? nil : $0 } ?? station.description ?? "",
                artworkURL: artwork,
                artworkURL2x: artwork,
                actionURL: url,
                playActionURL: url,
                shape: .square,
                kind: .station
            )
        case .user:
            return nil
        }
    }

    private static func mixEntries(from shelves: [DiscoveryShelf]) -> [TopShelfEntry] {
        var entries: [TopShelfEntry] = []
        var seen = Set<String>()

        for shelf in shelves {
            let candidates: [DiscoveryEntry]
            switch shelf.content {
            case .playlists(let playlists): candidates = playlists.map(DiscoveryEntry.playlist)
            case .stations(let stations):   candidates = stations.map(DiscoveryEntry.station)
            case .mixed(let mixed):         candidates = mixed
            case .tracks, .users:           continue
            }
            for candidate in candidates {
                guard let entry = entry(for: candidate), seen.insert(entry.id).inserted else { continue }
                entries.append(entry)
            }
            if entries.count >= 12 { break }
        }
        return entries
    }

    // MARK: - Publishing

    static func publish(liked: [Track]) {
        guard AuthenticationService.shared.isAuthenticated else {
            Log.topShelf.info("publish(liked:) while signed out — clearing instead")
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

        replace(&sections, .likes, with: liked.filter { !$0.isLocal }.map { entry(for: $0, shelf: .likes) })
        write(sections)
    }

    static func publish(mixes shelves: [DiscoveryShelf]) {
        guard AuthenticationService.shared.isAuthenticated else { return }

        var sections = loadSections()
        replace(&sections, .mixes, with: mixEntries(from: shelves))
        write(sections)
    }

    static func publish(recents tracks: [Track]) {
        guard AuthenticationService.shared.isAuthenticated else { return }
        let shown = Array(tracks.filter { !$0.isLocal }.prefix(TopShelfStore.maxEntriesPerSection))
        guard !shown.isEmpty else { return }

        let playedAt = Dictionary(
            RecentlyPlayed.shared.items.map { ($0.track.id, $0.playedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        var sections = loadSections()
        let previous = sections.first { $0.kind == Shelf.recents.kind }?.entries ?? []
        let progress = Dictionary(previous.map { ($0.id, $0.progress) }, uniquingKeysWith: { first, _ in first })
        let entries = shown.map { track in
            entry(
                for: track,
                shelf: .recents,
                progress: progress[Shelf.recents.entryId(track.id)] ?? 0,
                playedAt: playedAt[track.id]
            )
        }
        replace(&sections, .recents, with: stampCurrentProgress(entries))
        write(sections)
        persistRecentTracks(shown)
    }

    static func clear() {
        lastSample = nil
        TopShelfArtwork.removeAll()
        Task {
            await LibraryCache.shared.replaceSection(
                TopShelfStore.recentsTrackCacheSection,
                rows: []
            )
        }
        write([], isSignedIn: false)
    }

    static func adoptLocalArtwork() {
        guard let snapshot = TopShelfStore.load(), snapshot.isSignedIn else { return }
        var changed = false
        let sections = snapshot.sections.map { section in
            TopShelfSection(kind: section.kind, title: section.title, entries: section.entries.map { entry in
                guard let local = TopShelfArtwork.localURL(for: entry.artworkURL) else { return entry }
                var updated = entry
                updated.artworkURL = local
                updated.artworkURL2x = local
                changed = true
                return updated
            })
        }
        guard changed else { return }
        write(sections, localiseArtwork: false)
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
        guard progress.isFinite, progress > 0 else { return entries }

        return entries.map { entry in
            guard entry.id == Shelf.recents.entryId(current.id) else { return entry }
            var updated = entry
            updated.progress = min(max(progress, 0), 1)
            return updated
        }
    }

    private static func persistRecentTracks(_ tracks: [Track]) {
        let rows = tracks.compactMap { cached -> LibraryCache.WriteRow? in
            guard let payload = try? JSONEncoder().encode(cached) else { return nil }
            return LibraryCache.WriteRow(id: cached.id, payload: payload)
        }
        Task {
            await LibraryCache.shared.replaceSection(
                TopShelfStore.recentsTrackCacheSection,
                rows: rows
            )
        }
    }

    static func cachedRecentTracks() -> [Track] {
        let decoder = JSONDecoder()
        return LibraryCache.shared.loadSection(TopShelfStore.recentsTrackCacheSection)
            .compactMap { try? decoder.decode(Track.self, from: $0.payload) }
    }

    private static func write(_ sections: [TopShelfSection], isSignedIn: Bool = true, localiseArtwork: Bool = true) {
        let ordered = sections
            .compactMap { section -> (Int, TopShelfSection)? in
                guard !section.entries.isEmpty,
                      let shelf = Shelf(kind: section.kind) else { return nil }
                return (shelf.rawValue, section)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
            .prefix(TopShelfStore.maxSections)

        let snapshot = TopShelfSnapshot(sections: Array(ordered), generatedAt: Date(), isSignedIn: isSignedIn)
        guard TopShelfStore.save(snapshot) else { return }

        NotificationCenter.default.post(name: TopShelfStore.snapshotDidChangeNotification, object: nil)
        scheduleReload()
        if localiseArtwork && isSignedIn {
            TopShelfArtwork.sync()
        }
    }

    #if DEBUG
    static func publishFixtures() {
        let tracks = VisualFixtures.tracks
        let recents = Array(tracks.prefix(8)).enumerated().map { offset, track in
            entry(for: track, shelf: .recents, progress: offset == 0 ? 0.42 : 0, playedAt: Date())
        }
        let likes = Array(tracks.dropFirst(4).prefix(10)).map { entry(for: $0, shelf: .likes) }
        let mixes = VisualFixtures.playlists.compactMap { entry(for: .playlist($0)) }

        var sections: [TopShelfSection] = []
        replace(&sections, .recents, with: recents)
        replace(&sections, .likes, with: likes)
        replace(&sections, .mixes, with: mixes)
        write(sections, localiseArtwork: false)
    }
    #endif
}

private enum ShelfLineArt {
    static func fileURL(id: String, subject: SoundingArtSubject) -> URL? {
        guard let directory = TopShelfStore.writableURL?.appendingPathComponent("ShelfArt", isDirectory: true) else { return nil }
        let name = "\(subject.rawValue)-\(GeneratedArtworkIdentity.seed(id)).png"
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let request = SoundingArtRequest(
            seed: GeneratedArtworkIdentity.seed(id),
            subject: subject,
            scheme: .dark,
            size: CGSize(width: 800, height: 800),
            scale: 1,
            exactSize: true
        )
        guard let image = SoundingArtRenderer.render(request),
              let data = UIImage(cgImage: image).pngData() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}
