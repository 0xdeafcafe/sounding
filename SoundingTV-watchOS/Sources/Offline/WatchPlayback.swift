import Combine
import Foundation

@MainActor
final class WatchPlayback: ObservableObject {
    static let shared = WatchPlayback()

    enum Route: String {
        case phone
        case watch
    }

    @Published private(set) var route: Route = .phone

    private let link = WatchLinkClient.shared
    private let local = WatchLocalPlayer.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        link.objectWillChange
            .merge(with: local.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isLocal: Bool { route == .watch }

    nonisolated static func detailsTrackID(_ trackID: String?) -> String? {
        guard let trackID, !LocalTrackFile.isLocalTrackID(trackID) else { return nil }
        return trackID
    }

    var nowPlaying: WatchNowPlaying { isLocal ? local.nowPlaying : link.nowPlaying }

    var receivedAt: Date { isLocal ? local.anchoredAt : link.nowPlayingReceivedAt }

    var volume: Double? { isLocal ? local.volume : link.volume }

    var isControllable: Bool { isLocal || link.isReachable }

    func transport(_ action: WatchTransportAction) {
        guard isLocal else {
            link.transport(action)
            return
        }
        switch action {
        case .play: local.play()
        case .pause: local.pause()
        case .toggle: local.toggle()
        case .next: local.next()
        case .previous: local.previous()
        }
    }

    func seek(to seconds: TimeInterval) {
        if isLocal {
            local.seek(to: seconds)
        } else {
            link.seek(to: seconds)
        }
    }

    func setVolume(_ value: Double) {
        if isLocal {
            local.setVolume(value)
        } else {
            link.setVolume(value)
        }
    }

    func play(_ tracks: [WatchOfflineTrack], startAt start: Int = 0, title: String? = nil) {
        if !isLocal, link.nowPlaying.isPlaying { link.transport(.pause) }
        route = .watch
        Task { await local.play(tracks, startAt: start, title: title) }
    }

    func playShuffled(_ tracks: [WatchOfflineTrack], title: String? = nil) {
        play(tracks.shuffled(), title: title)
    }

    func switchTo(_ next: Route) {
        guard next != route else { return }
        switch next {
        case .watch:
            let phone = link.nowPlaying
            let store = WatchOfflineStore.shared
            if let trackId = phone.trackId, let track = store.tracks[trackId] {
                let queued = link.queue.items.compactMap { store.tracks[$0.trackId] }.filter { $0.id != track.id }
                let position = phone.projectedPosition(at: Date(), since: link.nowPlayingReceivedAt)
                let wasPlaying = phone.isPlaying
                if wasPlaying { link.transport(.pause) }
                route = .watch
                let title = link.queue.sourceTitle
                Task {
                    await local.play([track] + queued, startAt: 0, position: position, title: title, autoplay: wasPlaying)
                }
            } else {
                if phone.isPlaying { link.transport(.pause) }
                route = .watch
            }
        case .phone:
            let current = local.current
            let wasPlaying = local.isPlaying
            local.pause()
            route = .phone
            if wasPlaying, let current, current.source == .soundCloud, link.isReachable {
                link.play(trackId: current.id)
            }
        }
    }

    func phoneWillPlay() {
        guard isLocal else { return }
        local.pause()
        route = .phone
    }
}
