import Combine
import Foundation

enum TrackSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case title      = "Title"
    case artist     = "Artist"
    case duration   = "Duration"
    case dateAdded  = "Date Added"
    case plays      = "Plays"
    case bpm        = "BPM"
    case key        = "Key"
    case energy     = "Energy"
    case genre      = "Genre"
    case source     = "Source"
    case likes      = "Likes"
    case album      = "Album"
    case released   = "Released"
    case cues       = "Cues"
    case grid       = "Grid"

    var id: String { rawValue }

    var defaultAscending: Bool {
        switch self {
        case .title, .artist, .key, .genre, .duration, .source, .album: return true
        case .dateAdded, .bpm, .plays, .energy, .likes, .released, .cues: return false
        case .grid: return true
        }
    }

    var icon: String {
        switch self {
        case .title:     return "textformat"
        case .artist:    return "person"
        case .duration:  return "clock"
        case .dateAdded: return "calendar"
        case .plays:     return "play"
        case .bpm:       return "metronome"
        case .key:       return "pianokeys"
        case .energy:    return "bolt"
        case .genre:     return "guitars"
        case .source:    return "externaldrive"
        case .likes:     return "heart"
        case .album:     return "square.stack"
        case .released:  return "calendar.badge.clock"
        case .cues:      return "circle.grid.2x2"
        case .grid:      return "lock"
        }
    }

    var isPrepOnly: Bool { self == .cues || self == .grid }

    static let menuCases: [TrackSortKey] = allCases.filter { !$0.isPrepOnly }

    func title(dateLabel: String) -> String {
        self == .dateAdded ? dateLabel : rawValue
    }
}

extension TrackSortKey {
    var analysisKind: SCAnalysisKind? {
        switch self {
        case .bpm: return .bpm
        case .key: return .key
        default:   return nil
        }
    }
}

enum TrackSourceKind: Int, Comparable, Sendable {
    case local
    case soundCloud
    case preview

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ track: Track) {
        if track.isLocal { self = .local }
        else if track.isPreviewOnly { self = .preview }
        else { self = .soundCloud }
    }

    var label: String {
        switch self {
        case .local: return "File"
        case .soundCloud: return "SoundCloud"
        case .preview: return "Preview"
        }
    }
}

enum TrackSort {
    static func unanalysedCount(
        in tracks: [Track],
        key: TrackSortKey?,
        analysis: [String: TrackAnalysisSummary]
    ) -> Int {
        switch key {
        case .bpm: return tracks.filter { analysis[$0.id]?.bpm == nil }.count
        case .key: return tracks.filter { analysis[$0.id]?.key == nil }.count
        case .energy: return tracks.filter { analysis[$0.id]?.energy == nil }.count
        default:   return 0
        }
    }

    static func sorted(
        _ tracks: [Track],
        by key: TrackSortKey,
        ascending: Bool,
        analysis: [String: TrackAnalysisSummary],
        dateAdded: (Track) -> Date = { $0.createdAt }
    ) -> [Track] {
        let order: SortOrder = ascending ? .forward : .reverse
        return tracks.enumerated().sorted { lhs, rhs in
            let result = compare(
                lhs.element, rhs.element,
                key: key,
                order: order,
                lhsAnalysis: analysis[lhs.element.id],
                rhsAnalysis: analysis[rhs.element.id],
                dateAdded: dateAdded
            )
            if result == .orderedSame { return lhs.offset < rhs.offset }
            return result == .orderedAscending
        }
        .map(\.element)
    }

    static func compare(
        _ lhs: Track,
        _ rhs: Track,
        key: TrackSortKey,
        order: SortOrder,
        lhsAnalysis: TrackAnalysisSummary?,
        rhsAnalysis: TrackAnalysisSummary?,
        dateAdded: (Track) -> Date = { $0.createdAt }
    ) -> ComparisonResult {
        switch key {
        case .title:
            return rank(lhs.title, rhs.title, order: order) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .artist:
            return rank(lhs.user.displayName, rhs.user.displayName, order: order) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .duration:
            return rank(
                lhs.isAwaitingLocalMetadata ? nil : lhs.duration,
                rhs.isAwaitingLocalMetadata ? nil : rhs.duration,
                order: order,
                by: <
            )
        case .dateAdded:
            return rank(dateAdded(lhs), dateAdded(rhs), order: order, by: <)
        case .plays:
            return rank(lhs.playbackCount, rhs.playbackCount, order: order, by: <)
        case .bpm:
            return rank(lhsAnalysis?.bpm, rhsAnalysis?.bpm, order: order, by: <)
        case .key:
            return rank(lhsAnalysis?.key, rhsAnalysis?.key, order: order) {
                ($0.wheelPosition, $0.mode.rawValue) < ($1.wheelPosition, $1.mode.rawValue)
            }
        case .energy:
            return rank(lhsAnalysis?.energy, rhsAnalysis?.energy, order: order, by: <)
        case .genre:
            return rank(lhsAnalysis?.genre ?? lhs.genre, rhsAnalysis?.genre ?? rhs.genre, order: order) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .source:
            return rank(TrackSourceKind(lhs), TrackSourceKind(rhs), order: order, by: <)
        case .likes:
            return rank(lhs.likeCount, rhs.likeCount, order: order, by: <)
        case .album:
            return rank(TrackValueFormat.album(lhs), TrackValueFormat.album(rhs), order: order) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .released:
            return rank(lhs.createdAt, rhs.createdAt, order: order, by: <)
        case .cues, .grid:
            return .orderedSame
        }
    }

    static func rank<T>(_ lhs: T?, _ rhs: T?, order: SortOrder, by less: (T, T) -> Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _?):  return .orderedDescending
        case (_?, nil):  return .orderedAscending
        case let (l?, r?):
            if less(l, r) { return order == .forward ? .orderedAscending : .orderedDescending }
            if less(r, l) { return order == .forward ? .orderedDescending : .orderedAscending }
            return .orderedSame
        }
    }

    static func sortValue(
        for track: Track,
        key: TrackSortKey?,
        analysis: TrackAnalysisSummary?,
        dateAdded: Date? = nil
    ) -> String? {
        switch key {
        case .bpm:
            guard let bpm = analysis?.bpm else { return nil }
            return ["\(Int(bpm.rounded())) BPM", analysis?.key?.label].compactMap { $0 }.joined(separator: " · ")
        case .key:
            guard let key = analysis?.key else { return nil }
            return [key.label, analysis?.bpm.map { "\(Int($0.rounded())) BPM" }].compactMap { $0 }.joined(separator: " · ")
        case .energy:
            return analysis?.energy.map { "Energy \($0)" }
        case .plays:
            return track.playbackCount.map { "\(CompactCount.string($0)) plays" }
        case .dateAdded:
            return dateAdded.map { $0.formatted(date: .abbreviated, time: .omitted) }
        case .source:
            return TrackSourceKind(track).label
        case .likes:
            return "\(CompactCount.string(track.likeCount)) likes"
        case .album:
            return TrackValueFormat.album(track)
        case .released:
            return track.createdAt.formatted(date: .abbreviated, time: .omitted)
        case .genre:
            return (analysis?.genre ?? track.genre).map(GenrePresentation.displayName(for:))
        case .title, .artist, .duration, .cues, .grid, nil:
            return nil
        }
    }
}

// MARK: - Filters

enum TrackFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case downloaded
    case local
    case soundCloud
    case previews
    case sets
    case analysed
    case keyCompatible
    case unplayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloaded: return "Downloaded"
        case .local: return "Files"
        case .soundCloud: return "SoundCloud"
        case .previews: return "Previews"
        case .sets: return "Sets"
        case .analysed: return "Analysed"
        case .keyCompatible: return "In Key with Now Playing"
        case .unplayed: return "Not Played"
        }
    }

    var icon: String {
        switch self {
        case .downloaded: return "arrow.down.circle"
        case .local: return "folder"
        case .soundCloud: return "cloud"
        case .previews: return "30.circle"
        case .sets: return "timer"
        case .analysed: return "waveform"
        case .keyCompatible: return "pianokeys"
        case .unplayed: return "circle.dashed"
        }
    }

    var isSource: Bool {
        switch self {
        case .downloaded, .local, .soundCloud, .previews: return true
        default: return false
        }
    }

    static let sourceFilters = allCases.filter(\.isSource)
    static let propertyFilters = allCases.filter { !$0.isSource }
}

struct TrackBPMRange: Codable, Hashable, Sendable, Identifiable {
    var lower: Double
    var upper: Double?

    var id: String { label }

    func contains(_ bpm: Double) -> Bool {
        bpm >= lower && (upper.map { bpm < $0 } ?? true)
    }

    var label: String {
        if let upper {
            return lower <= 0 ? "Under \(Int(upper)) BPM" : "\(Int(lower))–\(Int(upper)) BPM"
        }
        return "\(Int(lower))+ BPM"
    }

    static let presets: [TrackBPMRange] = [
        TrackBPMRange(lower: 0, upper: 100),
        TrackBPMRange(lower: 100, upper: 120),
        TrackBPMRange(lower: 120, upper: 128),
        TrackBPMRange(lower: 128, upper: 135),
        TrackBPMRange(lower: 135, upper: 150),
        TrackBPMRange(lower: 150, upper: nil),
    ]
}

struct TrackFilterContext {
    var isDownloaded: (Track) -> Bool = { _ in false }
    var isPlayed: (Track) -> Bool = { _ in false }
    var nowPlayingKey: CamelotKey? = nil
    var setMinimumDuration: TimeInterval = TrackFilterContext.defaultSetMinimumDuration

    static let defaultSetMinimumDuration: TimeInterval = 30 * 60
}

struct TrackCollectionQuery: Equatable, Sendable, RawRepresentable {
    var sortKey: TrackSortKey?
    var ascending: Bool
    var filters: Set<TrackFilter>
    var bpmRange: TrackBPMRange?

    init(sortKey: TrackSortKey?, ascending: Bool? = nil, filters: Set<TrackFilter> = [], bpmRange: TrackBPMRange? = nil) {
        self.sortKey = sortKey
        self.ascending = ascending ?? sortKey?.defaultAscending ?? true
        self.filters = filters
        self.bpmRange = bpmRange
    }

    static let newestFirst = TrackCollectionQuery(sortKey: .dateAdded, ascending: false)
    static let collectionOrder = TrackCollectionQuery(sortKey: nil, ascending: true)

    var isFiltering: Bool { !filters.isEmpty || bpmRange != nil }
    var activeFilterCount: Int { filters.count + (bpmRange == nil ? 0 : 1) }

    mutating func toggle(_ filter: TrackFilter) {
        if filters.contains(filter) { filters.remove(filter) } else { filters.insert(filter) }
    }

    mutating func select(_ key: TrackSortKey?) {
        guard key != sortKey else { return }
        sortKey = key
        ascending = key?.defaultAscending ?? true
    }

    mutating func clearFilters() {
        filters = []
        bpmRange = nil
    }

    private struct Stored: Codable {
        var sortKey: TrackSortKey?
        var ascending: Bool
        var filters: [TrackFilter]
        var bpmRange: TrackBPMRange?
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        self.init(sortKey: stored.sortKey, ascending: stored.ascending, filters: Set(stored.filters), bpmRange: stored.bpmRange)
    }

    var rawValue: String {
        let stored = Stored(
            sortKey: sortKey,
            ascending: ascending,
            filters: filters.sorted { $0.rawValue < $1.rawValue },
            bpmRange: bpmRange
        )
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum TrackCollection {
    static func matches(
        _ track: Track,
        query: TrackCollectionQuery,
        analysis: TrackAnalysisSummary?,
        context: TrackFilterContext
    ) -> Bool {
        let sources = query.filters.filter(\.isSource)
        if !sources.isEmpty, !sources.contains(where: { matches(track, filter: $0, analysis: analysis, context: context) }) {
            return false
        }
        for filter in query.filters where !filter.isSource {
            if !matches(track, filter: filter, analysis: analysis, context: context) { return false }
        }
        if let range = query.bpmRange {
            guard let bpm = analysis?.bpm, range.contains(bpm) else { return false }
        }
        return true
    }

    static func matches(
        _ track: Track,
        filter: TrackFilter,
        analysis: TrackAnalysisSummary?,
        context: TrackFilterContext
    ) -> Bool {
        switch filter {
        case .downloaded: return context.isDownloaded(track)
        case .local: return track.isLocal
        case .soundCloud: return !track.isLocal && !track.isPreviewOnly
        case .previews: return track.isPreviewOnly
        case .sets: return !track.isAwaitingLocalMetadata && track.duration >= context.setMinimumDuration
        case .analysed: return analysis?.bpm != nil || analysis?.key != nil
        case .keyCompatible:
            guard let target = context.nowPlayingKey, let key = analysis?.key else { return false }
            return target.harmonicallyCompatible.contains(key)
        case .unplayed: return !context.isPlayed(track)
        }
    }

    static func matchesSearch(_ track: Track, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return track.title.localizedStandardContains(needle)
            || track.user.displayName.localizedStandardContains(needle)
            || (track.genre?.localizedStandardContains(needle) ?? false)
    }

    static func apply(
        _ tracks: [Track],
        query: TrackCollectionQuery,
        search: String = "",
        analysis: [String: TrackAnalysisSummary],
        context: TrackFilterContext = TrackFilterContext(),
        dateAdded: (Track) -> Date = { $0.createdAt }
    ) -> [Track] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = needle.isEmpty && !query.isFiltering ? tracks : tracks.filter { track in
            matchesSearch(track, needle: needle)
                && matches(track, query: query, analysis: analysis[track.id], context: context)
        }
        guard let key = query.sortKey else { return filtered }
        return TrackSort.sorted(filtered, by: key, ascending: query.ascending, analysis: analysis, dateAdded: dateAdded)
    }

    static func needsFullCollection(_ query: TrackCollectionQuery, naturalOrder: TrackCollectionQuery) -> Bool {
        guard query.sortKey != nil else { return false }
        return query.sortKey != naturalOrder.sortKey || query.ascending != naturalOrder.ascending
    }

    static func availableSortKeys(for tracks: [Track], analysis: [String: TrackAnalysisSummary]) -> [TrackSortKey] {
        let hasEnergy = tracks.contains { analysis[$0.id]?.energy != nil }
        let hasPlays = tracks.contains { $0.playbackCount != nil }
        let mixedSources = Set(tracks.prefix(500).map(TrackSourceKind.init)).count > 1
        let hasAlbums = tracks.prefix(500).contains { TrackValueFormat.album($0) != nil }
        return TrackSortKey.allCases.filter { key in
            switch key {
            case .energy: return hasEnergy
            case .plays: return hasPlays
            case .source: return mixedSources
            case .album: return hasAlbums
            case .cues, .grid: return false
            default: return true
            }
        }
    }
}

@MainActor
enum TrackCollectionLoader {
    static func loadAll<Item: Identifiable>(_ pager: Paginator<Item>) async {
        pager.attend()
        while !Task.isCancelled, pager.hasMore, !pager.isPaused, !pager.didFailLoadingMore {
            if pager.isLoadingMore || pager.isLoadingFirst {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let before = pager.items.count
            await pager.loadMore()
            if pager.items.count == before, pager.isLoadingMore == false, pager.hasMore == false { break }
        }
    }

    static func context(setMinimumDuration: TimeInterval? = nil) -> TrackFilterContext {
        let downloaded = Set(DownloadManager.shared.states.compactMap { $0.value == .downloaded ? $0.key : nil })
        let played = PlayedTrackLog.shared.ids
        let nowPlaying = PlayerService.shared.currentTrack
        return TrackFilterContext(
            isDownloaded: { downloaded.contains($0.id) },
            isPlayed: { played.contains($0.id) },
            nowPlayingKey: nowPlaying.flatMap { AnalysisLookup.summary(for: $0)?.key },
            setMinimumDuration: setMinimumDuration ?? SettingsStore.shared.setMinimumDurationSeconds
        )
    }
}

@MainActor
final class TrackAnalysisStore: ObservableObject {
    @Published private(set) var summaries: [String: TrackAnalysisSummary] = [:] {
        didSet { revision &+= 1 }
    }
    private(set) var revision = 0

    private var known: [String: Track] = [:]
    private var changed: Set<String> = []
    private var changedEverything = false
    private var cancellable: AnyCancellable?

    init() {
        cancellable = NotificationCenter.default.publisher(for: .analysisDataDidChange)
            .receive(on: RunLoop.main)
            .handleEvents(receiveOutput: { [weak self] note in
                let trackIds = note.userInfo?[AnalysisDataChange.trackIdsKey] as? [String]
                MainActor.assumeIsolated { self?.noteChange(trackIds) }
            })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadChanged() }
            }
    }

    func load(for tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        for track in tracks { known[track.id] = track }
        let fresh = await AnalysisLookup.summaries(for: tracks)
        guard !fresh.isEmpty else { return }
        summaries.merge(fresh) { _, new in new }
    }

    private func noteChange(_ trackIds: [String]?) {
        guard let trackIds else {
            changedEverything = true
            return
        }
        changed.formUnion(trackIds.filter { known[$0] != nil })
    }

    private func reloadChanged() {
        let tracks = changedEverything ? Array(known.values) : changed.compactMap { known[$0] }
        changed.removeAll()
        changedEverything = false
        guard !tracks.isEmpty else { return }
        Task { await load(for: tracks) }
    }
}
