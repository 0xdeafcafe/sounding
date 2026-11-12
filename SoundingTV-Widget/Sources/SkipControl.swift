import AppIntents
import SwiftUI
import WidgetKit

struct SkipControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SoundingSurfaceKind.skipControl) {
            ControlWidgetButton(action: SkipTrackIntent()) {
                Label("Next Track", systemImage: "forward.fill")
            }
        }
        .displayName("Next Track")
        .description("Skips to the next track in Sounding.")
    }
}
