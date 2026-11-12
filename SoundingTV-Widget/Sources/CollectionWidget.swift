import AppIntents
import SwiftUI
import WidgetKit

struct CollectionWidgetEntry: TimelineEntry {
    let date: Date
    let collections: [WidgetCollection]
    let selected: WidgetCollection?
    let nowPlaying: SoundingSnapshot.NowPlaying?

    var others: [WidgetCollection] {
        collections.filter { $0.id != selected?.id }
    }

    func isPlaying(_ collection: WidgetCollection) -> Bool {
        collection.isPlaying(in: nowPlaying, at: date)
    }

    var relevance: TimelineEntryRelevance? {
        selected.map { isPlaying($0) } == true ? TimelineEntryRelevance(score: 50, duration: 15 * 60) : nil
    }

    static func sample(at date: Date = Date()) -> CollectionWidgetEntry {
        let collections = [
            WidgetCollection(kind: .playlist, itemID: "sample-1", title: "Playlist Title", subtitle: "Owner Name · 24 tracks"),
            WidgetCollection(kind: .station, itemID: "sample-2", title: "Station Title", subtitle: "Based on Artist Name"),
            WidgetCollection(kind: .setlist, itemID: "sample-3", title: "Setlist Title", subtitle: ""),
            WidgetCollection(kind: .playlist, itemID: "sample-4", title: "Playlist Title", subtitle: "Owner Name · 12 tracks"),
            WidgetCollection(kind: .station, itemID: "sample-5", title: "Station Title", subtitle: "")
        ]
        return CollectionWidgetEntry(date: date, collections: collections, selected: collections.first, nowPlaying: nil)
    }
}

struct CollectionWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CollectionWidgetEntry {
        .sample()
    }

    func snapshot(for configuration: CollectionWidgetIntent, in context: Context) async -> CollectionWidgetEntry {
        let current = entry(at: Date(), configuration: configuration, nowPlaying: nil)
        return context.isPreview && current.collections.isEmpty ? .sample() : current
    }

    func timeline(for configuration: CollectionWidgetIntent, in context: Context) async -> Timeline<CollectionWidgetEntry> {
        let now = Date()
        let current = entry(at: now, configuration: configuration, nowPlaying: nil)
        guard let nowPlaying = current.nowPlaying,
              nowPlaying.isRunning(at: now),
              let duration = nowPlaying.duration, duration > 0 else {
            return Timeline(entries: [current], policy: .never)
        }
        let end = nowPlaying.anchor.startDate.addingTimeInterval(duration)
        guard end > now else {
            return Timeline(entries: [entry(at: now, configuration: configuration, nowPlaying: nowPlaying.ended(at: now))], policy: .never)
        }
        let finished = entry(at: end, configuration: configuration, nowPlaying: nowPlaying.ended(at: end))
        return Timeline(entries: [current, finished], policy: .never)
    }

    private func entry(at date: Date, configuration: CollectionWidgetIntent, nowPlaying override: SoundingSnapshot.NowPlaying?) -> CollectionWidgetEntry {
        let collections = WidgetCollectionStore.load()
        let selected = collections.first { $0.id == configuration.collection?.id } ?? collections.first
        let nowPlaying = override ?? SoundingSnapshotStore.load()?.nowPlaying
        return CollectionWidgetEntry(date: date, collections: collections, selected: selected, nowPlaying: nowPlaying)
    }
}

struct CollectionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SoundingSurfaceKind.collectionWidget, intent: CollectionWidgetIntent.self, provider: CollectionWidgetProvider()) { entry in
            CollectionWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Play")
        .description("Start a playlist, setlist or station.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct CollectionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CollectionWidgetEntry

    var body: some View {
        if let selected = entry.selected {
            switch family {
            case .systemMedium:
                medium(selected)
            case .systemLarge:
                large(selected)
            case .systemExtraLarge:
                extraLarge(selected)
            default:
                small(selected)
            }
        } else {
            WidgetEmptyState(
                symbol: "music.note.list",
                title: "Nothing to Play",
                detail: "Your playlists, setlists and stations appear here."
            )
        }
    }

    private func small(_ collection: WidgetCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CollectionArtwork(collection: collection)
                    .frame(width: 56, height: 56)
                Spacer(minLength: 0)
                CollectionPlayButton(collection: collection, isPlaying: entry.isPlaying(collection))
            }
            Spacer(minLength: 6)
            CollectionTitles(collection: collection, isPlaying: entry.isPlaying(collection), lines: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ collection: WidgetCollection) -> some View {
        HStack(spacing: 14) {
            CollectionArtwork(collection: collection, radius: 12)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                CollectionTitles(collection: collection, isPlaying: entry.isPlaying(collection), lines: 2)
                Spacer(minLength: 4)
                CollectionActions(collection: collection, isPlaying: entry.isPlaying(collection))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ collection: WidgetCollection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            hero(collection, side: 112)
            CollectionList(entries: Array(entry.others.prefix(4)), entry: entry)
        }
    }

    private func extraLarge(_ collection: WidgetCollection) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                CollectionArtwork(collection: collection, radius: 14)
                    .frame(maxHeight: .infinity)
                CollectionTitles(collection: collection, isPlaying: entry.isPlaying(collection), lines: 2)
                CollectionActions(collection: collection, isPlaying: entry.isPlaying(collection))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CollectionList(entries: Array(entry.others.prefix(6)), entry: entry)
                .frame(maxWidth: .infinity)
        }
    }

    private func hero(_ collection: WidgetCollection, side: CGFloat) -> some View {
        HStack(spacing: 14) {
            CollectionArtwork(collection: collection, radius: 12)
                .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 4) {
                CollectionTitles(collection: collection, isPlaying: entry.isPlaying(collection), lines: 2)
                Spacer(minLength: 4)
                CollectionActions(collection: collection, isPlaying: entry.isPlaying(collection))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: side)
    }
}

struct CollectionArtwork: View {
    let collection: WidgetCollection
    var radius: CGFloat = 10

    var body: some View {
        WidgetArtworkView(item: collection.artworkItem, radius: radius, fallbackSymbol: collection.fallbackSymbol)
    }
}

struct CollectionTitles: View {
    let collection: WidgetCollection
    let isPlaying: Bool
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isPlaying ? "Playing" : collection.kind.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(collection.title)
                .font(.headline)
                .lineLimit(lines)
            if !collection.subtitle.isEmpty {
                Text(collection.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CollectionIntentButton<Label: View>: View {
    let collection: WidgetCollection
    let isPlaying: Bool
    var shuffle = false
    @ViewBuilder let label: Label

    var body: some View {
        if isPlaying {
            Button(intent: SetPlaybackIntent(playing: false)) { label }
        } else {
            Button(intent: PlayWidgetCollectionIntent(collection, shuffle: shuffle)) { label }
        }
    }
}

struct CollectionPlayButton: View {
    let collection: WidgetCollection
    let isPlaying: Bool

    var body: some View {
        CollectionIntentButton(collection: collection, isPlaying: isPlaying) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play \(collection.title)")
    }
}

struct CollectionActions: View {
    let collection: WidgetCollection
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            CollectionIntentButton(collection: collection, isPlaying: isPlaying) {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(.fill.secondary, in: Capsule())
                    .contentShape(Capsule())
                    .widgetAccentable()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play \(collection.title)")
            if collection.canShuffle && !isPlaying {
                CollectionIntentButton(collection: collection, isPlaying: false, shuffle: true) {
                    Image(systemName: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.fill.secondary, in: Circle())
                        .contentShape(Circle())
                        .widgetAccentable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle \(collection.title)")
            }
            Spacer(minLength: 0)
        }
    }
}

struct CollectionList: View {
    let entries: [WidgetCollection]
    let entry: CollectionWidgetEntry

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { collection in
                if collection.id != entries.first?.id {
                    Divider()
                }
                CollectionRow(collection: collection, isPlaying: entry.isPlaying(collection))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct CollectionRow: View {
    let collection: WidgetCollection
    let isPlaying: Bool

    var body: some View {
        CollectionIntentButton(collection: collection, isPlaying: isPlaying) {
            HStack(spacing: 10) {
                CollectionArtwork(collection: collection, radius: 6)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(isPlaying ? "Playing" : collection.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause \(collection.title)" : "Play \(collection.title)")
    }
}
