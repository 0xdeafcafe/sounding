import SwiftUI
import WidgetKit

struct RecentlyPlayedRow: Identifiable, Equatable {
    var item: SoundingSnapshot.Item
    var position: TimeInterval
    var isContinue: Bool

    var id: String { "\(item.kind.rawValue):\(item.id)" }

    var url: URL {
        SoundingWidgetLink.link(for: item, position: position).url
    }
}

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let rows: [RecentlyPlayedRow]

    static let limit = 6
    static let mediumLimit = 4

    init(date: Date, rows: [RecentlyPlayedRow]) {
        self.date = date
        self.rows = rows
    }

    init(date: Date, snapshot: SoundingSnapshot?) {
        var rows: [RecentlyPlayedRow] = []
        if let target = snapshot?.resumeTarget {
            let nearEnd = (target.item.duration ?? 0) > 0 && target.position >= (target.item.duration ?? 0) - 5
            rows.append(RecentlyPlayedRow(item: target.item, position: nearEnd ? 0 : target.position, isContinue: true))
        }
        for item in snapshot?.recents ?? [] {
            rows.append(RecentlyPlayedRow(item: item, position: 0, isContinue: false))
        }
        var seen = Set<String>()
        self.init(date: date, rows: rows.filter { seen.insert($0.id).inserted }.prefix(Self.limit).map { $0 })
    }

    static func sample(at date: Date = Date()) -> RecentlyPlayedEntry {
        let rows = (1...limit).map { index in
            RecentlyPlayedRow(
                item: SoundingSnapshot.Item(kind: .track, id: "sample-\(index)", title: "Track Title", subtitle: "Artist Name"),
                position: 0,
                isContinue: index == 1
            )
        }
        return RecentlyPlayedEntry(date: date, rows: rows)
    }
}

struct RecentlyPlayedTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        let current = RecentlyPlayedEntry(date: Date(), snapshot: SoundingSnapshotStore.load())
        completion(context.isPreview && current.rows.isEmpty ? .sample() : current)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        let entry = RecentlyPlayedEntry(date: Date(), snapshot: SoundingSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SoundingSurfaceKind.recentlyPlayedWidget, provider: RecentlyPlayedTimelineProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recently Played")
        .description("Pick up where you left off.")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular, .accessoryCircular])
        #endif
    }
}

struct RecentlyPlayedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentlyPlayedEntry

    var body: some View {
        if let first = entry.rows.first {
            switch family {
            #if !os(macOS)
            case .accessoryCircular:
                circular(first)
            case .accessoryRectangular:
                rectangular(first)
            #endif
            case .systemMedium:
                medium
            case .systemLarge:
                list(columns: 1)
            case .systemExtraLarge:
                list(columns: 2)
            default:
                small(first)
            }
        } else {
            empty
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        #if !os(macOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "clock")
                    .accessibilityLabel("No recent music")
            }
        case .accessoryRectangular:
            WidgetEmptyState(symbol: "clock", title: "No Recent Music")
        #endif
        default:
            WidgetEmptyState(symbol: "clock", title: "No Recent Music", detail: "Music you play appears here.")
        }
    }

    #if !os(macOS)
    private func circular(_ row: RecentlyPlayedRow) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            WidgetArtworkView(item: row.item, radius: 100)
                .padding(4)
        }
        .widgetURL(row.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: row))
    }

    private func rectangular(_ row: RecentlyPlayedRow) -> some View {
        HStack(spacing: 8) {
            WidgetArtworkView(item: row.item, radius: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.isContinue ? "Continue" : "Recently Played")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                Text(row.item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(row.item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(row.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: row))
    }
    #endif

    private func small(_ row: RecentlyPlayedRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetArtworkView(item: row.item)
                    .frame(width: 72, height: 72)
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.isContinue ? "Continue" : "Recently Played")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                Text(row.item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(row.item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(row.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: row))
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(entry.rows.prefix(RecentlyPlayedEntry.mediumLimit)) { row in
                Link(destination: row.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        WidgetArtworkView(item: row.item)
                        Text(row.item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(row.item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(label(for: row))
            }
            ForEach(0..<max(0, RecentlyPlayedEntry.mediumLimit - entry.rows.count), id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func list(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(entry.rows) { row in
                Link(destination: row.url) {
                    HStack(spacing: 10) {
                        WidgetArtworkView(item: row.item, radius: 8)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.isContinue ? "Continue" : "Recently Played")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .widgetAccentable()
                            Text(row.item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(row.item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "play.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .widgetAccentable()
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(label(for: row))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func label(for row: RecentlyPlayedRow) -> String {
        let prefix = row.isContinue ? "Continue" : "Play"
        return [prefix, row.item.title, row.item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
