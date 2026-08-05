import Foundation
import Combine
import WatchConnectivity
import os

private struct WatchPayloadBox: @unchecked Sendable {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
}

@MainActor
final class WatchLinkClient: NSObject, ObservableObject {
    static let shared = WatchLinkClient()

    @Published private(set) var nowPlaying: WatchNowPlaying = .idle
    @Published private(set) var djState: WatchDJState = .off
    @Published private(set) var downloads: WatchDownloadInventory = .empty
    @Published private(set) var authState: WatchAuthState = .unknown
    @Published private(set) var settings: WatchSettingsSnapshot = .empty
    @Published private(set) var polyphonyState: WatchPolyphonyState = .idle
    @Published private(set) var isReachable = false
    @Published private(set) var isCompanionInstalled = false

    private(set) var nowPlayingReceivedAt = Date()
    private(set) var djStateReceivedAt = Date()

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            syncReachability()
            ingest(context: session.receivedApplicationContext)
        }
    }

    var canReachPhone: Bool { isReachable }

    func send(_ command: WatchCommand) {
        guard let session, session.activationState == .activated else { return }
        let message = WatchLinkCodec.message(command.kind, command)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                Log.link.error("[WatchLink] send failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            session.transferUserInfo(message)
        }
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

    func selectOutput(_ output: DeviceClass) {
        send(WatchCommand(kind: .output, output: output))
    }

    func polyphony(_ action: WatchPolyphonyAction) {
        send(WatchCommand(kind: .polyphony, polyphony: action))
    }

    func play(trackId: String, collectionId: String? = nil) {
        send(WatchCommand(kind: .play, trackId: trackId, collectionId: collectionId))
    }

    func play(collectionId: String, shuffled: Bool = false) {
        send(WatchCommand(kind: .play, collectionId: collectionId, shuffled: shuffled))
    }

    func enqueue(trackId: String, action: WatchQueueAction) {
        send(WatchCommand(kind: .queue, queue: action, trackId: trackId))
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
            var resumed = false
            session.sendMessage(message) { reply in
                guard !resumed else { return }
                resumed = true
                guard WatchLinkCodec.kind(of: reply) == .sessionOffer,
                      let offer = WatchLinkCodec.payload(WatchSessionOffer.self, from: reply)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: offer)
            } errorHandler: { error in
                guard !resumed else { return }
                resumed = true
                Log.link.error("[WatchLink] session request failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: nil)
            }
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
        guard let session else { return }
        isReachable = session.isReachable
        isCompanionInstalled = session.isCompanionAppInstalled
    }

    private func ingest(context: [String: Any]) {
        if let data = context[WatchLinkKey.nowPlaying] as? Data,
           let value = WatchLinkCodec.decode(WatchNowPlaying.self, from: data) {
            nowPlaying = value
            nowPlayingReceivedAt = Date()
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
        if let data = context[WatchLinkKey.polyphony] as? Data,
           let value = WatchLinkCodec.decode(WatchPolyphonyState.self, from: data) {
            polyphonyState = value
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
            self.syncReachability()
            self.ingest(context: box.values)
            if isActivated { self.requestSnapshot() }
        }
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
