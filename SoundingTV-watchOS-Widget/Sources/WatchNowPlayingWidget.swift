import AppIntents
import SwiftUI
import WidgetKit

struct WatchNowPlayingEntry: TimelineEntry {
    let date: Date
    let nowPlaying: SoundingSnapshot.NowPlaying?
    let resume: SoundingSnapshot.Resume?

    var item: SoundingSnapshot.Item? {
        nowPlaying?.item ?? resume?.item
    }

    var isPlaying: Bool {
        nowPlaying?.isRunning(at: date) == true
    }

    static func sample(at date: Date = Date()) -> WatchNowPlayingEntry {
        let item = SoundingSnapshot.Item(kind: .track, id: "sample", title: "Track Title", subtitle: "Artist Name", duration: 240)
        let nowPlaying = SoundingSnapshot.NowPlaying(
            item: item,
            anchor: SoundingSnapshot.PositionAnchor(position: 90, anchoredAt: date, rate: 0),
            isPlaying: false
        )
        return WatchNowPlayingEntry(date: date, nowPlaying: nowPlaying, resume: nil)
    }

    var relevance: TimelineEntryRelevance? {
        if isPlaying { return TimelineEntryRelevance(score: 100, duration: 15 * 60) }
        if nowPlaying != nil { return TimelineEntryRelevance(score: 30, duration: 30 * 60) }
        return TimelineEntryRelevance(score: 0)
    }
}

struct WatchNowPlayingTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchNowPlayingEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchNowPlayingEntry) -> Void) {
        let current = entry(at: Date(), nowPlaying: nil)
        completion(context.isPreview && current.item == nil ? .sample() : current)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchNowPlayingEntry>) -> Void) {
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

    private func entry(at date: Date, nowPlaying override: SoundingSnapshot.NowPlaying?) -> WatchNowPlayingEntry {
        let snapshot = SoundingSnapshotStore.load()
        return WatchNowPlayingEntry(date: date, nowPlaying: override ?? snapshot?.nowPlaying, resume: snapshot?.lastMix)
    }
}

struct WatchNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SoundingSurfaceKind.watchNowPlayingWidget, provider: WatchNowPlayingTimelineProvider()) { entry in
            WatchNowPlayingWidgetContainer(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing, with play and pause.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct WatchNowPlayingWidgetContainer: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchNowPlayingEntry

    var body: some View {
        WatchNowPlayingWidgetView(entry: entry, family: family)
    }
}

struct WatchNowPlayingWidgetView: View {
    let entry: WatchNowPlayingEntry
    let family: WidgetFamily

    private var title: String {
        entry.item?.title ?? "Nothing Playing"
    }

    private var artist: String {
        entry.item?.subtitle ?? "Sounding"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let item = entry.item {
                Label("\(item.title) · \(item.subtitle)", systemImage: entry.isPlaying ? "waveform" : "pause.fill")
            } else {
                Label("Sounding", systemImage: "waveform")
            }
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            corner
        default:
            rectangular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            progress
                .progressViewStyle(.circular)
            playPause
                .font(.title3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var corner: some View {
        playPause
            .font(.title3)
            .widgetLabel {
                Text(entry.item?.title ?? "Sounding")
            }
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var rectangular: some View {
        if entry.item == nil {
            VStack(spacing: 2) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                    .accessibilityHidden(true)
                Text("Nothing Playing")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            nowPlayingRow
        }
    }

    private var nowPlayingRow: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                progress
                    .progressViewStyle(.linear)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            playPause
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.fill.tertiary, in: Circle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var playPause: some View {
        if entry.item != nil {
            Button(intent: SetPlaybackIntent(playing: !entry.isPlaying)) {
                Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isPlaying ? "Pause" : "Play")
        } else {
            Image(systemName: "waveform")
                .accessibilityHidden(true)
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
            if nowPlaying.isPlaying {
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
