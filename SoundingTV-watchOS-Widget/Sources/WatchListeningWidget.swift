import AppIntents
import RelevanceKit
import SwiftUI
import WidgetKit

struct WatchListeningIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Listening"
    static let description = IntentDescription("Now Playing, shown when you start listening.")

    init() {}
}

struct WatchListeningProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<WatchListeningIntent> {
        let configuration = WatchListeningIntent()
        var attributes: [WidgetRelevanceAttribute<WatchListeningIntent>] = [
            WidgetRelevanceAttribute(configuration: configuration, context: .hardware(headphones: .connected)),
            WidgetRelevanceAttribute(configuration: configuration, context: .fitness(.workoutActive))
        ]
        if let window = Self.playingWindow() {
            attributes.append(WidgetRelevanceAttribute(configuration: configuration, context: .date(interval: window, kind: .default)))
        }
        return WidgetRelevance(attributes)
    }

    func entry(configuration: WatchListeningIntent, context: Context) async throws -> WatchNowPlayingEntry {
        let now = Date()
        let snapshot = SoundingSnapshotStore.load()
        var nowPlaying = snapshot?.nowPlaying
        if let current = nowPlaying, current.isPlaying, !current.isRunning(at: now) {
            nowPlaying = current.ended(at: now)
        }
        return WatchNowPlayingEntry(date: now, nowPlaying: nowPlaying, resume: snapshot?.lastMix)
    }

    func placeholder(context: Context) -> WatchNowPlayingEntry {
        .sample()
    }

    private static func playingWindow() -> DateInterval? {
        let now = Date()
        guard let nowPlaying = SoundingSnapshotStore.load()?.nowPlaying,
              nowPlaying.isRunning(at: now),
              let duration = nowPlaying.duration, duration > 0 else { return nil }
        let end = nowPlaying.anchor.startDate.addingTimeInterval(duration)
        guard end > now else { return nil }
        return DateInterval(start: now, end: end)
    }
}

struct WatchListeningWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: SoundingSurfaceKind.watchListeningWidget, provider: WatchListeningProvider()) { entry in
            WatchNowPlayingWidgetContainer(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Listening")
        .description("Now Playing, shown when headphones connect or a workout starts.")
        .supportedFamilies([.accessoryRectangular])
    }
}
