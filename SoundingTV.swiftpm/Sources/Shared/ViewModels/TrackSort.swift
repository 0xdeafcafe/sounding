import Foundation

enum TrackSortKey: String, CaseIterable, Identifiable {
    case title      = "Title"
    case artist     = "Artist"
    case duration   = "Duration"
    case dateAdded  = "Date Added"
    case bpm        = "BPM"
    case key        = "Key"
    case genre      = "Genre"

    var id: String { rawValue }

    var defaultAscending: Bool {
        switch self {
        case .title, .artist, .key, .genre, .duration: return true
        case .dateAdded, .bpm: return false
        }
    }

    var icon: String {
        switch self {
        case .title:     return "textformat"
        case .artist:    return "person"
        case .duration:  return "clock"
        case .dateAdded: return "calendar"
        case .bpm:       return "metronome"
        case .key:       return "pianokeys"
        case .genre:     return "guitars"
        }
    }
}

enum TrackSort {
    static func sorted(
        _ tracks: [Track],
        by key: TrackSortKey,
        ascending: Bool,
        analysis: [String: TrackAnalysisSummary],
        dateAdded: (Track) -> Date = { $0.createdAt }
    ) -> [Track] {
        tracks.sorted { lhs, rhs in
            compare(
                lhs, rhs,
                key: key,
                order: ascending ? .forward : .reverse,
                lhsAnalysis: analysis[lhs.id],
                rhsAnalysis: analysis[rhs.id],
                dateAdded: dateAdded
            ) == .orderedAscending
        }
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
            return rank(lhs.duration, rhs.duration, order: order, by: <)
        case .dateAdded:
            return rank(dateAdded(lhs), dateAdded(rhs), order: order, by: <)
        case .bpm:
            return rank(lhsAnalysis?.bpm, rhsAnalysis?.bpm, order: order, by: <)
        case .key:
            return rank(lhsAnalysis?.key, rhsAnalysis?.key, order: order) {
                ($0.wheelPosition, $0.mode.rawValue) < ($1.wheelPosition, $1.mode.rawValue)
            }
        case .genre:
            return rank(lhsAnalysis?.genre, rhsAnalysis?.genre, order: order) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
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
}

@MainActor
final class TrackAnalysisStore: ObservableObject {
    @Published private(set) var summaries: [String: TrackAnalysisSummary] = [:]

    func load(for tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        let fresh = await AnalysisLookup.summaries(for: tracks)
        guard !fresh.isEmpty else { return }
        summaries.merge(fresh) { _, new in new }
    }
}
