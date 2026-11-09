import Foundation
import Combine

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0 {
        didSet { updatedAt = Date() }
    }
    @Published var duration: TimeInterval = 0
    private(set) var updatedAt = Date()

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
}
