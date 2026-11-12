import Foundation
import CoreGraphics

enum TrackListDensity: String, CaseIterable, Identifiable, Sendable {
    case roomy
    case dense

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roomy: return "Roomy"
        case .dense: return "Dense"
        }
    }

    var systemImage: String {
        switch self {
        case .roomy: return "list.bullet.below.rectangle"
        case .dense: return "list.dash"
        }
    }

    static func storageKey(_ list: String) -> String { "trackList.density.\(list)" }

    static func defaultValue(prefersTables: Bool) -> TrackListDensity {
        prefersTables ? .dense : .roomy
    }
}

enum TrackListColumnsPreference {
    static func storageKey(_ list: String) -> String { "trackList.showsColumns.\(list)" }

    static func migrate(_ list: String, defaults: UserDefaults = .sounding) {
        guard defaults.object(forKey: storageKey(list)) == nil,
              let stored = defaults.string(forKey: TrackListDensity.storageKey(list)) else { return }
        defaults.set(stored == TrackListDensity.dense.rawValue, forKey: storageKey(list))
    }
}

struct TrackTableColumnWidth: Sendable {
    let min: CGFloat
    let ideal: CGFloat
    let max: CGFloat
}

enum TrackTableColumn: String, CaseIterable, Identifiable, Sendable {
    case title
    case artist
    case bpm
    case key
    case genre
    case energy
    case time
    case plays
    case added
    case source
    case likes
    case album
    case released

    var id: String { rawValue }
    var customizationID: String { rawValue }

    func title(dateLabel: String = "Added") -> String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .bpm: return "BPM"
        case .key: return "Key"
        case .genre: return "Genre"
        case .energy: return "Energy"
        case .time: return "Time"
        case .plays: return "Plays"
        case .added: return dateLabel
        case .source: return "Source"
        case .likes: return "Likes"
        case .album: return "Album"
        case .released: return "Released"
        }
    }

    var settingsTitle: String {
        switch self {
        case .added: return "Date Added"
        case .time: return "Duration"
        case .album: return "Album or Release"
        default: return title()
        }
    }

    var sortKey: TrackSortKey {
        switch self {
        case .title: return .title
        case .artist: return .artist
        case .bpm: return .bpm
        case .key: return .key
        case .genre: return .genre
        case .energy: return .energy
        case .time: return .duration
        case .plays: return .plays
        case .added: return .dateAdded
        case .source: return .source
        case .likes: return .likes
        case .album: return .album
        case .released: return .released
        }
    }

    var width: TrackTableColumnWidth {
        switch self {
        case .title: return TrackTableColumnWidth(min: 180, ideal: 280, max: 1_000)
        case .artist: return TrackTableColumnWidth(min: 100, ideal: 160, max: 280)
        case .bpm: return TrackTableColumnWidth(min: 58, ideal: 68, max: 82)
        case .key: return TrackTableColumnWidth(min: 58, ideal: 68, max: 82)
        case .genre: return TrackTableColumnWidth(min: 82, ideal: 100, max: 180)
        case .energy: return TrackTableColumnWidth(min: 58, ideal: 68, max: 82)
        case .time: return TrackTableColumnWidth(min: 50, ideal: 58, max: 68)
        case .plays: return TrackTableColumnWidth(min: 50, ideal: 60, max: 80)
        case .added: return TrackTableColumnWidth(min: 98, ideal: 104, max: 130)
        case .source: return TrackTableColumnWidth(min: 70, ideal: 110, max: 140)
        case .likes: return TrackTableColumnWidth(min: 50, ideal: 60, max: 80)
        case .album: return TrackTableColumnWidth(min: 100, ideal: 160, max: 280)
        case .released: return TrackTableColumnWidth(min: 98, ideal: 104, max: 130)
        }
    }

    var isNumeric: Bool {
        switch self {
        case .bpm, .energy, .time, .plays, .likes: return true
        default: return false
        }
    }

    var isHideable: Bool { self != .title }

    var showsInDenseRow: Bool {
        switch self {
        case .title, .artist, .time, .source, .added: return false
        default: return true
        }
    }
}

struct TrackColumnLayout: Equatable, Sendable, RawRepresentable {
    static let storageKey = "trackList.columns.v1"

    static let standardOrder: [TrackTableColumn] = [
        .title, .artist, .bpm, .key, .genre, .time, .added, .album, .plays, .likes, .energy, .released, .source,
    ]
    static let standardVisible: Set<TrackTableColumn> = [.title, .artist, .bpm, .key, .genre, .time, .added, .source]
    static let standard = TrackColumnLayout(order: standardOrder, visible: standardVisible)

    private(set) var order: [TrackTableColumn]
    private(set) var visible: Set<TrackTableColumn>

    init(order: [TrackTableColumn], visible: Set<TrackTableColumn>) {
        var seen = Set<TrackTableColumn>()
        var cleaned = [TrackTableColumn.title]
        seen.insert(.title)
        for column in order where !seen.contains(column) {
            cleaned.append(column)
            seen.insert(column)
        }
        for column in Self.standardOrder where !seen.contains(column) {
            cleaned.append(column)
            seen.insert(column)
        }
        for column in TrackTableColumn.allCases where !seen.contains(column) {
            cleaned.append(column)
            seen.insert(column)
        }
        self.order = cleaned
        self.visible = visible.union([.title])
    }

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        var order: [TrackTableColumn] = []
        var visible = Set<TrackTableColumn>()
        for part in rawValue.split(separator: ",") {
            let hidden = part.hasPrefix("-")
            guard let column = TrackTableColumn(rawValue: String(hidden ? part.dropFirst() : part[...])) else { continue }
            order.append(column)
            if !hidden { visible.insert(column) }
        }
        let known = Set(order)
        for column in TrackTableColumn.allCases where !known.contains(column) && Self.standardVisible.contains(column) {
            visible.insert(column)
        }
        self.init(order: order, visible: visible)
    }

    var rawValue: String {
        order.map { visible.contains($0) ? $0.rawValue : "-" + $0.rawValue }.joined(separator: ",")
    }

    var enabled: [TrackTableColumn] { order.filter(visible.contains) }

    var denseExtras: [TrackTableColumn] {
        Array(enabled.filter(\.showsInDenseRow).prefix(2))
    }

    var isStandard: Bool { self == Self.standard }

    func isVisible(_ column: TrackTableColumn) -> Bool { visible.contains(column) }

    mutating func setVisible(_ column: TrackTableColumn, _ isVisible: Bool) {
        guard column.isHideable else { return }
        if isVisible { visible.insert(column) } else { visible.remove(column) }
    }

    var movable: [TrackTableColumn] { Array(order.dropFirst()) }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var movable = self.movable
        let valid = source.filter { movable.indices.contains($0) }
        let items = valid.sorted().map { movable[$0] }
        let before = valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { movable.remove(at: index) }
        movable.insert(contentsOf: items, at: min(max(destination - before, 0), movable.count))
        order = [.title] + movable
    }
}

enum TrackValueFormat {
    static let missing = "—"

    static func bpm(_ bpm: Double?) -> String? {
        bpm.map { "\(Int($0.rounded()))" }
    }

    static func key(_ key: CamelotKey?) -> String? {
        key?.label
    }

    static func energy(_ energy: Int?) -> String? {
        energy.map(String.init)
    }

    static func plays(_ track: Track) -> String {
        track.playbackCount.map(CompactCount.string) ?? missing
    }

    static func sourceLabel(_ track: Track) -> String {
        let label = TrackSourceKind(track).label
        guard LibraryIdentity.current.sources(of: track) == [.files, .soundCloud] else { return label }
        return track.isLocal ? "\(label) · SoundCloud" : "File · \(label)"
    }

    static func sourceSymbol(_ track: Track) -> String {
        track.isLocal || LibraryIdentity.current.localCopy(of: track) != nil ? "folder" : "cloud"
    }

    static func added(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func likes(_ track: Track) -> String {
        CompactCount.string(track.likeCount)
    }

    static func album(_ track: Track) -> String? {
        track.albumName
    }

    static func value(
        _ column: TrackTableColumn,
        track: Track,
        analysis: TrackAnalysisSummary?,
        dateAdded: Date? = nil
    ) -> String {
        switch column {
        case .title: return track.title
        case .artist: return track.user.displayName
        case .bpm: return bpm(analysis?.bpm) ?? missing
        case .key: return key(analysis?.key) ?? missing
        case .genre: return (analysis?.genre ?? track.genre).flatMap { $0.isEmpty ? nil : $0 } ?? missing
        case .energy: return energy(analysis?.energy) ?? missing
        case .time: return track.formattedDuration
        case .plays: return plays(track)
        case .added: return added(dateAdded ?? track.createdAt)
        case .source: return sourceLabel(track)
        case .likes: return likes(track)
        case .album: return album(track) ?? missing
        case .released: return added(track.createdAt)
        }
    }
}

protocol TrackKeyedSortComparator: SortComparator {
    init(key: TrackSortKey, order: SortOrder)
    var key: TrackSortKey { get }
}

extension TrackCollectionQuery {
    func tableSortOrder<Comparator: TrackKeyedSortComparator>(_: Comparator.Type = Comparator.self) -> [Comparator] {
        guard let sortKey else { return [] }
        return [Comparator(key: sortKey, order: ascending ? .forward : .reverse)]
    }

    mutating func adoptTableSort<Comparator: TrackKeyedSortComparator>(_ order: [Comparator]) {
        guard let first = order.first else { return }
        sortKey = first.key
        ascending = first.order == .forward
    }
}

#if os(iOS) || os(macOS)
import SwiftUI

extension TableColumn {
    @MainActor func trackColumn(_ column: TrackTableColumn) -> some TableColumnContent<RowValue, Sort> {
        width(min: column.width.min, ideal: column.width.ideal, max: column.width.max)
            .alignment(column.isNumeric ? .numeric : .automatic)
            .customizationID(column.customizationID)
    }
}
#endif
