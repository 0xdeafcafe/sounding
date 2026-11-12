import SwiftUI

private struct TrackSortKeyEnvironmentKey: EnvironmentKey {
    static let defaultValue: TrackSortKey? = nil
}

private struct TrackListShowsColumnsEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var trackSortKey: TrackSortKey? {
        get { self[TrackSortKeyEnvironmentKey.self] }
        set { self[TrackSortKeyEnvironmentKey.self] = newValue }
    }

    var trackListShowsColumns: Bool {
        get { self[TrackListShowsColumnsEnvironmentKey.self] }
        set { self[TrackListShowsColumnsEnvironmentKey.self] = newValue }
    }
}

extension AppStorage where Value == Bool {
    @MainActor init(trackListColumns list: String) {
        TrackListColumnsPreference.migrate(list)
        self.init(wrappedValue: false, TrackListColumnsPreference.storageKey(list))
    }
}

struct UnanalysedTracksFooter: View {
    let tracks: [Track]
    let sortKey: TrackSortKey?
    let summaries: [String: TrackAnalysisSummary]

    var body: some View {
        let count = TrackSort.unanalysedCount(in: tracks, key: sortKey, analysis: summaries)
        if count > 0 {
            Text(count == 1 ? "1 track not yet analysed." : "\(count) tracks not yet analysed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.sm)
                .listRowSeparator(.hidden)
        }
    }
}

struct TrackSortMenu: View {
    @Binding var sortKey: TrackSortKey
    @Binding var ascending: Bool
    var showsColumns: Binding<Bool>? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Menu {
            if let showsColumns, horizontalSizeClass == .regular {
                TrackListColumnsToggle(showsColumns: showsColumns)
            }

            Picker("Sort by", selection: $sortKey) {
                ForEach(TrackSortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.icon).tag(key)
                }
            }

            Section {
                Button {
                    ascending.toggle()
                } label: {
                    Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
                }
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
                .frame(minWidth: 44, minHeight: 44)
        }
        .onChange(of: sortKey) { _, newKey in
            ascending = newKey.defaultAscending
        }
        .accessibilityLabel("Sort")
    }
}

struct PlaylistSortMenu: View {
    @Binding var sortKey: TrackSortKey?
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                Label("Playlist Order", systemImage: "list.number").tag(TrackSortKey?.none)
                ForEach(TrackSortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.icon).tag(TrackSortKey?.some(key))
                }
            }

            if sortKey != nil {
                Section {
                    Button {
                        ascending.toggle()
                    } label: {
                        Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .onChange(of: sortKey) { _, newKey in
            if let newKey { ascending = newKey.defaultAscending }
        }
        .accessibilityLabel("Sort")
    }
}

// MARK: - Sort & Filter

struct TrackCollectionMenu: View {
    @Binding var query: TrackCollectionQuery
    var showsColumns: Binding<Bool>? = nil
    var sortKeys: [TrackSortKey] = TrackSortKey.allCases
    var dateLabel = "Date Added"
    var naturalOrderLabel: String? = nil
    var filters: [TrackFilter] = TrackFilter.allCases
    var analyseTracks: [Track]? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Menu {
            TrackCollectionMenuItems(
                query: $query,
                showsColumns: horizontalSizeClass == .regular ? showsColumns : nil,
                sortKeys: sortKeys,
                dateLabel: dateLabel,
                naturalOrderLabel: naturalOrderLabel,
                filters: filters
            )
            if let analyseTracks {
                Section {
                    AnalyseMissingMenuItems(tracks: analyseTracks)
                }
            }
        } label: {
            Label(
                "Sort & Filter",
                systemImage: query.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Sort and Filter")
        .accessibilityValue(query.isFiltering ? "\(query.activeFilterCount) filters on" : "")
    }
}

struct TrackCollectionLoadAllRow: View {
    @ObservedObject var pager: Paginator<Track>
    let noun: String
    let isLoadingAll: Bool
    let isFiltering: Bool
    let loadAll: () -> Void
    let stop: () -> Void

    private var loaded: Int { pager.items.count }
    private var total: Int? { pager.total.map { max($0, loaded) } }

    var body: some View {
        if pager.hasMore, isLoadingAll || isFiltering {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if isLoadingAll {
                    if let total {
                        ProgressView(value: Double(loaded), total: Double(max(total, 1)))
                    } else {
                        ProgressView()
                    }
                }
                HStack {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: Spacing.sm)
                    if isLoadingAll {
                        Button("Stop", action: stop)
                            .font(.footnote)
                    } else if !pager.isPaused {
                        Button("Load All", action: loadAll)
                            .font(.footnote)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
            .listRowSeparator(.hidden)
        }
    }

    private var caption: String {
        let count = total.map { "\(loaded.formatted()) of \($0.formatted())" } ?? "\(loaded.formatted())"
        if pager.isPaused { return "Paused at \(count) \(noun)" }
        if isLoadingAll { return "Loading \(count) \(noun)…" }
        return "Showing matches from \(count) \(noun)"
    }
}

enum TrackColumnsMetrics {
    static let spacing: CGFloat = 12
    static let artwork: CGFloat = 44
    static let number: CGFloat = 28
    static let time: CGFloat = 52
    static let bpm: CGFloat = 44
    static let key: CGFloat = 44
    static let count: CGFloat = 52
    static let date: CGFloat = 96
    static let source: CGFloat = 96
    static let trailing: CGFloat = 44 + Space.tight

    static let phoneColumns: [TrackTableColumn] = [.title, .artist, .album, .time, .bpm, .key]

    @MainActor static func columns(_ layout: TrackColumnLayout) -> [TrackTableColumn] {
        PadLayout.isPad ? layout.enabled : phoneColumns
    }

    static func width(_ column: TrackTableColumn) -> CGFloat? {
        switch column {
        case .title, .artist, .album, .genre: return nil
        case .time: return time
        case .bpm: return bpm
        case .key: return key
        case .energy, .plays, .likes: return count
        case .added, .released: return date
        case .source: return source
        }
    }
}

private struct TrackColumnFrame: ViewModifier {
    let column: TrackTableColumn

    func body(content: Content) -> some View {
        if let width = TrackColumnsMetrics.width(column) {
            content.frame(width: width, alignment: column.isTextColumn ? .leading : .trailing)
        } else {
            content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension TrackTableColumn {
    var isTextColumn: Bool {
        switch self {
        case .title, .artist, .album, .genre, .source: true
        default: false
        }
    }
}

private extension View {
    func trackColumnFrame(_ column: TrackTableColumn) -> some View {
        modifier(TrackColumnFrame(column: column))
    }
}

struct TrackColumnsRowLabel: View {
    let track: Track
    let analysis: TrackAnalysisSummary?
    var number: Int?
    let activity: SCTrackActivity

    @AppStorage(TrackColumnLayout.storageKey) private var layout = TrackColumnLayout.standard

    private var isCurrent: Bool { activity != .none }

    var body: some View {
        HStack(spacing: TrackColumnsMetrics.spacing) {
            leading
            ForEach(TrackColumnsMetrics.columns(layout)) { column in
                cell(column)
                    .trackColumnFrame(column)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .opacity(track.streamURL == nil ? 0.5 : 1)
    }

    @ViewBuilder
    private func cell(_ column: TrackTableColumn) -> some View {
        switch column {
        case .title:
            HStack(spacing: Space.tight) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                SoundCloudTrackBadge(track: track, showsPreview: false)
            }
        case .album:
            Text(TrackValueFormat.album(track) ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
        case .time:
            TrackDurationLabel(track: track)
                .foregroundStyle(.secondary)
        case .bpm, .key:
            TrackAnalysisValueCell(track: track, kind: column == .bpm ? .bpm : .key, summary: analysis)
                .foregroundStyle(.secondary)
        default:
            Text(TrackValueFormat.value(column, track: track, analysis: analysis))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let number {
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: activity == .playing)
                        .foregroundStyle(.tint)
                } else {
                    Text("\(number)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: TrackColumnsMetrics.number, alignment: .center)
        } else {
            ArtworkThumbnail(
                url: track.artworkURL,
                systemImage: "music.note",
                size: TrackColumnsMetrics.artwork,
                cornerRadius: 6,
                identity: track.id
            )
        }
    }
}

struct TrackColumnsHeader: View {
    @Binding var query: TrackCollectionQuery
    var sortKeys: [TrackSortKey] = TrackSortKey.allCases
    var numbered = false
    var dateLabel = "Added"

    @AppStorage(TrackColumnLayout.storageKey) private var layout = TrackColumnLayout.standard

    var body: some View {
        HStack(spacing: TrackColumnsMetrics.spacing) {
            Color.clear
                .frame(width: numbered ? TrackColumnsMetrics.number : TrackColumnsMetrics.artwork, height: 1)
            ForEach(TrackColumnsMetrics.columns(layout)) { column in
                button(column.title(dateLabel: dateLabel), key: column.sortKey)
                    .trackColumnFrame(column)
            }
            Color.clear
                .frame(width: TrackColumnsMetrics.trailing, height: 1)
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort by column")
    }

    @ViewBuilder
    private func button(_ title: String, key: TrackSortKey) -> some View {
        if sortKeys.contains(key) {
            let isActive = query.sortKey == key
            Button {
                withAnimation(.smooth) {
                    if isActive {
                        query.ascending.toggle()
                    } else {
                        query.select(key)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    if isActive {
                        Image(systemName: query.ascending ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(isActive ? Color.scAccent : Color.secondary)
            }
            .accessibilityValue(isActive ? (query.ascending ? "Ascending" : "Descending") : "")
        } else {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.tertiary)
        }
    }
}

extension View {
    func trackListColumns(_ showsColumns: Bool) -> some View {
        environment(\.trackListShowsColumns, showsColumns)
            .environment(\.defaultMinListRowHeight, 52)
    }
}
