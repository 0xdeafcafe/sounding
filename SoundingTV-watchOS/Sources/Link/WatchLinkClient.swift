import Foundation
import Combine
import WatchConnectivity
import os

private struct WatchPayloadBox: @unchecked Sendable {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
}

private final class OfferReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (WatchSessionOffer?) -> Void)?

    init(_ completion: @escaping @Sendable (WatchSessionOffer?) -> Void) {
        self.completion = completion
    }

    func finish(_ offer: WatchSessionOffer?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(offer)
    }
}

@MainActor
final class WatchLinkClient: NSObject, ObservableObject {
    static let shared = WatchLinkClient()

    @Published private(set) var nowPlaying: WatchNowPlaying = .idle
    @Published private(set) var djState: WatchDJState = .off
    @Published private(set) var downloads: WatchDownloadInventory = .empty
    @Published private(set) var authState: WatchAuthState = .unknown
    @Published private(set) var settings: WatchSettingsSnapshot = .empty
    @Published private(set) var queue: WatchQueueSnapshot = .empty
    @Published private(set) var continueOffer: WatchContinueOffer?
    @Published private(set) var devicePresence: WatchDevicePresence = .empty
    @Published private(set) var isReachable = false
    @Published private(set) var isCompanionInstalled = false

    @Published private(set) var pendingVolume: Double?

    private(set) var nowPlayingReceivedAt = Date()
    private(set) var djStateReceivedAt = Date()
    private var volumeSendTask: Task<Void, Never>?
    private var lastVolumeSentAt = Date.distantPast
    private var pendingVolumeSetAt = Date.distantPast
    private var pendingUserInfo: [WatchPayloadBox] = []
    private var pendingInventory: Data?
    @Published private(set) var isActivated = false

    private static let phonePlaybackKinds: Set<WatchLinkKind> = [.play, .jump, .continueFrom]

    var volume: Double? { pendingVolume ?? nowPlaying.clampedVolume }

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    func activate() {
        #if DEBUG
        if WatchUIPreview.isEnabled {
            installPreviewFixture()
            return
        }
        #endif
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            isActivated = true
            syncReachability()
            ingest(context: session.receivedApplicationContext)
            flushOfflineState()
        }
    }

    func send(_ command: WatchCommand) {
        if Self.phonePlaybackKinds.contains(command.kind) {
            WatchPlayback.shared.phoneWillPlay()
        }
        guard let session, session.activationState == .activated else { return }
        let message = WatchLinkCodec.message(command.kind, command)
        if session.isReachable {
            Self.sendWithoutReply(message, on: session)
        } else if command.kind == .queue {
            session.transferUserInfo(message)
        } else {
            Log.link.info("[WatchLink] dropped \(command.kind.rawValue, privacy: .public): iPhone not reachable")
            syncReachability()
        }
    }

    func sendReliably(_ command: WatchCommand) {
        enqueueUserInfo(WatchLinkCodec.message(command.kind, command))
    }

    func sendPlayReport(_ report: WatchPlayReport) {
        enqueueUserInfo(WatchLinkCodec.message(.playReport, report))
    }

    func publishOfflineInventory(_ inventory: WatchOfflineInventory) {
        guard let data = WatchLinkCodec.encode(inventory) else { return }
        pendingInventory = data
        flushOfflineState()
    }

    private func enqueueUserInfo(_ message: [String: Any]) {
        pendingUserInfo.append(WatchPayloadBox(message))
        flushOfflineState()
    }

    private func flushOfflineState() {
        #if DEBUG
        if WatchUIPreview.isEnabled { return }
        #endif
        guard let session, session.activationState == .activated else { return }
        for box in pendingUserInfo {
            session.transferUserInfo(box.values)
        }
        pendingUserInfo.removeAll()
        if let pendingInventory {
            do {
                try session.updateApplicationContext([WatchLinkKey.offlineInventory: pendingInventory])
                self.pendingInventory = nil
            } catch {
                Log.link.error("[WatchLink] inventory publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendAwaitingPhone(_ command: WatchCommand) async {
        guard await waitUntilPhoneIsReachable() else { return }
        send(command)
    }

    func transport(_ action: WatchTransportAction) {
        send(WatchCommand(kind: .transport, transport: action))
    }

    func seek(to seconds: TimeInterval) {
        send(WatchCommand(kind: .seek, seekSeconds: seconds))
    }

    func dj(_ action: WatchDJAction) {
        send(WatchCommand(kind: .dj, dj: action))
    }

    func sendHeartRate(_ bpm: Double) {
        send(WatchCommand(kind: .dj, dj: .heartRate, heartRate: bpm))
    }

    func selectOutput(_ option: WatchOutputOption) {
        guard !nowPlaying.isSelected(option) else { return }
        send(WatchCommand(kind: .output, output: option.deviceClass, outputId: option.id))
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        pendingVolume = clamped
        pendingVolumeSetAt = Date()
        volumeSendTask?.cancel()
        let wait = max(0, WatchVolumeThrottle.interval - Date().timeIntervalSince(lastVolumeSentAt))
        volumeSendTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.lastVolumeSentAt = Date()
            self.send(WatchCommand(kind: .volume, volume: clamped))
        }
    }

    func play(trackId: String, collectionId: String? = nil) {
        send(WatchCommand(kind: .play, trackId: trackId, collectionId: collectionId))
    }

    func play(collectionId: String, shuffled: Bool = false) {
        send(WatchCommand(kind: .play, collectionId: collectionId, shuffled: shuffled))
    }

    func play(artistId: String, shuffled: Bool = false) {
        send(WatchCommand(kind: .play, shuffled: shuffled, artistId: artistId))
    }

    func jump(toQueueIndex index: Int) {
        send(WatchCommand(kind: .jump, queueIndex: index))
    }

    func enqueue(trackId: String, action: WatchQueueAction) {
        send(WatchCommand(kind: .queue, queue: action, trackId: trackId))
    }

    func pushRotatedSession(previous: StoredSession, renewed: StoredSession) {
        guard let session, session.activationState == .activated,
              let lineage = SessionSyncBookkeeping.lineageDigest(refreshToken: previous.refreshToken) else { return }
        let offer = WatchSessionOffer(
            oauthToken: renewed.oauthToken,
            refreshToken: renewed.refreshToken,
            clientId: renewed.clientId,
            expiresAt: renewed.expiresAt,
            replacesLineage: lineage
        )
        session.transferUserInfo(WatchLinkCodec.message(.sessionOffer, offer))
        Log.link.info("[WatchLink] queued the rotated SoundCloud session for the paired iPhone")
    }

    func continueFromOffer(_ offer: WatchContinueOffer) {
        send(WatchCommand(kind: .continueFrom, continueId: offer.id))
    }

    func dismissOffer(_ offer: WatchContinueOffer) {
        if continueOffer?.id == offer.id { continueOffer = nil }
        send(WatchCommand(kind: .continueDismiss, continueId: offer.id))
    }

    func requestSnapshot() {
        send(WatchCommand(kind: .snapshotRequest))
    }

    @discardableResult
    func requestSession() async -> WatchSessionOffer? {
        guard await waitUntilPhoneIsReachable(), let session else { return nil }
        let request = WatchCommand(kind: .sessionRequest)
        let message = WatchLinkCodec.message(.sessionRequest, request)

        return await withCheckedContinuation { continuation in
            Self.requestOffer(message, on: session) { offer in
                continuation.resume(returning: offer)
            }
        }
    }

    private nonisolated static func sendWithoutReply(_ message: [String: Any], on session: WCSession) {
        session.sendMessage(message, replyHandler: nil) { error in
            Log.link.error("[WatchLink] send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func requestOffer(
        _ message: [String: Any],
        on session: WCSession,
        completion: @escaping @Sendable (WatchSessionOffer?) -> Void
    ) {
        let once = OfferReplyOnce(completion)
        session.sendMessage(message) { reply in
            guard WatchLinkCodec.kind(of: reply) == .sessionOffer,
                  let offer = WatchLinkCodec.payload(WatchSessionOffer.self, from: reply)
            else {
                once.finish(nil)
                return
            }
            once.finish(offer)
        } errorHandler: { error in
            Log.link.error("[WatchLink] session request failed: \(error.localizedDescription, privacy: .public)")
            once.finish(nil)
        }
    }

    private func waitUntilPhoneIsReachable() async -> Bool {
        activate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while clock.now < deadline, !Task.isCancelled {
            if let session,
               session.activationState == .activated,
               session.isReachable {
                syncReachability()
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        syncReachability()
        return false
    }

    private func syncReachability() {
        #if DEBUG
        if WatchUIPreview.isEnabled { return }
        #endif
        guard let session else { return }
        isReachable = session.isReachable
        isCompanionInstalled = session.isCompanionAppInstalled
    }

    #if DEBUG
    private func installPreviewFixture() {
        isReachable = true
        isCompanionInstalled = true
        let artworkURL = WatchUIPreview.value(for: "-SoundingWatchUIArtwork").flatMap(URL.init(string:))
        let isMix = WatchUIPreview.hasFlag("-SoundingWatchUITracklist")
        nowPlaying = WatchNowPlaying(
            trackId: "preview-1",
            title: isMix ? "Low Tide 041" : "Midnight Transit",
            artist: isMix ? "Juno Vale" : "Glass District",
            artworkURL: artworkURL,
            isPlaying: true,
            positionSeconds: isMix ? 41 * 60 + 52 : 94,
            durationSeconds: isMix ? 61 * 60 : 312,
            output: WatchUIPreview.value(for: "-SoundingWatchUIOutput") == "tv" ? .tv : .phone,
            queueCount: 7,
            updatedAtMillis: 0,
            outputId: WatchUIPreview.value(for: "-SoundingWatchUIOutput") == "tv" ? "linked.living" : WatchOutputOption.thisPhoneID,
            outputName: WatchUIPreview.value(for: "-SoundingWatchUIOutput") == "tv" ? "Living Room" : "iPhone",
            outputs: [
                WatchOutputOption(id: WatchOutputOption.thisPhoneID, name: "iPhone", deviceClass: .phone),
                WatchOutputOption(id: "linked.living", name: "Living Room", deviceClass: .tv),
                WatchOutputOption(id: "linked.bedroom", name: "Bedroom", deviceClass: .tv, isAvailable: false)
            ],
            volume: 0.7
        )
        nowPlayingReceivedAt = Date()
        djState = WatchDJState(
            isEngineLive: true,
            isAutoEnabled: true,
            nextTitle: "Harbour Lights",
            nextArtist: "Low Sun",
            nextArtworkURL: nil,
            mixInSeconds: 148,
            reasoning: "Loop build into Harbour Lights, 16 bars",
            updatedAtMillis: 0
        )
        djStateReceivedAt = Date()
        queue = WatchQueueSnapshot(
            items: [
                WatchQueueItem(index: 1, trackId: "q1", title: "Harbour Lights", artist: "Low Sun", artworkURL: nil),
                WatchQueueItem(index: 2, trackId: "q2", title: "Slow Orbit", artist: "Soft Static", artworkURL: nil),
                WatchQueueItem(index: 3, trackId: "q3", title: "Glass Hours", artist: "Juno Vale", artworkURL: nil),
                WatchQueueItem(index: 4, trackId: "q4", title: "Night Bus to Nowhere", artist: "Glass District", artworkURL: nil),
                WatchQueueItem(index: 5, trackId: "q5", title: "Soft Machine", artist: "Soft Static", artworkURL: nil),
                WatchQueueItem(index: 6, trackId: "q6", title: "Tidal", artist: "Low Sun", artworkURL: nil),
                WatchQueueItem(index: 7, trackId: "q7", title: "Afterglow", artist: "Juno Vale", artworkURL: nil)
            ],
            updatedAtMillis: 0,
            sourceTitle: "Late Night Drive"
        )
        if WatchUIPreview.hasFlag("-SoundingWatchUIContinue") {
            continueOffer = WatchContinueOffer(
                id: "preview|offer",
                deviceName: "Living Room",
                deviceClass: .tv,
                title: "Harbour Lights",
                artist: "Low Sun",
                artworkURL: artworkURL,
                positionSeconds: 133,
                durationSeconds: 284,
                isPlaying: false,
                updatedAtMillis: WatchLinkCodec.nowMillis()
            )
        }
        downloads = WatchDownloadInventory(
            items: [
                WatchDownloadItem(id: "preview-1", title: "Midnight Transit", artist: "Glass District", artworkURL: nil, bytes: 9_400_000),
                WatchDownloadItem(id: "preview-2", title: "Harbour Lights", artist: "Low Sun", artworkURL: nil, bytes: 8_100_000),
                WatchDownloadItem(id: "preview-3", title: "Slow Orbit", artist: "Soft Static", artworkURL: nil, bytes: 11_200_000)
            ],
            totalBytes: 28_700_000,
            updatedAtMillis: 0
        )
    }
    #endif

    private func ingest(context: [String: Any]) {
        if let data = context[WatchLinkKey.nowPlaying] as? Data,
           let value = WatchLinkCodec.decode(WatchNowPlaying.self, from: data) {
            nowPlaying = value
            nowPlayingReceivedAt = Date()
            if let pending = pendingVolume,
               WatchVolumeThrottle.settles(pending: pending, reported: value.clampedVolume, since: pendingVolumeSetAt) {
                pendingVolume = nil
            }
            if !WatchPlayback.shared.isLocal {
                WatchSnapshotWriter.shared.record(value, receivedAt: nowPlayingReceivedAt)
            }
        }
        if let data = context[WatchLinkKey.djState] as? Data,
           let value = WatchLinkCodec.decode(WatchDJState.self, from: data) {
            djState = value
            djStateReceivedAt = Date()
        }
        if let data = context[WatchLinkKey.downloads] as? Data,
           let value = WatchLinkCodec.decode(WatchDownloadInventory.self, from: data) {
            downloads = value
        }
        if let data = context[WatchLinkKey.authState] as? Data,
           let value = WatchLinkCodec.decode(WatchAuthState.self, from: data) {
            authState = value
        }
        if let data = context[WatchLinkKey.settings] as? Data,
           let value = WatchLinkCodec.decode(WatchSettingsSnapshot.self, from: data) {
            settings = value
        }
        if let data = context[WatchLinkKey.queue] as? Data,
           let value = WatchLinkCodec.decode(WatchQueueSnapshot.self, from: data) {
            queue = value
        }
        if let data = context[WatchLinkKey.continueOffer] as? Data {
            let offer = WatchLinkCodec.decode(WatchContinueOffer.self, from: data)
            if offer != continueOffer { continueOffer = offer }
        }
        if let data = context[WatchLinkKey.devicePresence] as? Data {
            let presence = WatchLinkCodec.decode(WatchDevicePresence.self, from: data) ?? .empty
            if presence != devicePresence { devicePresence = presence }
        }
        if let data = context[WatchLinkKey.offlineManifest] as? Data,
           let manifest = WatchLinkCodec.decode(WatchOfflineManifest.self, from: data) {
            WatchOfflineStore.shared.apply(manifest)
        }
    }
}

extension WatchLinkClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        let box = WatchPayloadBox(session.receivedApplicationContext)
        let isActivated = state == .activated
        Task { @MainActor in
            self.isActivated = isActivated
            self.syncReachability()
            self.ingest(context: box.values)
            if isActivated {
                self.requestSnapshot()
                WatchOfflineStore.shared.publishInventory()
                self.flushOfflineState()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let track = WatchOfflineStore.adopt(file) else { return }
        Task { @MainActor in WatchOfflineStore.shared.didAdopt(track) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.syncReachability()
            if reachable { self.requestSnapshot() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let box = WatchPayloadBox(context)
        Task { @MainActor in self.ingest(context: box.values) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let box = WatchPayloadBox(userInfo)
        Task { @MainActor in self.ingest(context: box.values) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = WatchPayloadBox(message)
        Task { @MainActor in self.ingest(context: box.values) }
    }
}
