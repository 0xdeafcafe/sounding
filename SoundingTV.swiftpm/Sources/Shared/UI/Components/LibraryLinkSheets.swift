#if os(iOS) || os(macOS)
import SwiftUI

enum LibraryLinkRequest: Identifiable {
    case album(LocalCollection)
    case soundCloudAlbum(Playlist)
    case track(Track)
    case soundCloudTrack(Track)

    var id: String {
        switch self {
        case .album(let album): "album.\(album.id)"
        case .soundCloudAlbum(let playlist): "playlist.\(playlist.id)"
        case .track(let track): "track.\(track.id)"
        case .soundCloudTrack(let track): "sc.\(track.id)"
        }
    }
}

@MainActor
final class LibraryLinkPresenter: ObservableObject {
    static let shared = LibraryLinkPresenter()

    @Published var request: LibraryLinkRequest?

    func present(_ request: LibraryLinkRequest) {
        self.request = request
    }
}

extension View {
    func libraryLinkHost() -> some View {
        modifier(LibraryLinkHost())
    }
}

private struct LibraryLinkHost: ViewModifier {
    @ObservedObject private var presenter = LibraryLinkPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.request) { request in
            LibraryLinkSheet(request: request)
        }
    }
}

struct LibraryAlbumLinkMenuItems: View {
    let route: LibraryCollectionRoute

    var body: some View {
        let index = LibraryIdentity.current
        switch route {
        case .local(let album) where album.kind == .album:
            let remote = index.soundCloudAlbum(forLocalAlbumID: album.id)
            let origin = index.albumOrigin(forLocalAlbumID: album.id)
            Section {
                if let remote {
                    Button("Linked to \(remote.title)", systemImage: "link") {}
                        .disabled(true)
                }
                Button(remote == nil ? "Link to SoundCloud Album…" : "Link to Another SoundCloud Album…", systemImage: "link") {
                    LibraryLinkPresenter.shared.present(.album(album))
                }
                if remote != nil {
                    Button("Unlink", systemImage: "minus.circle") {
                        LibraryIdentity.shared.unlink(album: album)
                    }
                } else if origin == .unlinked {
                    Button("Link Automatically", systemImage: "wand.and.stars") {
                        LibraryIdentity.shared.allowAutomaticLinking(album: album)
                    }
                } else {
                    Button("Don’t Link Automatically", systemImage: "link.badge.minus") {
                        LibraryIdentity.shared.unlink(album: album)
                    }
                }
            }
        case .playlist(let playlist) where playlist.isAlbum && index.hasLocalFiles:
            let local = index.localAlbum(forPlaylistID: playlist.id)
            Section {
                if let local {
                    Button("Linked to \(local.title)", systemImage: "link") {}
                        .disabled(true)
                }
                Button(local == nil ? "Link to File…" : "Link to Another File…", systemImage: "link") {
                    LibraryLinkPresenter.shared.present(.soundCloudAlbum(playlist))
                }
                if let local {
                    Button("Unlink", systemImage: "minus.circle") {
                        LibraryIdentity.shared.unlink(album: local)
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

struct LibraryTrackLinkMenuItems: View {
    let track: Track

    var body: some View {
        let index = LibraryIdentity.current
        if track.isLocal {
            let remote = index.soundCloudCopy(of: track)
            let origin = index.trackOrigin(forLocalTrackID: track.id)
            Section {
                if let remote {
                    Button("Linked to \(remote.title)", systemImage: "link") {}
                        .disabled(true)
                }
                Button(remote == nil ? "Link to SoundCloud Track…" : "Link to Another SoundCloud Track…", systemImage: "link") {
                    LibraryLinkPresenter.shared.present(.track(track))
                }
                if remote != nil {
                    Button("Unlink", systemImage: "minus.circle") {
                        LibraryIdentity.shared.unlink(track: track)
                    }
                } else if origin == .unlinked {
                    Button("Link Automatically", systemImage: "wand.and.stars") {
                        LibraryIdentity.shared.allowAutomaticLinking(track: track)
                    }
                } else {
                    Button("Don’t Link Automatically", systemImage: "link.badge.minus") {
                        LibraryIdentity.shared.unlink(track: track)
                    }
                }
            }
        } else if index.hasLocalFiles {
            let local = index.localCopy(of: track)
            Section {
                if let local {
                    Button("Linked to \(local.title)", systemImage: "link") {}
                        .disabled(true)
                }
                Button(local == nil ? "Link to File…" : "Link to Another File…", systemImage: "link") {
                    LibraryLinkPresenter.shared.present(.soundCloudTrack(track))
                }
                if let local {
                    Button("Unlink", systemImage: "minus.circle") {
                        LibraryIdentity.shared.unlink(track: local)
                    }
                }
            }
        }
    }
}

private struct LibraryLinkArtwork: View {
    let url: URL?
    let identity: String

    var body: some View {
        #if os(macOS)
        ArtworkThumbnail(url: url, identity: identity, size: 44, cornerRadius: 6)
        #else
        ArtworkThumbnail(url: url, systemImage: "music.note", isCircle: false, size: 44, cornerRadius: 6, identity: identity)
        #endif
    }
}

struct LibraryLinkSheet: View {
    let request: LibraryLinkRequest

    @Environment(\.dismiss) private var dismiss
    @State private var pool: [LibraryLinkEntry] = []
    @State private var isLoaded = false
    @State private var searchText = ""

    private var filtered: [LibraryLinkEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(pool.filter(\.isSuggested).prefix(200)) }
        return Array(pool.filter { LibraryNames.matches($0.title, query: needle) || LibraryNames.matches($0.artist, query: needle) }.prefix(300))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(text: $searchText, prompt: prompt)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 620)
        #endif
        .task {
            pool = await LibraryLinkCandidates.load(for: request)
            isLoaded = true
        }
    }

    private var title: String {
        switch request {
        case .album(let album): "Link \(album.title)"
        case .soundCloudAlbum(let playlist): "Link \(playlist.title)"
        case .track(let track), .soundCloudTrack(let track): "Link \(track.title)"
        }
    }

    private var prompt: String {
        switch request {
        case .album: "Search SoundCloud Albums"
        case .soundCloudAlbum: "Search Your Albums"
        case .track: "Search SoundCloud Tracks"
        case .soundCloudTrack: "Search Your Files"
        }
    }

    private var emptyTitle: String {
        switch request {
        case .album: "No SoundCloud Albums"
        case .soundCloudAlbum: "No Albums in Your Files"
        case .track: "No SoundCloud Tracks"
        case .soundCloudTrack: "No Tracks in Your Files"
        }
    }

    private var emptyDescription: String {
        switch request {
        case .album: "Albums you like or save appear here."
        case .soundCloudAlbum: "Add a music folder to link its albums."
        case .track: "Tracks you like appear here."
        case .soundCloudTrack: "Add a music folder to link its tracks."
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pool.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "link", description: Text(emptyDescription))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No Close Matches",
                    systemImage: "magnifyingglass",
                    description: Text("Search to find one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(filtered) { entry in
                Button {
                    LibraryLinkCandidates.apply(entry, for: request)
                    dismiss()
                } label: {
                    row(entry)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ entry: LibraryLinkEntry) -> some View {
        HStack(spacing: 12) {
            LibraryLinkArtwork(url: entry.artworkURL, identity: "link.\(entry.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.detail)
                        .foregroundStyle(.secondary)
                    if let hint = entry.hint {
                        Text(hint)
                            .foregroundStyle(entry.hintIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Linked")
            }
        }
        .contentShape(Rectangle())
    }
}

struct LibraryLinkEntry: Identifiable, Sendable {
    enum Target: Sendable {
        case playlist(Playlist)
        case localAlbum(LocalCollection)
        case track(Track)
    }

    let id: String
    let title: String
    let artist: String
    let detail: String
    var hint: String?
    var hintIsWarning = false
    let artworkURL: URL?
    var isCurrent = false
    var isSuggested = true
    let target: Target
}

@MainActor
enum LibraryLinkCandidates {
    static func apply(_ entry: LibraryLinkEntry, for request: LibraryLinkRequest) {
        let identity = LibraryIdentity.shared
        switch (request, entry.target) {
        case (.album(let album), .playlist(let playlist)):
            identity.link(album: album, to: playlist)
        case (.soundCloudAlbum(let playlist), .localAlbum(let album)):
            identity.link(album: album, to: playlist)
        case (.track(let local), .track(let remote)):
            identity.link(track: local, to: remote)
        case (.soundCloudTrack(let remote), .track(let local)):
            identity.link(track: local, to: remote)
        default:
            break
        }
    }

    static func load(for request: LibraryLinkRequest) async -> [LibraryLinkEntry] {
        let index = LibraryIdentity.shared.index
        switch request {
        case .album(let album): return await albumCandidates(for: album, index: index)
        case .soundCloudAlbum(let playlist): return await fileAlbumCandidates(for: playlist, index: index)
        case .track(let track): return await soundCloudTrackCandidates(for: track, index: index)
        case .soundCloudTrack(let track): return fileTrackCandidates(for: track, index: index)
        }
    }

    private static let hintLimit = 80

    private static func isAlbumLike(_ playlist: Playlist) -> Bool {
        if playlist.isAlbum { return true }
        guard let type = playlist.setType?.lowercased() else { return false }
        return ["album", "ep", "single"].contains(type)
    }

    private static func year(_ playlist: Playlist) -> Int {
        Calendar.current.component(.year, from: playlist.releaseDate ?? playlist.createdAt)
    }

    private static func albumDetail(_ playlist: Playlist) -> String {
        let count = playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks"
        return "\(count) · \(year(playlist))"
    }

    private static func albumArtistKeys(_ album: LocalCollection) -> Set<String> {
        var keys = Set<String>()
        for track in album.tracks { keys.formUnion(LibraryNames.creditKeys(track.user.displayName)) }
        return keys
    }

    private static func albumCandidates(for album: LocalCollection, index: LibraryIdentityIndex) async -> [LibraryLinkEntry] {
        let current = index.soundCloudAlbum(forLocalAlbumID: album.id)
        var pool = index.soundCloudAlbums
        var linkedUserIDs = Set<String>()
        for track in album.tracks {
            if let key = LocalCollections.artistKey(of: track), let user = index.artist(forLocalKey: key)?.user {
                linkedUserIDs.insert(user.id)
            }
        }
        for userID in linkedUserIDs {
            pool.append(contentsOf: (index.playlistsByUserID[userID] ?? []).filter(isAlbumLike))
        }
        if let current { pool.append(current) }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.id).inserted }

        let titleKey = LibraryNames.albumKey(album.title)
        let artistKeys = albumArtistKeys(album)
        func rank(_ playlist: Playlist) -> Int {
            var score = 0
            if LibraryNames.albumKey(playlist.title) == titleKey { score += 4 }
            if linkedUserIDs.contains(playlist.user.id) { score += 2 }
            if !artistKeys.isDisjoint(with: LibraryNames.creditKeys(playlist.user.displayName)) { score += 1 }
            return score
        }
        let ranked = pool
            .map { ($0, rank($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }

        let localKeys = Set(album.tracks.map { LibraryNames.trackKey($0.title) })
        var entries: [LibraryLinkEntry] = []
        for (position, item) in ranked.enumerated() {
            let (playlist, score) = item
            var entry = LibraryLinkEntry(
                id: playlist.id,
                title: playlist.title,
                artist: playlist.user.displayName,
                detail: albumDetail(playlist),
                artworkURL: playlist.displayArtworkURL,
                isCurrent: playlist.id == current?.id,
                isSuggested: score > 0 || position < 40,
                target: .playlist(playlist)
            )
            if position < hintLimit {
                let remote: [Track]
                if let inline = playlist.tracks, !inline.isEmpty {
                    remote = inline
                } else {
                    remote = await LibraryDB.playlistTracks(id: playlist.id) ?? []
                }
                if !remote.isEmpty {
                    let remoteKeys = Set(remote.map { LibraryNames.trackKey($0.title) })
                    let matched = localKeys.intersection(remoteKeys).count
                    entry.hint = "\(matched) of \(album.tracks.count) tracks match"
                    entry.hintIsWarning = matched < album.tracks.count / 2
                }
            }
            entries.append(entry)
        }
        return entries
    }

    private static func fileAlbumCandidates(for playlist: Playlist, index: LibraryIdentityIndex) async -> [LibraryLinkEntry] {
        let current = index.localAlbum(forPlaylistID: playlist.id)
        let titleKey = LibraryNames.albumKey(playlist.title)
        let owners = LibraryNames.creditKeys(playlist.user.displayName)
        let remote: [Track]
        if let inline = playlist.tracks, !inline.isEmpty {
            remote = inline
        } else {
            remote = await LibraryDB.playlistTracks(id: playlist.id) ?? []
        }
        let remoteKeys = Set(remote.map { LibraryNames.trackKey($0.title) })

        func rank(_ album: LocalCollection) -> Int {
            var score = 0
            if LibraryNames.albumKey(album.title) == titleKey { score += 4 }
            if !owners.isDisjoint(with: albumArtistKeys(album)) { score += 1 }
            return score
        }
        let ranked = index.localAlbums
            .map { ($0, rank($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
        return ranked.enumerated().map { position, item in
            let (album, score) = item
            var entry = LibraryLinkEntry(
                id: album.id,
                title: album.title,
                artist: album.subtitle,
                detail: album.trackCountText,
                artworkURL: album.artworkURL,
                isCurrent: album.id == current?.id,
                isSuggested: score > 0 || position < 40,
                target: .localAlbum(album)
            )
            if !remoteKeys.isEmpty {
                let matched = Set(album.tracks.map { LibraryNames.trackKey($0.title) }).intersection(remoteKeys).count
                entry.hint = "\(matched) of \(album.tracks.count) tracks match"
                entry.hintIsWarning = matched < album.tracks.count / 2
            }
            return entry
        }
    }

    private static func titleScore(_ lhs: String, _ rhs: String) -> Int {
        let left = LibraryNames.trackKey(lhs), right = LibraryNames.trackKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 3 }
        if min(left.count, right.count) >= 4, left.contains(right) || right.contains(left) { return 2 }
        let a = Set(left.split(separator: " ")), b = Set(right.split(separator: " "))
        let union = a.union(b).count
        if union > 0, Double(a.intersection(b).count) / Double(union) >= 0.5 { return 1 }
        return 0
    }

    private static func durationHint(reference: TimeInterval, candidate: TimeInterval) -> (String, Bool)? {
        guard reference > 0, candidate > 0 else { return nil }
        let delta = candidate - reference
        guard abs(delta) > LibraryIdentityMatcher.trackDurationTolerance else { return nil }
        let seconds = Int(abs(delta).rounded())
        return (delta > 0 ? "+\(seconds) s" : "−\(seconds) s", true)
    }

    private static func trackEntry(
        _ track: Track,
        reference: Track,
        current: Track?,
        score: Int,
        suggested: Bool
    ) -> LibraryLinkEntry {
        var entry = LibraryLinkEntry(
            id: track.id,
            title: track.title,
            artist: track.user.displayName,
            detail: track.formattedDuration,
            artworkURL: track.artworkURL,
            isCurrent: track.id == current?.id,
            isSuggested: suggested,
            target: .track(track)
        )
        if let (text, warning) = durationHint(reference: reference.duration, candidate: track.duration) {
            entry.hint = text
            entry.hintIsWarning = warning
        }
        return entry
    }

    private static func ordered(_ groups: [[(Track, Int)]]) -> [(Track, Int)] {
        var seen = Set<String>()
        var out: [(Track, Int)] = []
        for group in groups {
            let sorted = group.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            for item in sorted where seen.insert(item.0.id).inserted { out.append(item) }
        }
        return out
    }

    private static func soundCloudTrackCandidates(for local: Track, index: LibraryIdentityIndex) async -> [LibraryLinkEntry] {
        let current = index.soundCloudCopy(of: local)
        let credits = LibraryNames.creditKeys(local.user.displayName)
        func score(_ track: Track) -> Int {
            var value = titleScore(local.title, track.title)
            if value > 0, !credits.isDisjoint(with: LibraryNames.creditKeys(track.user.displayName)) { value += 1 }
            return value
        }

        let likeCount = await LibraryDB.count(.likes)
        let liked = likeCount > 0 ? await LibraryDB.tracks(.likes, offset: 0, limit: min(likeCount, 25_000)).tracks : []
        let likedIDs = Set(liked.map(\.id))

        var related: [Track] = []
        if let albumID = LocalCollections.albumID(of: local), let album = index.soundCloudAlbum(forLocalAlbumID: albumID) {
            if let inline = album.tracks, !inline.isEmpty {
                related.append(contentsOf: inline)
            } else {
                related.append(contentsOf: await LibraryDB.playlistTracks(id: album.id) ?? [])
            }
        }
        if let key = LocalCollections.artistKey(of: local), let user = index.artist(forLocalKey: key)?.user {
            related.append(contentsOf: index.likedTracksByUserID[user.id] ?? [])
        }
        related = related.filter { !likedIDs.contains($0.id) }

        let groups: [[(Track, Int)]] = [
            liked.map { ($0, score($0)) },
            related.map { ($0, score($0)) },
        ]
        let relatedIDs = Set(related.map(\.id))
        return ordered(groups).map { track, value in
            trackEntry(track, reference: local, current: current, score: value, suggested: value > 0 || relatedIDs.contains(track.id))
        }
    }

    private static func fileTrackCandidates(for remote: Track, index: LibraryIdentityIndex) -> [LibraryLinkEntry] {
        let current = index.localCopy(of: remote)
        let credits = LibraryNames.creditKeys(remote.user.displayName)
        func score(_ track: Track) -> Int {
            var value = titleScore(remote.title, track.title)
            if value > 0, !credits.isDisjoint(with: LibraryNames.creditKeys(track.user.displayName)) { value += 1 }
            return value
        }
        var pool = index.localAlbums.flatMap(\.tracks)
        pool.append(contentsOf: index.artists.compactMap(\.local).flatMap(\.tracks))
        let ranked = ordered([pool.map { ($0, score($0)) }])
        return ranked.map { track, value in
            trackEntry(track, reference: remote, current: current, score: value, suggested: value > 0)
        }
    }
}
#endif
