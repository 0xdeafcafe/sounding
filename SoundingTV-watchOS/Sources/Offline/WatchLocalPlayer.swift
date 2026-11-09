import AVFoundation
import Combine
import Foundation
import MediaPlayer
import os

@MainActor
final class WatchLocalPlayer: ObservableObject {
    static let shared = WatchLocalPlayer()

    @Published private(set) var queue: [WatchOfflineTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var anchorPosition: TimeInterval = 0
    @Published private(set) var anchoredAt = Date()
    @Published private(set) var volume: Double = 1
    @Published private(set) var sourceTitle: String?
    @Published private(set) var routeName: String?
    @Published private(set) var isActivating = false

    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var commandsInstalled = false
    private var isSessionActive = false
    private var heard: TimeInterval = 0
    private var audibleSince: Date?
    private var isCounted = false
    private var countTask: Task<Void, Never>?
    private var lastCounted: [String: Date] = [:]

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        interruptionObserver = Self.observeInterruptions()
    }

    var current: WatchOfflineTrack? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var hasItem: Bool { current != nil }

    var upNext: [WatchOfflineTrack] {
        guard queue.indices.contains(index + 1) else { return [] }
        return Array(queue[(index + 1)...])
    }

    var nowPlaying: WatchNowPlaying {
        guard let current else {
            var idle = WatchNowPlaying.idle
            idle.output = .watch
            idle.outputId = WatchOutputOption.thisWatchID
            idle.outputName = "This Watch"
            return idle
        }
        return WatchNowPlaying(
            trackId: current.id,
            title: current.title,
            artist: current.artist,
            artworkURL: current.artworkURL,
            isPlaying: isPlaying,
            positionSeconds: anchorPosition,
            durationSeconds: duration,
            output: .watch,
            queueCount: max(0, queue.count - index - 1),
            updatedAtMillis: Int64(anchoredAt.timeIntervalSince1970 * 1000),
            outputId: WatchOutputOption.thisWatchID,
            outputName: "This Watch",
            outputs: nil,
            volume: volume
        )
    }

    private var duration: TimeInterval {
        let measured = player.currentItem?.duration.seconds ?? .nan
        if measured.isFinite, measured > 0 { return measured }
        return current?.durationSeconds ?? 0
    }

    func play(_ tracks: [WatchOfflineTrack], startAt start: Int = 0, position: TimeInterval = 0, title: String? = nil, autoplay: Bool = true) async {
        let store = WatchOfflineStore.shared
        store.enforceExpiry()
        let playable = tracks.filter { store.fileURL(for: $0) != nil }
        guard !playable.isEmpty else { return }
        let startID = tracks.indices.contains(start) ? tracks[start].id : nil
        closePlay()
        queue = playable
        index = playable.firstIndex { $0.id == startID } ?? 0
        sourceTitle = title
        guard autoplay, await activateIfNeeded() else {
            player.pause()
            isPlaying = false
            load(at: index, position: position)
            publishNowPlayingInfo()
            return
        }
        load(at: index, position: position)
        resume()
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard hasItem else { return }
        Task {
            guard await activateIfNeeded() else { return }
            if player.currentItem == nil { load(at: index, position: anchorPosition) }
            resume()
        }
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        reanchor()
        noteAudible(false)
        publishNowPlayingInfo()
    }

    func next() {
        guard queue.indices.contains(index + 1) else {
            pause()
            seek(to: 0)
            return
        }
        closePlay()
        index += 1
        load(at: index, position: 0)
        if isPlaying { player.play() }
        reanchor()
        noteAudible(isPlaying)
        publishNowPlayingInfo()
    }

    func previous() {
        if currentPosition() > 3 || index == 0 {
            seek(to: 0)
            return
        }
        closePlay()
        index -= 1
        load(at: index, position: 0)
        if isPlaying { player.play() }
        reanchor()
        noteAudible(isPlaying)
        publishNowPlayingInfo()
    }

    func jump(to trackID: String) {
        guard let target = queue.firstIndex(where: { $0.id == trackID }) else { return }
        closePlay()
        index = target
        load(at: index, position: 0)
        play()
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        anchorPosition = clamped
        anchoredAt = Date()
        publishNowPlayingInfo()
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        volume = clamped
        player.volume = Float(clamped)
    }

    func stop() {
        closePlay()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        queue = []
        index = 0
        anchorPosition = 0
        anchoredAt = Date()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func itemDidEnd() {
        closePlay()
        guard queue.indices.contains(index + 1) else {
            isPlaying = false
            index = 0
            load(at: index, position: 0)
            reanchor()
            publishNowPlayingInfo()
            return
        }
        index += 1
        load(at: index, position: 0)
        player.play()
        reanchor()
        noteAudible(true)
        publishNowPlayingInfo()
    }

    func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            if isPlaying { pause() }
        } else if shouldResume, hasItem {
            play()
        }
    }

    private func resume() {
        installRemoteCommandsIfNeeded()
        player.play()
        isPlaying = true
        anchoredAt = Date()
        noteAudible(true)
        publishNowPlayingInfo()
    }

    private func load(at target: Int, position seconds: TimeInterval) {
        guard queue.indices.contains(target),
              let url = WatchOfflineStore.shared.fileURL(for: queue[target]) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = Self.observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        anchorPosition = seconds
        anchoredAt = Date()
        heard = 0
        audibleSince = nil
        isCounted = false
    }

    private func currentPosition() -> TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : anchorPosition
    }

    private func reanchor() {
        anchorPosition = currentPosition()
        anchoredAt = Date()
    }

    private func activateIfNeeded() async -> Bool {
        if isSessionActive { return true }
        isActivating = true
        let activated = await Self.activateSession()
        isActivating = false
        isSessionActive = activated
        routeName = activated ? Self.currentRouteName() : nil
        if !activated { Log.player.info("[WatchPlayer] audio route not chosen") }
        return activated
    }

    private func publishNowPlayingInfo() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: anchorPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = current.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        WatchSnapshotWriter.shared.record(nowPlaying, receivedAt: anchoredAt)
    }

    private func installRemoteCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        Self.installRemoteCommands()
    }

    private func noteAudible(_ audible: Bool) {
        let now = Date()
        if let since = audibleSince {
            heard += max(0, now.timeIntervalSince(since))
        }
        audibleSince = audible ? now : nil
        countTask?.cancel()
        countTask = nil
        evaluatePlay()
        guard audible, !isCounted, let current else { return }
        let wait = max(0.5, PlayQualification.threshold(duration: current.durationSeconds) - heard)
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.noteAudible(self.isPlaying)
        }
    }

    private func closePlay() {
        countTask?.cancel()
        countTask = nil
        if let since = audibleSince {
            heard += max(0, Date().timeIntervalSince(since))
            audibleSince = nil
        }
        evaluatePlay()
    }

    private func evaluatePlay() {
        guard !isCounted, let current,
              heard >= PlayQualification.threshold(duration: current.durationSeconds) else { return }
        isCounted = true
        let now = Date()
        lastCounted = lastCounted.filter { now.timeIntervalSince($0.value) < 3600 }
        guard !PlayQualification.isRepeat(of: lastCounted[current.id], at: now, duration: current.durationSeconds) else { return }
        lastCounted[current.id] = now
        WatchLinkClient.shared.sendPlayReport(
            WatchPlayReport(
                trackID: current.id,
                playedAtMillis: RecentPlay.millis(now),
                title: current.title,
                artist: current.artist,
                durationSeconds: current.durationSeconds,
                isLocal: current.source == .file
            )
        )
    }

    private nonisolated static func activateSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            return false
        }
        return await withCheckedContinuation { continuation in
            session.activate(options: []) { activated, error in
                continuation.resume(returning: activated && error == nil)
            }
        }
    }

    private nonisolated static func currentRouteName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }

    private nonisolated static func observeEnd(of item: AVPlayerItem) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in WatchLocalPlayer.shared.itemDidEnd() }
        }
    }

    private nonisolated static func observeInterruptions() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let began = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            Task { @MainActor in
                WatchLocalPlayer.shared.handleInterruption(began: began, shouldResume: shouldResume)
            }
        }
    }

    private nonisolated static func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        _ = center.playCommand.addTarget { _ in
            Task { @MainActor in WatchLocalPlayer.shared.play() }
            return .success
        }
        _ = center.pauseCommand.addTarget { _ in
            Task { @MainActor in WatchLocalPlayer.shared.pause() }
            return .success
        }
        _ = center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in WatchLocalPlayer.shared.toggle() }
            return .success
        }
        _ = center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in WatchLocalPlayer.shared.next() }
            return .success
        }
        _ = center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in WatchLocalPlayer.shared.previous() }
            return .success
        }
        _ = center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in WatchLocalPlayer.shared.seek(to: position) }
            return .success
        }
    }
}
