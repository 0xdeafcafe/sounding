import AppIntents
import SwiftUI
import WidgetKit

struct IdentifySongControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SoundingSurfaceKind.identifySongControl) {
            ControlWidgetButton(action: IdentifySongIntent()) {
                Label("Identify Song", systemImage: "shazam.logo.fill")
            }
        }
        .displayName("Identify Song")
        .description("Names the song playing around you.")
    }
}
