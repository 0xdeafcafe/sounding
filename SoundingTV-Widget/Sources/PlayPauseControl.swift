import AppIntents
import SwiftUI
import WidgetKit

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SoundingSurfaceKind.playPauseControl, provider: Provider()) { value in
            ControlWidgetToggle(isOn: value.isPlaying, action: SetPlaybackIntent()) {
                Label(value.title ?? "Sounding", systemImage: "waveform")
            } valueLabel: { isOn in
                Label(isOn ? "Playing" : "Paused", systemImage: isOn ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses Sounding.")
    }

    struct Value {
        var isPlaying: Bool
        var title: String?
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value {
            Value(isPlaying: false, title: nil)
        }

        func currentValue() async throws -> Value {
            let snapshot = SoundingSnapshotStore.load()
            let item = snapshot?.nowPlaying?.item ?? snapshot?.lastMix?.item
            return Value(isPlaying: snapshot?.nowPlaying?.isRunning(at: Date()) ?? false, title: item?.title)
        }
    }
}
