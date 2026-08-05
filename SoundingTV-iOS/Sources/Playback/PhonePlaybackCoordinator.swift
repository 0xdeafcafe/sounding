import Combine
import Foundation
import SwiftUI
import UIKit
import os

@MainActor
final class PhonePlaybackCoordinator: ObservableObject {
    private let player = PlayerService.shared
    private let client: CompanionClient
    private var cancellables = Set<AnyCancellable>()
    private var liveActivityUpdateTask: Task<Void, Never>?
    private var liveActivityUpdatePending = false
    private var liveActivityEnrichmentTask: Task<Void, Never>?
    private var liveActivityEnrichmentTrackID: String?
    private var lastLiveActivityUpdate = Date.distantPast
    private var lastLiveActivityState: NowPlayingActivityAttributes.ContentState?
    private var accentCache: [String: String] = [:]
    private var waveformBarCache: [String: String] = [:]
    private var presentationRefreshTask: Task<Void, Never>?
    private var lastPresentation: PresentationFingerprint?

    /// The phone shell is installed above every tab, so it must not mirror the
    /// player's clock ticks into an app-wide SwiftUI invalidation. The visible
    /// transport already interpolates its own clock between discrete snapshots.
    private struct PresentationFingerprint: Equatable {
        let source: PlaybackOutput
        let trackID: String?
        let title: String?
        let artist: String?
        let artworkURL: String?
        let duration: TimeInterval
        let isPlaying: Bool
        let isLoading: Bool
        let isDJEngineLive: Bool
        let isAppleTVAvailable: Bool
    }

    init(client: CompanionClient) {
        self.client = client

        player.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
                self?.scheduleLiveActivityUpdate()
            }
            .store(in: &cancellables)
        client.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
                self?.scheduleLiveActivityUpdate()
            }
            .store(in: &cancellables)

        lastPresentation = presentationFingerprint()
        scheduleLiveActivityUpdate()
    }

    var activeSource: PlaybackOutput {
        if let forced = Self.debugFakeNowPlayingSource { return forced }
        if player.outputTarget == .companion(.tv) { return .companion(.tv) }
        if player.currentTrack != nil { return .thisDevice }
        if client.playback?.trackId != nil { return .companion(.tv) }
        return .thisDevice
    }

    var isAppleTVAvailable: Bool { client.isReachable }

    var isPlayingOnAppleTV: Bool { activeSource == .companion(.tv) }

    var nowPlaying: NowPlayingSnapshot? {
        if let fake = Self.debugFakeNowPlayingSnapshot { return fake }
        switch activeSource {
        case .thisDevice:
            guard let track = player.currentTrack else { return nil }
            return NowPlayingSnapshot(
                source: .thisDevice,
                trackId: track.id,
                title: track.title,
                artist: track.user.displayName,
                artworkURL: track.artworkURL?.absoluteString,
                position: player.currentTime,
                duration: player.duration > 0 ? player.duration : track.duration,
                isPlaying: player.isPlaying,
                isLoading: player.loadingState != .playing && player.loadingState != .idle,
                isDJEngineLive: player.isMixEngineLive
            )
        case .companion:
            guard let playback = client.playback, playback.trackId != nil else { return nil }
            return NowPlayingSnapshot(
                source: .companion(.tv),
                trackId: playback.trackId,
                title: playback.title,
                artist: playback.artist,
                artworkURL: playback.artworkURL,
                position: playback.positionSeconds,
                duration: playback.durationSeconds,
                isPlaying: client.state == .connected && playback.isPlaying,
                isLoading: false,
                isDJEngineLive: playback.isDJEngineLive
            )
        }
    }

    /// Object publishers fire before their backing property is changed. Delay
    /// one turn, coalesce bursts, and notify SwiftUI only for data a shell can
    /// actually display (not playback position or remote telemetry revisions).
    private func schedulePresentationRefresh() {
        guard presentationRefreshTask == nil else { return }
        presentationRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.presentationRefreshTask = nil
            let next = self.presentationFingerprint()
            guard next != self.lastPresentation else { return }
            self.lastPresentation = next
            self.objectWillChange.send()
        }
    }

    private func presentationFingerprint() -> PresentationFingerprint {
        let snapshot = nowPlaying
        return PresentationFingerprint(
            source: activeSource,
            trackID: snapshot?.trackId,
            title: snapshot?.title,
            artist: snapshot?.artist,
            artworkURL: snapshot?.artworkURL,
            duration: snapshot?.duration ?? 0,
            isPlaying: snapshot?.isPlaying ?? false,
            isLoading: snapshot?.isLoading ?? false,
            isDJEngineLive: snapshot?.isDJEngineLive ?? false,
            isAppleTVAvailable: isAppleTVAvailable
        )
    }

    /// A single activity follows whichever output currently owns playback.
    /// Player and Bonjour publishers can be noisy, so updates are coalesced to
    /// roughly once a second instead of waking ActivityKit for every time tick.
    private func scheduleLiveActivityUpdate() {
        liveActivityUpdatePending = true
        guard liveActivityUpdateTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastLiveActivityUpdate)
        let delay = max(0.12, 1.0 - elapsed)

        liveActivityUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            while self.liveActivityUpdatePending, !Task.isCancelled {
                self.liveActivityUpdatePending = false
                self.lastLiveActivityUpdate = Date()
                await self.syncLiveActivity()
            }
            self.liveActivityUpdateTask = nil

            // A publisher can fire between the loop condition and clearing the
            // task. Re-arm here so that edge cannot strand the newest state.
            if self.liveActivityUpdatePending {
                self.scheduleLiveActivityUpdate()
            }
        }
    }

    private static func liveActivitySource(for output: PlaybackOutput) -> NowPlayingActivityAttributes.PlaybackSource {
        switch output {
        case .thisDevice:
            return .local
        case .companion(let deviceClass):
            switch deviceClass {
            case .tv: return .appleTV
            case .mac: return .mac
            default: return .unknown
            }
        }
    }

    private func syncLiveActivity() async {
        guard let snapshot = nowPlaying, snapshot.trackId != nil else {
            guard lastLiveActivityState != nil || NowPlayingLiveActivity.currentContentState != nil else { return }
            lastLiveActivityState = nil
            await NowPlayingLiveActivity.end()
            return
        }

        let controlsPairedDevice = snapshot.source.isCompanion
        let artworkFileName = SharedArtworkStore.fileName(for: snapshot.artworkURL)

        let state = NowPlayingActivityAttributes.ContentState(
            trackTitle: snapshot.displayTitle,
            artistName: snapshot.displayArtist,
            artworkURLString: snapshot.artworkURL,
            isPlaying: snapshot.isPlaying,
            position: snapshot.position,
            duration: snapshot.duration,
            isDJModeLive: snapshot.isDJEngineLive,
            playbackSource: Self.liveActivitySource(for: snapshot.source),
            outputName: snapshot.source.displayName,
            controlsPairedDevice: controlsPairedDevice,
            startedAt: snapshot.isPlaying
                ? Date().addingTimeInterval(-snapshot.position)
                : nil,
            artworkFileName: artworkFileName,
            accentHex: artworkFileName
                .flatMap { accentCache[$0] }
                .flatMap { $0.isEmpty ? nil : $0 },
            waveformBars: snapshot.trackId.flatMap { waveformBarCache[$0] },
            mixPointSeconds: Self.debugFakeNowPlayingSource != nil
                ? snapshot.duration * 0.82
                : player.plannedMixPointSeconds()
        )
        guard state.differsMeaningfully(from: lastLiveActivityState) else { return }
        lastLiveActivityState = state

        await NowPlayingLiveActivity.start(
            sessionId: controlsPairedDevice ? (client.linkSessionId ?? "paired-apple-tv") : "local-iphone",
            state: state
        )

        prepareLiveActivityAssets(for: snapshot, artworkFileName: artworkFileName)
    }

    /// Artwork and waveform work is deliberately downstream of the state
    /// update. A slow network response or analysis lookup must never delay a
    /// play/pause/seek/track transition, and an old track's work is cancelled
    /// before it can overwrite the current activity.
    private func prepareLiveActivityAssets(
        for snapshot: NowPlayingSnapshot,
        artworkFileName: String?
    ) {
        guard let trackID = snapshot.trackId else { return }
        let needsArtwork = artworkFileName.map { accentCache[$0] == nil } ?? false
        let needsWaveform = waveformBarCache[trackID] == nil
        guard needsArtwork || needsWaveform else { return }

        if liveActivityEnrichmentTrackID != trackID {
            liveActivityEnrichmentTask?.cancel()
        } else if liveActivityEnrichmentTask != nil {
            return
        }
        liveActivityEnrichmentTrackID = trackID

        liveActivityEnrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if needsArtwork, let artworkFileName {
                await self.cacheArtworkIfNeeded(
                    urlString: snapshot.artworkURL,
                    fileName: artworkFileName
                )
                guard !Task.isCancelled else { return }
                self.accentCache[artworkFileName] =
                    Self.accentHex(forArtworkNamed: artworkFileName) ?? ""
            }

            if needsWaveform {
                var encoded = ""
                if Self.debugFakeNowPlayingSource != nil {
                    encoded = Self.debugWaveformBars()
                } else if let track = self.player.currentTrack, track.id == trackID,
                          case .success(let waveform) = await WaveformService.shared.waveform(for: track) {
                    encoded = Self.encodeBars(waveform.resampled(to: 48))
                }
                guard !Task.isCancelled else { return }
                self.waveformBarCache[trackID] = encoded
            }

            guard self.nowPlaying?.trackId == trackID else { return }
            self.liveActivityEnrichmentTask = nil
            self.scheduleLiveActivityUpdate()
        }
    }

    private func cacheArtworkIfNeeded(urlString: String?, fileName: String?) async {
        guard let urlString,
              let fileName,
              let url = URL(string: urlString),
              !SharedArtworkStore.hasCachedArtwork(fileName: fileName)
        else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            SharedArtworkStore.store(data, fileName: fileName)
            SharedArtworkStore.prune(keeping: [fileName])
        } catch {
            Log.player.debug("[LiveActivity] Artwork cache failed: \(error, privacy: .public)")
        }
    }

    private static func debugWaveformBars() -> String {
        #if DEBUG
        let levels: [Float] = (0..<48).map { index in
            let position = Double(index) / 47
            let build = 0.35 + 0.5 * sin(position * .pi)
            let beat = 0.18 * sin(position * 34)
            let drop = position > 0.42 && position < 0.78 ? 0.22 : 0
            return Float(min(1, max(0.08, build + beat + drop)))
        }
        return encodeBars(levels)
        #else
        return ""
        #endif
    }

    private static func encodeBars(_ levels: [Float]) -> String {
        guard !levels.isEmpty else { return "" }
        let peak = max(0.001, levels.max() ?? 1)
        return String(levels.map { level in
            let normalised = min(1, max(0, Double(level / peak)))
            let step = Int((normalised * 15).rounded())
            return Character(String(step, radix: 16))
        })
    }

    private static func accentHex(forArtworkNamed fileName: String?) -> String? {
        guard let fileName,
              let url = SharedArtworkStore.url(forFileName: fileName),
              let image = UIImage(contentsOfFile: url.path),
              let cgImage = image.cgImage
        else { return nil }

        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var best: (score: Double, r: Double, g: Double, b: Double)?
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            guard maxC > 0.15, maxC < 0.98 else { continue }
            let score = saturation * 1.6 + maxC * 0.4
            if best == nil || score > best!.score {
                best = (score, r, g, b)
            }
        }

        guard let picked = best else { return nil }
        return boosted(red: picked.r, green: picked.g, blue: picked.b)
    }

    private static func boosted(red: Double, green: Double, blue: Double) -> String {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let vivid = UIColor(
            hue: hue,
            saturation: min(1, max(0.55, saturation * 1.35)),
            brightness: min(1, max(0.62, brightness * 1.15)),
            alpha: 1
        )

        var outR: CGFloat = 0, outG: CGFloat = 0, outB: CGFloat = 0
        vivid.getRed(&outR, green: &outG, blue: &outB, alpha: &alpha)
        return String(
            format: "%02X%02X%02X",
            Int((outR * 255).rounded()),
            Int((outG * 255).rounded()),
            Int((outB * 255).rounded())
        )
    }

    func play() {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: player.play()
        case .companion:  client.play()
        }
    }

    func pause() {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: player.pause()
        case .companion:  client.pause()
        }
    }

    func togglePlayPause() {
        guard let snapshot = nowPlaying else { return }
        snapshot.isPlaying ? pause() : play()
    }

    func next() {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: Task { await player.playNext() }
        case .companion:  client.next()
        }
    }

    func previous() {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: Task { await player.playPrevious() }
        case .companion:  client.previous()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: player.seek(to: seconds)
        case .companion:  client.seek(toSeconds: seconds)
        }
    }

    struct SkipPreview: Equatable {
        let title: String
        let artist: String
        let artworkURL: String?
    }

    var nextSkipPreview: SkipPreview? {
        switch activeSource {
        case .thisDevice:
            guard !player.queue.isEmpty else { return nil }
            if player.currentIndex < player.queue.count - 1 {
                return SkipPreview(track: player.queue[player.currentIndex + 1])
            }
            if player.repeatMode == .all, let first = player.queue.first {
                return SkipPreview(track: first)
            }
            return nil
        case .companion:
            guard client.hasSnapshot,
                  client.tracks.indices.contains(client.currentIndex + 1) else { return nil }
            return SkipPreview(track: client.tracks[client.currentIndex + 1])
        }
    }

    var previousSkipPreview: SkipPreview? {
        switch activeSource {
        case .thisDevice:
            guard player.currentTrack != nil, !player.queue.isEmpty else { return nil }
            if player.currentTime > 3 { return currentAsPreview }
            if player.currentIndex > 0 {
                return SkipPreview(track: player.queue[player.currentIndex - 1])
            }
            if player.repeatMode == .all, let last = player.queue.last {
                return SkipPreview(track: last)
            }
            return currentAsPreview
        case .companion:
            guard client.hasSnapshot else { return nil }
            if (client.playback?.positionSeconds ?? 0) > 3 { return currentAsPreview }
            guard client.tracks.indices.contains(client.currentIndex - 1) else { return currentAsPreview }
            return SkipPreview(track: client.tracks[client.currentIndex - 1])
        }
    }

    private var currentAsPreview: SkipPreview? {
        guard let snapshot = nowPlaying else { return nil }
        return SkipPreview(
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            artworkURL: snapshot.artworkURL
        )
    }

    struct UpNextEntry: Equatable, Identifiable {
        let id: String
        let title: String
        let artist: String
        let artworkURL: String?
        let duration: TimeInterval

        var formattedDuration: String {
            let total = max(0, Int(duration.rounded()))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// The active queue's upcoming tracks, whichever output owns playback.
    /// Read-only — reorder/remove stay in `QueueManagerView` for the TV queue.
    var upNextEntries: [UpNextEntry] {
        switch activeSource {
        case .thisDevice:
            guard !player.queue.isEmpty else { return [] }
            return player.queue.enumerated().compactMap { index, track in
                guard index > player.currentIndex else { return nil }
                return UpNextEntry(
                    id: track.id,
                    title: track.title,
                    artist: track.user.displayName,
                    artworkURL: track.artworkURL?.absoluteString,
                    duration: track.duration
                )
            }
        case .companion:
            guard client.hasSnapshot else { return [] }
            return client.tracks.enumerated().compactMap { index, track in
                guard index > client.currentIndex else { return nil }
                return UpNextEntry(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    artworkURL: track.artworkURL?.absoluteString,
                    duration: track.duration
                )
            }
        }
    }

    func playHere(_ track: Track, in context: [Track], collectionId: String? = nil) async {
        guard !PolyphonyController.shared.isSpeaker else { return }
        if player.outputTarget == .companion(.tv) {
            player.switchOutputTarget(to: .thisDevice)
        }
        await player.play(track, in: context, collectionId: collectionId)
    }

    func playHere(shuffled tracks: [Track], collectionId: String? = nil) async {
        guard !PolyphonyController.shared.isSpeaker else { return }
        guard let start = tracks.randomElement() else { return }
        if player.outputTarget == .companion(.tv) {
            player.switchOutputTarget(to: .thisDevice)
        }
        player.isShuffleEnabled = true
        await player.play(start, in: tracks, collectionId: collectionId)
    }

    func playOnAppleTV(_ track: Track) {
        guard !PolyphonyController.shared.isSpeaker else { return }
        guard client.isReachable else { return }
        client.replaceQueue(withTrackId: track.id)
        player.switchOutputTarget(to: .companion(.tv))
    }

    func addToQueue(_ track: Track) {
        guard !PolyphonyController.shared.isSpeaker else { return }
        switch activeSource {
        case .thisDevice: player.addToQueue(track)
        case .companion:  client.addToEnd(trackId: track.id)
        }
    }

    func setDJEnabled(_ enabled: Bool) {
        switch activeSource {
        case .thisDevice: player.setDJSessionEnabled(enabled)
        case .companion:  client.setDJEnabled(enabled)
        }
    }

    /// The phone owns the start sheet. Its choices are synced settings, then
    /// the selected playback endpoint is asked to enter Decks.
    func startDJSession(configuration: DJStartConfiguration, reconfigure: Bool = false) {
        SettingsStore.shared.setDJStartConfiguration(configuration)
        switch activeSource {
        case .thisDevice:
            player.startDJSession(configuration: configuration, reconfigure: reconfigure)
        case .companion:
            client.setAutoMixEnabled(true)
            client.setDJEnabled(true)
        }
    }

    func setAutoMixEnabled(_ enabled: Bool) {
        switch activeSource {
        case .thisDevice: player.setAutomaticMixEnabled(enabled)
        case .companion:  client.setAutoMixEnabled(enabled)
        }
    }

    func mixNow() {
        switch activeSource {
        case .thisDevice: player.startMix()
        case .companion:  client.mixNow()
        }
    }

    var djSnapshot: DJSnapshot {
        switch activeSource {
        case .thisDevice:
            let plan = player.adaptiveMixPlan
            return DJSnapshot(
                isEngineLive: player.isMixEngineLive,
                isAutoEnabled: player.isAutoMixEnabled,
                nextTitle: player.upcomingTrack?.title,
                nextArtist: player.upcomingTrack?.user.displayName,
                nextArtworkURL: player.upcomingTrack?.artworkURL?.absoluteString,
                mixInSeconds: player.plannedMixPointSeconds().map { max(0, $0 - player.currentTime) },
                reasoning: plan?.reasoning
            )
        case .companion:
            let decision = client.djState?.automaticMix
            let position = client.playback?.positionSeconds ?? 0
            let mixIn = decision?.mixPointSeconds.map { max(0, $0 - position) }
            return DJSnapshot(
                isEngineLive: client.isDJControlLive,
                isAutoEnabled: client.djState?.isAutoMixEnabled ?? false,
                nextTitle: nextSkipPreview?.title,
                nextArtist: nextSkipPreview?.artist,
                nextArtworkURL: nextSkipPreview?.artworkURL,
                mixInSeconds: mixIn,
                reasoning: decision?.headline
            )
        }
    }

    struct DJSnapshot: Equatable {
        let isEngineLive: Bool
        let isAutoEnabled: Bool
        let nextTitle: String?
        let nextArtist: String?
        let nextArtworkURL: String?
        let mixInSeconds: TimeInterval?
        let reasoning: String?
    }

    func moveSession(to target: PlaybackOutput) async {
        guard target != activeSource else { return }

        switch target {
        case .companion(let deviceClass):
            player.switchOutputTarget(to: .companion(deviceClass))
        case .thisDevice:
            guard let playback = client.playback,
                  let trackId = playback.trackId else {
                player.switchOutputTarget(to: .thisDevice)
                return
            }
            guard let track = try? await SoundCloudAPI.shared.getTrack(id: trackId) else {
                player.switchOutputTarget(to: .thisDevice)
                return
            }
            await player.adoptHandoff(
                track: track,
                queue: [track],
                index: 0,
                position: playback.positionSeconds,
                autoplay: playback.isPlaying
            )
        }
    }

    private static var debugFakeNowPlayingSource: PlaybackOutput? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_NOWPLAYING"] {
        case "1":       return .thisDevice
        case "appletv": return .companion(.tv)
        default:        return nil
        }
        #else
        return nil
        #endif
    }

    private static let debugFakeStart = Date()

    private static var debugFakeNowPlayingSnapshot: NowPlayingSnapshot? {
        guard let source = debugFakeNowPlayingSource else { return nil }
        let duration: TimeInterval = 243
        let elapsed = Date().timeIntervalSince(debugFakeStart) + 97
        return NowPlayingSnapshot(
            source: source,
            trackId: "debug-fake-track",
            title: "Midnight Runner",
            artist: "Nocturne Collective",
            artworkURL: "https://i1.sndcdn.com/artworks-000067273316-smsiqx-t500x500.jpg",
            position: elapsed.truncatingRemainder(dividingBy: duration),
            duration: duration,
            isPlaying: true,
            isLoading: false,
            isDJEngineLive: false
        )
    }
}

struct NowPlayingSnapshot: Equatable {
    let source: PlaybackOutput
    let trackId: String?
    let title: String?
    let artist: String?
    let artworkURL: String?
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let isLoading: Bool
    let isDJEngineLive: Bool

    var displayTitle: String { title ?? "Unknown Track" }
    var displayArtist: String { artist ?? "Unknown Artist" }
}

extension PhonePlaybackCoordinator.SkipPreview {
    init(track: Track) {
        self.init(
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL?.absoluteString
        )
    }

    init(track: QueueTrack) {
        self.init(
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL?.absoluteString
        )
    }
}
