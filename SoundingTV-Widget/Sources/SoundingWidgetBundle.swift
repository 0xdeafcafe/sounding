import SwiftUI
import WidgetKit

@main
struct SoundingWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RecentlyPlayedWidget()
        PlayPauseControl()
        SkipControl()
        ResumeControl()
        #if os(iOS)
        IdentifySongControl()
        NowPlayingLiveActivity()
        TVSignInLiveActivity()
        #endif
    }
}
