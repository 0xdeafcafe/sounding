import Foundation

enum PlaybackLoadingState: Equatable {
    case idle
    case resolvingStream
    case buffering
    case playing
}
