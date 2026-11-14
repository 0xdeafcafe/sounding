import AppIntents
import SwiftUI
import WidgetKit

struct OpenRemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SoundingSurfaceKind.openRemoteControl) {
            ControlWidgetButton(action: OpenRemoteIntent()) {
                Label("Remote", systemImage: RemoteRequest.tabSymbol)
            }
        }
        .displayName("Sounding Remote")
        .description("Opens the Remote for your Apple TV.")
    }
}
