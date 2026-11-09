import Combine
import Foundation
import UIKit
import WatchConnectivity
import os
import Observation

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
    private let scheduler = WorkScheduler.shared
    private static let schedulerQueue = WorkScheduler.QueueID(rawValue: "watch.state")
    private var lastPublished: [String: Data] = [:]
    private var stamp: Int64 = 0

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
        ContinueFrom.shared.objectWillChange
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        PhoneWatchOfflineSync.shared.$manifest
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        PhoneWatchOfflineSync.shared.start()
        observeAutoMix()
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
        scheduler.submit(
            queue: Self.schedulerQueue,
            key: "watch.application-context",
            delivery: .latest,
            delay: Self.publishInterval
        ) { [weak self] in
            self?.publish()
        }
    }

    func publish() {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled
        else { return }

        guard makeContext() != lastPublished else { return }
        stamp = WatchLinkCodec.nowMillis()
        let context = makeContext()
        lastPublished = context
        do {
            try session.updateApplicationContext(context)
        } catch {
            Log.link.error("[WatchLink] publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeContext() -> [String: Data] {
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
        if let data = WatchLinkCodec.encode(currentQueue()) {
            context[WatchLinkKey.queue] = data
        }
        context[WatchLinkKey.continueOffer] = currentContinueOffer().flatMap { WatchLinkCodec.encode($0) } ?? Data()
        if let data = WatchLinkCodec.encode(PhoneWatchOfflineSync.shared.manifest) {
            context[WatchLinkKey.offlineManifest] = data
        }
        return context
    }

    // MARK: - Snapshots

    private func currentNowPlaying() -> WatchNowPlaying {
        guard let coordinator, let snapshot = coordinator.nowPlaying else {
            var idle = WatchNowPlaying.idle
            idle.updatedAtMillis = stamp
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
            output: coordinator.activeSource.deviceClassIfRemote ?? DeviceClass.current,
            queueCount: PlayerService.shared.queue.count,
            updatedAtMillis: stamp,
            outputId: coordinator.currentOutput.id,
            outputName: Self.watchName(for: coordinator.currentOutput),
            outputs: currentOutputs(),
            volume: coordinator.volume
        )
    }

    private func currentOutputs() -> [WatchOutputOption] {
        guard let coordinator else { return [] }
        return Self.watchOutputs(coordinator.outputs) { coordinator.isReachable($0) }
    }

    static func watchName(for device: OutputDevice) -> String {
        device.isLocal ? DeviceClass.current.displayName : device.name
    }

    static func watchOutputs(_ devices: [OutputDevice], isReachable: (OutputDevice) -> Bool) -> [WatchOutputOption] {
        var options = devices.map { device in
            WatchOutputOption(
                id: device.id,
                name: watchName(for: device),
                deviceClass: device.deviceClass,
                isAvailable: device.isLocal || isReachable(device)
            )
        }
        if !options.contains(where: { $0.id == OutputDevice.localID }) {
            let local = OutputDevice.thisDevice
            options.insert(
                WatchOutputOption(id: local.id, name: watchName(for: local), deviceClass: local.deviceClass),
                at: 0
            )
        }
        return options
    }

    private func currentContinueOffer() -> WatchContinueOffer? {
        guard let offer = ContinueFrom.shared.offer else { return nil }
        let session = offer.session
        return WatchContinueOffer(
            id: offer.id,
            deviceName: offer.deviceName,
            deviceClass: session.deviceClass,
            title: session.title,
            artist: session.artist,
            artworkURL: session.artworkURL,
            positionSeconds: offer.position,
            durationSeconds: session.duration,
            isPlaying: session.isPlaying,
            updatedAtMillis: session.updatedAtMillis
        )
    }

    private func currentQueue() -> WatchQueueSnapshot {
        guard let coordinator else { return .empty }
        let items = coordinator.upNextEntries.prefix(WatchQueueSnapshot.limit).compactMap { entry -> WatchQueueItem? in
            guard let index = entry.queueIndex else { return nil }
            return WatchQueueItem(
                index: index,
                trackId: entry.trackID,
                title: entry.title,
                artist: entry.artist,
                artworkURL: entry.artworkURL.flatMap(URL.init(string:))
            )
        }
        return WatchQueueSnapshot(
            items: Array(items),
            updatedAtMillis: stamp,
            sourceTitle: coordinator.queueSource?.title
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
            updatedAtMillis: stamp,
            live: coordinator.autoMixLive.map(Self.compact)?.encoded()
        )
    }

    private static func compact(_ state: AutoMixLiveState) -> AutoMixLiveState {
        var compact = state
        compact.outgoing = nil
        compact.incoming = nil
        compact.crossfade = 0
        compact.anchoredAt = state.startsAt
        return compact
    }

    private func observeAutoMix() {
        withObservationTracking {
            _ = AutoMixLive.shared.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePublish()
                self?.observeAutoMix()
            }
        }
    }

    private func currentAuthState() -> WatchAuthState {
        let user = SoundCloudCredentialSource.shared.currentUser
        return WatchAuthState(
            isSignedIn: DeviceSessionStore.load()?.isUsable == true,
            displayName: user?.displayName,
            avatarURL: user?.avatarURL,
            updatedAtMillis: stamp
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
            updatedAtMillis: stamp
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
            updatedAtMillis: stamp
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
            case .extend:      coordinator.extendMix()
            case .heartRate:
                if let bpm = command.heartRate { PhoneWorkoutEnergy.shared.noteHeartRate(bpm) }
            case nil:          break
            }

        case .output:
            let target: OutputDevice
            if let outputId = command.outputId {
                target = coordinator.outputs.first { $0.id == outputId } ?? .thisDevice
            } else if let output = command.output {
                target = coordinator.outputs.first { !$0.isLocal && $0.deviceClass == output } ?? .thisDevice
            } else {
                break
            }
            guard target != coordinator.currentOutput else { break }
            Task { await coordinator.move(to: target) }

        case .volume:
            if let volume = command.volume { coordinator.setVolume(volume) }

        case .continueFrom:
            if let offer = ContinueFrom.shared.offer, offer.id == command.continueId {
                ContinueFrom.shared.accept(offer, play: true)
            }

        case .continueDismiss:
            if let offer = ContinueFrom.shared.offer, offer.id == command.continueId {
                ContinueFrom.shared.dismiss(offer)
            }

        case .play:
            Task { await self.startPlayback(command) }

        case .jump:
            if let index = command.queueIndex { coordinator.playQueueItem(at: index) }

        case .queue:
            guard let trackId = command.trackId else { break }
            Task { await self.enqueue(trackId: trackId, action: command.queue) }

        case .offlineRemove:
            PhoneWatchOfflineSync.shared.handleRemoval(collectionId: command.collectionId, trackId: command.trackId)

        case .sessionRequest, .sessionOffer, .sessionUnavailable, .offlineFile, .playReport:
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
                await coordinator.play(first, in: tracks, collectionId: CollectionPolicyID.likedTracks)
            } else if let artistId = command.artistId {
                let page = try await SoundCloudAPI.shared.getUserTracks(userId: artistId, limit: 50)
                var tracks = page.collection.filter { $0.streamURL != nil }
                if command.shuffled == true { tracks.shuffle() }
                guard let first = tracks.first else { return }
                await coordinator.play(first, in: tracks)
            } else if let collectionId = command.collectionId {
                let playlist = try await SoundCloudAPI.shared.getPlaylist(id: collectionId)
                let tracks = playlist.loadedTracks
                guard !tracks.isEmpty else { return }
                if command.shuffled == true {
                    await coordinator.play(shuffled: tracks, collectionId: collectionId)
                } else if let trackId = command.trackId,
                          let start = tracks.first(where: { $0.id == trackId }) {
                    await coordinator.play(start, in: tracks, collectionId: collectionId)
                } else {
                    await coordinator.play(tracks[0], in: tracks, collectionId: collectionId)
                }
            } else if let trackId = command.trackId {
                let track = try await SoundCloudAPI.shared.getTrack(id: trackId)
                await coordinator.play(track, in: [track])
            }
        } catch {
            Log.link.error("[WatchLink] play request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(trackId: String, action: WatchQueueAction?) async {
        guard let coordinator else { return }
        guard let track = try? await SoundCloudAPI.shared.getTrack(id: trackId) else { return }
        let player = PlayerService.shared
        if action == .playNext, player.currentTrack != nil, !player.queue.isEmpty {
            player.insertIntoQueue(track, at: player.currentIndex + 1)
        } else {
            coordinator.addToQueue(track)
        }
    }

    private func sessionOfferReply() async -> [String: Any] {
        guard var session = DeviceSessionStore.load(), session.isUsable else {
            return [WatchLinkKey.kind: WatchLinkKind.sessionUnavailable.rawValue]
        }
        if session.shouldRefreshBeforeHandoff,
           let refreshed = await DeviceSessionRefresher.shared.refresh(session, trigger: "watch asked for a session") {
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

    private func adoptRotatedWatchSession(_ offer: WatchSessionOffer) {
        guard let lineage = offer.replacesLineage else { return }
        let adopted = SoundCloudCredentialSource.shared.adoptRotatedSession(
            StoredSession(
                oauthToken: offer.oauthToken,
                refreshToken: offer.refreshToken,
                clientId: offer.clientId,
                expiresAt: offer.expiresAt
            ),
            replacingLineage: lineage
        )
        Log.link.info("[WatchLink] rotated session from the watch \(adopted ? "adopted" : "ignored", privacy: .public)")
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
            if state == .activated {
                self.publish()
                PhoneWatchOfflineSync.shared.sessionDidActivate()
            }
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
            PhoneWatchOfflineSync.shared.sessionDidActivate()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLinkKey.offlineInventory] as? Data,
              let inventory = WatchLinkCodec.decode(WatchOfflineInventory.self, from: data) else { return }
        Task { @MainActor in PhoneWatchOfflineSync.shared.ingestInventory(inventory) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let stagedURL = fileTransfer.file.fileURL
        let trackID = PhoneWatchOfflineSync.trackID(of: fileTransfer.file.metadata)
        let failure = error.map { $0.localizedDescription }
        Task { @MainActor in
            PhoneWatchOfflineSync.shared.transferFinished(
                stagedURL: stagedURL,
                trackID: trackID,
                failure: failure
            )
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
        if WatchLinkCodec.kind(of: userInfo) == .sessionOffer {
            guard let offer = WatchLinkCodec.payload(WatchSessionOffer.self, from: userInfo) else { return }
            Task { @MainActor in self.adoptRotatedWatchSession(offer) }
            return
        }
        if WatchLinkCodec.kind(of: userInfo) == .playReport {
            guard let report = WatchLinkCodec.payload(WatchPlayReport.self, from: userInfo) else { return }
            Task { @MainActor in PhoneWatchOfflineSync.shared.record(report) }
            return
        }
        guard let command = WatchLinkCodec.payload(WatchCommand.self, from: userInfo) else { return }
        Task { @MainActor in self.handle(command) }
    }
}
