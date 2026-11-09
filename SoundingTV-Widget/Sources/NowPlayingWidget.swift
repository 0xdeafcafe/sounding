import SwiftUI
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let nowPlaying: SoundingSnapshot.NowPlaying?
    let resume: SoundingSnapshot.Resume?

    var item: SoundingSnapshot.Item? {
        nowPlaying?.item ?? resume?.item
    }

    var isPlaying: Bool {
        nowPlaying?.isRunning(at: date) == true
    }

    var relevance: TimelineEntryRelevance? {
        isPlaying ? TimelineEntryRelevance(score: 100, duration: 15 * 60) : nil
    }

    static func sample(at date: Date = Date()) -> NowPlayingEntry {
        let item = SoundingSnapshot.Item(kind: .track, id: "sample", title: "Track Title", subtitle: "Artist Name", duration: 240)
        let nowPlaying = SoundingSnapshot.NowPlaying(
            item: item,
            anchor: SoundingSnapshot.PositionAnchor(position: 90, anchoredAt: date, rate: 0),
            isPlaying: false
        )
        return NowPlayingEntry(date: date, nowPlaying: nowPlaying, resume: nil)
    }
}

struct NowPlayingTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let current = entry(at: Date(), nowPlaying: nil)
        completion(context.isPreview && current.item == nil ? .sample() : current)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let current = entry(at: now, nowPlaying: nil)
        guard let nowPlaying = current.nowPlaying,
              nowPlaying.isPlaying,
              let duration = nowPlaying.duration, duration > 0 else {
            completion(Timeline(entries: [current], policy: .never))
            return
        }
        let end = nowPlaying.anchor.startDate.addingTimeInterval(duration)
        guard end > now else {
            completion(Timeline(entries: [entry(at: now, nowPlaying: nowPlaying.ended(at: now))], policy: .never))
            return
        }
        let finished = entry(at: end, nowPlaying: nowPlaying.ended(at: end))
        completion(Timeline(entries: [current, finished], policy: .never))
    }

    private func entry(at date: Date, nowPlaying override: SoundingSnapshot.NowPlaying?) -> NowPlayingEntry {
        let snapshot = SoundingSnapshotStore.load()
        return NowPlayingEntry(date: date, nowPlaying: override ?? snapshot?.nowPlaying, resume: snapshot?.lastMix)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SoundingSurfaceKind.nowPlayingWidget, provider: NowPlayingTimelineProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Sounding, with play and pause.")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #endif
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        #if !os(macOS)
        case .accessoryInline:
            inline
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        #endif
        case .systemMedium:
            medium
                .widgetURL(link)
        default:
            small
                .widgetURL(link)
        }
    }

    private var link: URL? {
        entry.item == nil ? nil : SoundingWidgetLink.nowPlaying.url
    }

    #if !os(macOS)
    @ViewBuilder
    private var inline: some View {
        if let item = entry.item {
            Label("\(item.title) · \(item.subtitle)", systemImage: entry.isPlaying ? "waveform" : "pause.fill")
        } else {
            Label("Sounding", systemImage: "waveform")
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            progress
                .progressViewStyle(.circular)
            Image(systemName: entry.isPlaying ? "waveform" : "play.fill")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var rectangular: some View {
        if let item = entry.item {
            HStack(spacing: 8) {
                WidgetArtworkView(item: item, radius: 6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    progress
                        .progressViewStyle(.linear)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        } else {
            WidgetEmptyState(symbol: "waveform", title: "Nothing Playing")
        }
    }
    #endif

    @ViewBuilder
    private var small: some View {
        if let item = entry.item {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    WidgetArtworkView(item: item)
                        .frame(width: 56, height: 56)
                    Spacer(minLength: 0)
                    WidgetPlayPauseButton(isPlaying: entry.isPlaying)
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                progress
                    .progressViewStyle(.linear)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WidgetEmptyState(symbol: "waveform", title: "Nothing Playing", detail: "Play something in Sounding.")
        }
    }

    @ViewBuilder
    private var medium: some View {
        if let item = entry.item {
            HStack(spacing: 14) {
                WidgetArtworkView(item: item, radius: 12)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                            .widgetAccentable()
                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
                    Spacer(minLength: 4)
                    progress
                        .progressViewStyle(.linear)
                    HStack(spacing: 0) {
                        WidgetPlayPauseButton(isPlaying: entry.isPlaying)
                        if entry.nowPlaying != nil {
                            WidgetSkipButton()
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            WidgetEmptyState(symbol: "waveform", title: "Nothing Playing", detail: "Play something in Sounding.")
        }
    }

    private var accessibilityLabel: String {
        guard let item = entry.item else { return "Sounding, nothing playing" }
        let state = entry.isPlaying ? "Playing" : "Paused"
        return [item.title, item.subtitle, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private var progress: some View {
        if let nowPlaying = entry.nowPlaying, let duration = nowPlaying.duration, duration > 0 {
            if entry.isPlaying {
                let start = nowPlaying.anchor.startDate
                ProgressView(timerInterval: start...start.addingTimeInterval(duration), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: nowPlaying.progress(at: entry.date))
            }
        } else if let resume = entry.resume, let duration = resume.item.duration, duration > 0 {
            ProgressView(value: min(max(resume.position / duration, 0), 1))
        } else {
            ProgressView(value: 0)
        }
    }
}
