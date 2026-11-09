import SwiftUI
import WidgetKit

@main
struct SoundingWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchNowPlayingWidget()
        PlayPauseControl()
    }
}
