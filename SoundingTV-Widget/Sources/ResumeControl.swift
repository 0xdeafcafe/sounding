import AppIntents
import SwiftUI
import WidgetKit

struct ResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SoundingSurfaceKind.resumeControl) {
            ControlWidgetButton(action: ResumeLastSessionIntent()) {
                Label("Resume", systemImage: "play.circle.fill")
            }
        }
        .displayName("Resume")
        .description("Resumes your last session in Sounding.")
    }
}
