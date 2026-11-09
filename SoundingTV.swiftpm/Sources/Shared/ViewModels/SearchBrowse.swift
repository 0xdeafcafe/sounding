import Foundation
import SwiftUI

enum SearchResultFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case top
    case artists
    case tracks
    case sets
    case playlists
    case albums
    case people

    var id: Self { self }

    var title: String {
        switch self {
        case .top: return "Top Results"
        case .artists: return "Artists"
        case .tracks: return "Tracks"
        case .sets: return "Sets"
        case .playlists: return "Playlists"
        case .albums: return "Albums"
        case .people: return "People"
        }
    }

    var typeName: String {
        switch self {
        case .top: return ""
        case .artists: return "Artist"
        case .tracks: return "Track"
        case .sets: return "Set"
        case .playlists: return "Playlist"
        case .albums: return "Album"
        case .people: return "Profile"
        }
    }

    static func of(_ hit: SearchHit, reason: SearchLibraryReason? = nil, setMinimumDuration: TimeInterval) -> SearchResultFilter {
        switch hit {
        case .track(let track): return track.duration >= setMinimumDuration ? .sets : .tracks
        case .playlist(let playlist): return playlist.isAlbum ? .albums : .playlists
        case .artist(let user):
            return user.trackCount > 0 || user.verified == true || reason == .followed ? .artists : .people
        }
    }
}

struct SearchResultItem: Identifiable, Hashable, Sendable {
    let hit: SearchHit
    var reason: SearchLibraryReason?
    var id: String { hit.id }

    var isNavigable: Bool { hit.track == nil }
    var isCircle: Bool {
        if case .artist = hit { return true }
        return false
    }
}

extension SearchHit {
    var kindKey: String {
        switch self {
        case .track: return "track"
        case .playlist: return "playlist"
        case .artist: return "artist"
        }
    }
}

extension SearchResults {
    var allItems: [SearchResultItem] {
        var out: [SearchResultItem] = []
        var seen = Set<String>()
        func add(_ hit: SearchHit, _ reason: SearchLibraryReason?) {
            guard seen.insert(hit.id).inserted else { return }
            out.append(SearchResultItem(hit: hit, reason: reason))
        }
        if let topResult { add(topResult, topReason) }
        for hit in library { add(hit.hit, hit.reason) }
        for track in tracks { add(.track(track), nil) }
        for track in sets { add(.track(track), nil) }
        for user in artists { add(.artist(user), nil) }
        for playlist in playlists { add(.playlist(playlist), nil) }
        return out
    }

    func availableFilters(setMinimumDuration: TimeInterval) -> Set<SearchResultFilter> {
        var found: Set<SearchResultFilter> = [.top]
        for item in allItems {
            found.insert(SearchResultFilter.of(item.hit, reason: item.reason, setMinimumDuration: setMinimumDuration))
        }
        return found
    }
}

extension SearchRanking {
    static let topResultsLimit = 24
    private static let sameKindPenalty = 120

    static func topResults(_ results: SearchResults, query: String, setMinimumDuration: TimeInterval, limit: Int = topResultsLimit) -> [SearchResultItem] {
        let items = results.allItems
        guard let first = items.first else { return [] }
        var out: [SearchResultItem] = []
        var rest = items
        if results.topResult != nil {
            out.append(first)
            rest.removeFirst()
        }
        var perKind: [SearchResultFilter: Int] = [:]
        var scored: [(item: SearchResultItem, score: Int, order: Int)] = []
        for (order, item) in rest.enumerated() {
            let kind = SearchResultFilter.of(item.hit, reason: item.reason, setMinimumDuration: setMinimumDuration)
            let rank = perKind[kind, default: 0]
            perKind[kind] = rank + 1
            let lexical = max(score(item.hit, query: query), 1)
            let boost = item.reason == nil ? 0 : libraryBoost / 3
            scored.append((item, lexical + boost - rank * sameKindPenalty, order))
        }
        scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        out.append(contentsOf: scored.prefix(max(0, limit - out.count)).map(\.item))
        return out
    }

    static func items(_ results: SearchResults, filter: SearchResultFilter, query: String, setMinimumDuration: TimeInterval) -> [SearchResultItem] {
        if filter == .top { return topResults(results, query: query, setMinimumDuration: setMinimumDuration) }
        return results.allItems.filter {
            SearchResultFilter.of($0.hit, reason: $0.reason, setMinimumDuration: setMinimumDuration) == filter
        }
    }
}

@MainActor
enum SearchTypeLine {
    static func text(_ item: SearchResultItem) -> String {
        text(item.hit, reason: item.reason)
    }

    static func text(_ hit: SearchHit, reason: SearchLibraryReason? = nil) -> String {
        let kind = SearchResultFilter.of(hit, reason: reason, setMinimumDuration: SettingsStore.shared.setMinimumDurationSeconds)
        var parts = [kind.typeName]
        switch hit {
        case .track(let track): parts.append(track.user.displayName)
        case .playlist(let playlist): parts.append(playlist.user.displayName)
        case .artist: break
        }
        if let reason, reason == .local || reason == .downloaded { parts.append(reason.title) }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

extension RecentSearchEntry {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    @MainActor
    init(hit: SearchHit) {
        self.init(
            query: hit.title,
            avatarURL: hit.artworkURL,
            subtitle: SearchTypeLine.text(hit),
            itemID: hit.id,
            kind: hit.kindKey,
            payload: Self.encode(hit)
        )
    }

    var hit: SearchHit? {
        guard let kind, let payload else { return nil }
        let decoder = Self.decoder
        switch kind {
        case "track": return (try? decoder.decode(Track.self, from: payload)).map(SearchHit.track)
        case "artist": return (try? decoder.decode(User.self, from: payload)).map(SearchHit.artist)
        case "playlist": return (try? decoder.decode(Playlist.self, from: payload)).map(SearchHit.playlist)
        default: return nil
        }
    }

    var isCircle: Bool { kind == "artist" || (kind == nil && (subtitle == "Artist" || subtitle == "Profile")) }

    private static func encode(_ hit: SearchHit) -> Data? {
        let encoder = Self.encoder
        let decoder = Self.decoder
        switch hit {
        case .track(let track):
            guard let data = try? encoder.encode(track), (try? decoder.decode(Track.self, from: data)) != nil else { return nil }
            return data
        case .artist(let user):
            guard let data = try? encoder.encode(user), (try? decoder.decode(User.self, from: data)) != nil else { return nil }
            return data
        case .playlist(let playlist):
            guard let full = try? encoder.encode(playlist),
                  var object = try? JSONSerialization.jsonObject(with: full) as? [String: Any] else { return nil }
            object["tracks"] = nil
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  (try? decoder.decode(Playlist.self, from: data)) != nil else { return nil }
            return data
        }
    }
}

struct SearchCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let chartGenre: String?
    let query: String
    let hue: Double
    let motif: SoundingArtMotif

    var chartURN: String? { chartGenre.map { "soundcloud:genres:\($0)" } }

    var top: Color { Color(hue: hue, saturation: 0.62, brightness: 0.72) }
    var bottom: Color { Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.46) }
    var tint: SoundingArtRGB { SoundingArtRGB.genreTint(id) }

    static let all: [SearchCategory] = [
        .init(id: "electronic", title: "Electronic", chartGenre: "electronic", query: "electronic", hue: 0.62, motif: .equaliser),
        .init(id: "house", title: "House", chartGenre: "house", query: "house", hue: 0.03, motif: .cone),
        .init(id: "techno", title: "Techno", chartGenre: "techno", query: "techno", hue: 0.76, motif: .waves),
        .init(id: "deep-house", title: "Deep House", chartGenre: "deephouse", query: "deep house", hue: 0.55, motif: .rings),
        .init(id: "drum-and-bass", title: "Drum & Bass", chartGenre: "drumbass", query: "drum and bass", hue: 0.33, motif: .crossfader),
        .init(id: "hip-hop", title: "Hip-Hop & Rap", chartGenre: "hiphoprap", query: "hip hop", hue: 0.08, motif: .vinyl),
        .init(id: "ambient", title: "Ambient", chartGenre: "ambient", query: "ambient", hue: 0.48, motif: .rings),
        .init(id: "chill", title: "Chill", chartGenre: nil, query: "chill", hue: 0.58, motif: .waves),
        .init(id: "party", title: "Party", chartGenre: nil, query: "party mix", hue: 0.92, motif: .jack),
        .init(id: "workout", title: "Workout", chartGenre: nil, query: "workout mix", hue: 0.40, motif: .equaliser),
        .init(id: "dubstep", title: "Dubstep", chartGenre: "dubstep", query: "dubstep", hue: 0.83, motif: .cone),
        .init(id: "trance", title: "Trance", chartGenre: "trance", query: "trance", hue: 0.68, motif: .rings),
        .init(id: "rnb", title: "R&B & Soul", chartGenre: "rbsoul", query: "r&b soul", hue: 0.97, motif: .vinyl),
        .init(id: "pop", title: "Pop", chartGenre: "pop", query: "pop", hue: 0.12, motif: .jack),
        .init(id: "lo-fi", title: "Lo-Fi", chartGenre: nil, query: "lofi", hue: 0.10, motif: .waves),
    ]
}

@MainActor
final class SearchCategoryModel: ObservableObject {
    enum State: Equatable { case loading, loaded, empty, failed }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var state: State = .loading

    let category: SearchCategory

    private static var memory: [String: (tracks: [Track], at: Date)] = [:]
    private static let lifetime: TimeInterval = 30 * 60
    private var isLoading = false

    init(category: SearchCategory) {
        self.category = category
        if let cached = Self.memory[category.id], Date().timeIntervalSince(cached.at) < Self.lifetime {
            tracks = cached.tracks
            state = cached.tracks.isEmpty ? .empty : .loaded
        }
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || state != .loaded else { return }
        isLoading = true
        defer { isLoading = false }
        if tracks.isEmpty { state = .loading }
        #if DEBUG
        if VisualFixtures.isEnabled {
            finish(VisualFixtures.tracks)
            return
        }
        #endif
        do {
            let api = SoundCloudAPI.shared
            let found: [Track]
            if let urn = category.chartURN {
                found = try await api.getCharts(kind: .trending, genreURN: urn, limit: 50).collection.map(\.track)
            } else {
                found = try await api.searchTracks(query: category.query, limit: 50).collection
            }
            guard !Task.isCancelled else { return }
            finish(found)
        } catch {
            guard !Task.isCancelled else { return }
            if tracks.isEmpty { state = .failed }
        }
    }

    private func finish(_ found: [Track]) {
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id).inserted }
        tracks = unique
        state = unique.isEmpty ? .empty : .loaded
        Self.memory[category.id] = (unique, Date())
    }
}
