import Combine
import Foundation
import UIKit
import WatchConnectivity
import os

private final class WatchReplyHandlerBox: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func callAsFunction(_ payload: [String: Any]) { handler(payload) }
}

@MainActor
final class PhoneWatchLinkServer: NSObject, ObservableObject {
    static let shared = PhoneWatchLinkServer()

    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false

    private weak var coordinator: PhonePlaybackCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var publishTask: Task<Void, Never>?
    private var lastPublished: [String: Data] = [:]

    private static let publishInterval: Duration = .milliseconds(600)

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    func attach(coordinator: PhonePlaybackCoordinator) {
        self.coordinator = coordinator
        cancellables.removeAll()
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        DownloadManager.shared.objectWillChange
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        SettingsStore.shared.objectWillChange
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        PolyphonyController.shared.objectWillChange
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            syncState()
        }
    }

    private func syncState() {
        guard let session else { return }
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            self?.publishTask = nil
            self?.publish()
        }
    }

    func publish() {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled
        else { return }

        var context: [String: Data] = [:]
        if let data = WatchLinkCodec.encode(currentNowPlaying()) {
            context[WatchLinkKey.nowPlaying] = data
        }
        if let data = WatchLinkCodec.encode(currentDJState()) {
            context[WatchLinkKey.djState] = data
        }
        if let data = WatchLinkCodec.encode(currentAuthState()) {
            context[WatchLinkKey.authState] = data
        }
        if let data = WatchLinkCodec.encode(currentDownloads()) {
            context[WatchLinkKey.downloads] = data
        }
        if let data = WatchLinkCodec.encode(currentSettings()) {
            context[WatchLinkKey.settings] = data
        }
        if let data = WatchLinkCodec.encode(currentPolyphonyState()) {
            context[WatchLinkKey.polyphony] = data
        }

        guard context != lastPublished else { return }
        lastPublished = context
        do {
            try session.updateApplicationContext(context)
        } catch {
            Log.link.error("[WatchLink] publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Snapshots

    private func currentNowPlaying() -> WatchNowPlaying {
        guard let coordinator, let snapshot = coordinator.nowPlaying else {
            var idle = WatchNowPlaying.idle
            idle.updatedAtMillis = WatchLinkCodec.nowMillis()
            return idle
        }
        return WatchNowPlaying(
            trackId: snapshot.trackId,
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            artworkURL: snapshot.artworkURL.flatMap(URL.init(string:)),
            isPlaying: snapshot.isPlaying,
            positionSeconds: snapshot.position,
            durationSeconds: snapshot.duration,
            output: coordinator.activeSource.companionClass ?? DeviceClass.current,
            queueCount: PlayerService.shared.queue.count,
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func currentDJState() -> WatchDJState {
        guard let coordinator else { return .off }
        let dj = coordinator.djSnapshot
        return WatchDJState(
            isEngineLive: dj.isEngineLive,
            isAutoEnabled: dj.isAutoEnabled,
            nextTitle: dj.nextTitle,
            nextArtist: dj.nextArtist,
            nextArtworkURL: dj.nextArtworkURL.flatMap(URL.init(string:)),
            mixInSeconds: dj.mixInSeconds,
            reasoning: dj.reasoning,
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func currentAuthState() -> WatchAuthState {
        let user = SoundCloudCredentialSource.shared.currentUser
        return WatchAuthState(
            isSignedIn: DeviceSessionStore.load()?.isUsable == true,
            displayName: user?.displayName,
            avatarURL: user?.avatarURL,
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func currentDownloads() -> WatchDownloadInventory {
        let entries = DownloadManager.shared.entries.values.filter(\.isDownloaded)
        let items = entries
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(100)
            .map { entry in
                WatchDownloadItem(
                    id: entry.track.id,
                    title: entry.track.title,
                    artist: entry.track.user.displayName,
                    artworkURL: entry.track.artworkURL,
                    bytes: entry.fileSize
                )
            }
        return WatchDownloadInventory(
            items: Array(items),
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.fileSize },
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func currentSettings() -> WatchSettingsSnapshot {
        let store = SettingsStore.shared
        return WatchSettingsSnapshot(
            items: [
                managedSetting(
                    "Streaming Quality",
                    value: store.streamingQualityCeiling.displayName,
                    key: SettingKeys.StreamingQualityCeiling.self
                ),
                managedSetting(
                    "Download Quality",
                    value: store.downloadQualityCeiling.displayName,
                    key: SettingKeys.DownloadQualityCeiling.self
                ),
                managedSetting(
                    "DJ Auto-Mix",
                    value: store.djAutoMixEnabled ? "On" : "Off",
                    key: SettingKeys.DJAutoMixEnabled.self
                ),
                managedSetting(
                    "DJ Personality",
                    value: DJProfile.profile(id: store.djDefaultProfileId)?.displayName ?? "Automatic",
                    key: SettingKeys.DJDefaultProfileId.self
                ),
                managedSetting(
                    "Transition",
                    value: watchDuration(store.djTransitionLengthSeconds),
                    key: SettingKeys.DJTransitionLengthSeconds.self
                ),
            ],
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func currentPolyphonyState() -> WatchPolyphonyState {
        let controller = PolyphonyController.shared
        let mode: WatchPolyphonyMode
        let leaderName: String?
        let message: String?
        switch controller.mode {
        case .idle:
            mode = .idle; leaderName = nil; message = nil
        case .startingLeader:
            mode = .startingLeader; leaderName = nil; message = nil
        case .leading:
            mode = .leading; leaderName = nil; message = nil
        case .connecting(let name):
            mode = .connecting; leaderName = name; message = nil
        case .speaker(let name):
            mode = .speaker; leaderName = name; message = nil
        case .failed(let detail):
            mode = .failed; leaderName = nil; message = detail
        }
        return WatchPolyphonyState(
            mode: mode,
            leaderName: leaderName,
            joinCode: controller.joinCode,
            speakerCount: controller.speakerCount,
            message: message,
            updatedAtMillis: WatchLinkCodec.nowMillis()
        )
    }

    private func managedSetting<K: SettingDefinition>(
        _ title: String,
        value: String,
        key: K.Type
    ) -> WatchManagedSetting {
        WatchManagedSetting(
            id: key.id,
            title: title,
            value: value,
            source: SettingsStore.shared.effectiveScope(key) == .synced ? .phone : .watch
        )
    }

    private func watchDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        return rounded < 60 ? "\(rounded)s" : "\(rounded / 60)m"
    }

    // MARK: - Inbound

    private func handle(_ command: WatchCommand) {
        guard let coordinator else { return }
        switch command.kind {
        case .snapshotRequest:
            lastPublished = [:]
            publish()

        case .transport:
            switch command.transport {
            case .play:     coordinator.play()
            case .pause:    coordinator.pause()
            case .toggle:   coordinator.togglePlayPause()
            case .next:     coordinator.next()
            case .previous: coordinator.previous()
            case nil:       break
            }

        case .seek:
            if let seconds = command.seekSeconds { coordinator.seek(to: seconds) }

        case .dj:
            switch command.dj {
            case .enable:      coordinator.setDJEnabled(true)
            case .disable:     coordinator.setDJEnabled(false)
            case .autoEnable:  coordinator.setAutoMixEnabled(true)
            case .autoDisable: coordinator.setAutoMixEnabled(false)
            case .mixNow:      coordinator.mixNow()
            case nil:          break
            }

        case .output:
            guard let output = command.output else { break }
            let target: PlaybackOutput = PlaybackOutput.deviceClassesWithCompanionServerToday.contains(output)
                ? .companion(output)
                : .thisDevice
            Task { await coordinator.moveSession(to: target) }

        case .polyphony:
            switch command.polyphony {
            case .lead:
                PolyphonyController.shared.startLeading(leaderName: UIDevice.current.name)
            case .leave:
                PolyphonyController.shared.leave()
            case nil:
                break
            }

        case .play:
            Task { await self.startPlayback(command) }

        case .queue:
            guard let trackId = command.trackId else { break }
            Task { await self.enqueue(trackId: trackId, action: command.queue) }

        case .sessionRequest, .sessionOffer, .sessionUnavailable:
            break
        }
        schedulePublish()
    }

    private func startPlayback(_ command: WatchCommand) async {
        guard let coordinator else { return }
        do {
            if command.collectionId == CollectionPolicyID.likedTracks {
                let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 100)
                var tracks = page.collection.map(\.item).filter { $0.streamURL != nil }
                if command.shuffled == true { tracks.shuffle() }
                guard let first = tracks.first else { return }
                await coordinator.playHere(first, in: tracks, collectionId: CollectionPolicyID.likedTracks)
            } else if let collectionId = command.collectionId {
                let playlist = try await SoundCloudAPI.shared.getPlaylist(id: collectionId)
                let tracks = playlist.loadedTracks
                guard !tracks.isEmpty else { return }
                if command.shuffled == true {
                    await coordinator.playHere(shuffled: tracks, collectionId: collectionId)
                } else if let trackId = command.trackId,
                          let start = tracks.first(where: { $0.id == trackId }) {
                    await coordinator.playHere(start, in: tracks, collectionId: collectionId)
                } else {
                    await coordinator.playHere(tracks[0], in: tracks, collectionId: collectionId)
                }
            } else if let trackId = command.trackId {
                let track = try await SoundCloudAPI.shared.getTrack(id: trackId)
                await coordinator.playHere(track, in: [track])
            }
        } catch {
            Log.link.error("[WatchLink] play request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(trackId: String, action: WatchQueueAction?) async {
        guard let coordinator else { return }
        guard let track = try? await SoundCloudAPI.shared.getTrack(id: trackId) else { return }
        coordinator.addToQueue(track)
    }

    private func sessionOfferReply() async -> [String: Any] {
        guard var session = DeviceSessionStore.load(), session.isUsable else {
            return [WatchLinkKey.kind: WatchLinkKind.sessionUnavailable.rawValue]
        }
        if session.shouldRefreshBeforeHandoff,
           let refreshed = await DeviceSessionRefresher.shared.refresh(session) {
            session = refreshed
        }
        let offer = WatchSessionOffer(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAt: session.expiresAt
        )
        Log.link.info("[WatchLink] handed the paired watch a SoundCloud session")
        return WatchLinkCodec.message(.sessionOffer, offer)
    }
}

extension PhoneWatchLinkServer: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.syncState()
            if state == .activated { self.publish() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.syncState()
            self.publish()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.syncState() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchLinkCodec.payload(WatchCommand.self, from: message) else { return }
        Task { @MainActor in self.handle(command) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let kind = WatchLinkCodec.kind(of: message) else {
            replyHandler([:])
            return
        }
        if kind == .sessionRequest {
            let reply = WatchReplyHandlerBox(replyHandler)
            Task { @MainActor in reply(await self.sessionOfferReply()) }
            return
        }
        if let command = WatchLinkCodec.payload(WatchCommand.self, from: message) {
            Task { @MainActor in self.handle(command) }
        }
        replyHandler([:])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = WatchLinkCodec.payload(WatchCommand.self, from: userInfo) else { return }
        Task { @MainActor in self.handle(command) }
    }
}
