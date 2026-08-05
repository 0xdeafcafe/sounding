import Combine
import CryptoKit
import Foundation
import Network
#if os(iOS)
import UIKit
#endif

enum PolyphonyWire {
    // Keep the shipped service type and PSK derivation stable so builds from
    // before the product rename remain interoperable.
    static let serviceType = "_polyphony._tcp"
    static let serviceDomain = "local."
    static let servicePrefix = "POLY"
    static let maximumFrameBytes = 1_048_576

    struct Snapshot: Codable, Equatable, Sendable {
        let roomID: String
        let revision: UInt64
        let trackID: String?
        let queueTrackIDs: [String]
        let currentIndex: Int
        let position: TimeInterval
        let duration: TimeInterval
        let isPlaying: Bool
        let title: String?
        let artist: String?
        let artworkURL: String?
        /// Leader wall-clock time when `position` was sampled. Optional keeps
        /// rooms interoperable with older builds during rollout.
        let hostTime: TimeInterval?
        /// A future leader-clock instant for discrete play/pause changes.
        let effectiveAt: TimeInterval?
    }

    struct ForeplayProbe: Codable, Equatable, Sendable {
        let id: UUID
        let guestSentAt: TimeInterval
        let leaderReceivedAt: TimeInterval?
        let leaderSentAt: TimeInterval?
    }

    struct Envelope: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case snapshot, sourcingProposal, sourcingConfirmation
            case foreplayPing, foreplayPong
        }
        let kind: Kind
        let snapshot: Snapshot?
        let sourcingProposal: PolyphonySourcing?
        let sourcingConfirmation: PolyphonySourcing?
        let foreplayProbe: ForeplayProbe?

        static func snapshot(_ snapshot: Snapshot) -> Self {
            Self(kind: .snapshot, snapshot: snapshot, sourcingProposal: nil, sourcingConfirmation: nil, foreplayProbe: nil)
        }

        static func sourcingProposal(_ proposal: PolyphonySourcing) -> Self {
            Self(kind: .sourcingProposal, snapshot: nil, sourcingProposal: proposal, sourcingConfirmation: nil, foreplayProbe: nil)
        }

        static func sourcingConfirmation(_ confirmation: PolyphonySourcing) -> Self {
            Self(kind: .sourcingConfirmation, snapshot: nil, sourcingProposal: nil, sourcingConfirmation: confirmation, foreplayProbe: nil)
        }

        static func foreplayPing(_ probe: ForeplayProbe) -> Self {
            Self(kind: .foreplayPing, snapshot: nil, sourcingProposal: nil, sourcingConfirmation: nil, foreplayProbe: probe)
        }

        static func foreplayPong(_ probe: ForeplayProbe) -> Self {
            Self(kind: .foreplayPong, snapshot: nil, sourcingProposal: nil, sourcingConfirmation: nil, foreplayProbe: probe)
        }
    }

    static func secret(sessionID: String, code: String) -> Data {
        Data(SHA256.hash(data: Data("Sounding-Polyphony-v2:\(sessionID):\(code)".utf8)))
    }

    static func serviceName(sessionID: String, leaderName: String) -> String {
        let safeName = leaderName.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_" }
            .prefix(22)
        return "\(servicePrefix)-\(sessionID)-\(String(safeName))"
    }

    static func parseServiceName(_ name: String) -> (sessionID: String, leaderName: String)? {
        let prefix = servicePrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = name.dropFirst(prefix.count)
        guard let divider = remainder.firstIndex(of: "-") else { return nil }
        let sessionID = String(remainder[..<divider])
        let encodedName = String(remainder[remainder.index(after: divider)...])
        guard sessionID.count == 16 else { return nil }
        let leaderName = encodedName.replacingOccurrences(of: "_", with: " ")
        return (sessionID, leaderName.isEmpty ? "Nearby device" : leaderName)
    }
}

private final class PolyphonyChannel: @unchecked Sendable {
    let connection: NWConnection
    var onReady: (@Sendable () -> Void)?
    var onEnvelope: (@Sendable (PolyphonyWire.Envelope) -> Void)?
    var onClose: (@Sendable (String?) -> Void)?

    private let queue: DispatchQueue
    private var buffer = Data()
    private var expectedFrameLength: Int?
    private var didClose = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveNextChunk()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ envelope: PolyphonyWire.Envelope) {
        queue.async { [weak self] in
            guard let self, !self.didClose,
                  let payload = try? JSONEncoder().encode(envelope),
                  payload.count <= PolyphonyWire.maximumFrameBytes else { return }
            var length = UInt32(payload.count).bigEndian
            var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
            frame.append(payload)
            self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(error.localizedDescription) }
            })
        }
    }

    func cancel() {
        connection.cancel()
        finish(nil)
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeFrames()
            }
            if let error {
                self.finish(error.localizedDescription)
            } else if complete {
                self.finish(nil)
            } else if !self.didClose {
                self.receiveNextChunk()
            }
        }
    }

    private func consumeFrames() {
        while true {
            if expectedFrameLength == nil {
                guard buffer.count >= 4 else { return }
                let bytes = Array(buffer.prefix(4))
                let length = (UInt32(bytes[0]) << 24)
                    | (UInt32(bytes[1]) << 16)
                    | (UInt32(bytes[2]) << 8)
                    | UInt32(bytes[3])
                buffer.removeFirst(4)
                guard length > 0, length <= PolyphonyWire.maximumFrameBytes else {
                    finish("Polyphony sent an invalid message.")
                    connection.cancel()
                    return
                }
                expectedFrameLength = Int(length)
            }
            guard let expectedFrameLength, buffer.count >= expectedFrameLength else { return }
            let payload = Data(buffer.prefix(expectedFrameLength))
            buffer.removeFirst(expectedFrameLength)
            self.expectedFrameLength = nil
            guard let envelope = try? JSONDecoder().decode(PolyphonyWire.Envelope.self, from: payload) else {
                finish("Polyphony sent a message this version cannot read.")
                connection.cancel()
                return
            }
            onEnvelope?(envelope)
        }
    }

    private func finish(_ message: String?) {
        guard !didClose else { return }
        didClose = true
        onClose?(message)
    }
}

@MainActor
final class PolyphonyController: ObservableObject {
    static let shared = PolyphonyController()

    struct NearbySession: Identifiable, Hashable {
        let id: String
        let leaderName: String
    }

    enum Mode: Equatable {
        case idle
        case startingLeader
        case leading
        case connecting(leaderName: String)
        case speaker(leaderName: String)
        case failed(message: String)
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var nearbySessions: [NearbySession] = []
    @Published private(set) var joinCode: String?
    @Published private(set) var speakerCount = 0
    @Published private(set) var remoteSnapshot: PolyphonyWire.Snapshot?
    @Published private(set) var sourcing: PolyphonySourcing = .ownAccount

    var isSpeaker: Bool {
        if case .speaker = mode { return true }
        if case .connecting = mode { return true }
        return false
    }

    var isLeading: Bool { mode == .leading || mode == .startingLeader }
    var isActive: Bool { isSpeaker || isLeading }

    private let player = PlayerService.shared
    private let networkQueue = DispatchQueue(label: "red.forbes.sounding.polyphony", qos: .userInitiated)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var speakerChannels: [UUID: PolyphonyChannel] = [:]
    private var guestChannel: PolyphonyChannel?
    private var hostBroadcastTask: Task<Void, Never>?
    private var guestSyncTask: Task<Void, Never>?
    private var guestTransportTask: Task<Void, Never>?
    private var foreplayTask: Task<Void, Never>?
    private var codeRotationTask: Task<Void, Never>?
    private var leaderSessionID: String?
    private var hostRevision: UInt64 = 0
    private var lastHostSignature: LeaderSignature?
    private var lastBroadcastAt = Date.distantPast
    private var lastAppliedRevision: UInt64 = 0
    private var leaderClockOffset: TimeInterval = 0
    private var bestForeplayRTT: TimeInterval = .infinity
    private var borrowedAccessToken: String?
    private var speakerProposals: [UUID: PolyphonySourcing] = [:]
    private var authenticatedSpeakerIDs = Set<UUID>()
    private var failedAttemptsByPeer: [String: [Date]] = [:]
    private var globalFailedAttempts: [Date] = []
    private var lockedPeersUntil: [String: Date] = [:]
    private var globallyLockedUntil: Date?
    private let leaderCanRelayAudio = false
    private let leaderWillShareCredentials = false

    private static let attemptWindow: TimeInterval = 60
    private static let peerAttemptLimit = 5
    private static let globalAttemptLimit = 20
    private static let lockoutDuration: TimeInterval = 5 * 60
    private static let codeRotationInterval: Duration = .seconds(600)

    private init() {}

    func startBrowsing() {
        guard browser == nil, !isLeading else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(
            for: .bonjour(type: PolyphonyWire.serviceType, domain: PolyphonyWire.serviceDomain),
            using: parameters
        )
        browser = newBrowser
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed: [(NearbySession, NWEndpoint)] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint,
                      let session = PolyphonyWire.parseServiceName(name) else { return nil }
                return (NearbySession(id: session.sessionID, leaderName: session.leaderName), result.endpoint)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.endpoints = Dictionary(uniqueKeysWithValues: parsed.map { ($0.0.id, $0.1) })
                self.nearbySessions = parsed.map(\.0).sorted {
                    $0.leaderName.localizedCaseInsensitiveCompare($1.leaderName) == .orderedAscending
                }
            }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { @MainActor [weak self] in
                    self?.fail("Nearby Polyphony sessions could not be found: \(error.localizedDescription)")
                }
            default:
                break
            }
        }
        newBrowser.start(queue: networkQueue)
    }

    func stopBrowsingIfIdle() {
        guard mode == .idle else { return }
        stopBrowser()
    }

    func startLeading(leaderName: String = ProcessInfo.processInfo.hostName) {
        leave(returnsToIdle: true)
        mode = .startingLeader
        let sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        startLeaderListener(sessionID: sessionID, code: code, leaderName: leaderName)
        beginCodeRotation(leaderName: leaderName)
    }

    private func startLeaderListener(sessionID: String, code: String, leaderName: String) {
        let parameters = LinkTLS.makeParameters(
            sessionId: sessionID,
            secret: PolyphonyWire.secret(sessionID: sessionID, code: code),
            info: LinkTLS.polyphonyPSKInfo
        )
        do {
            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: PolyphonyWire.serviceName(sessionID: sessionID, leaderName: leaderName),
                type: PolyphonyWire.serviceType,
                domain: PolyphonyWire.serviceDomain
            )
            listener = newListener
            leaderSessionID = sessionID
            joinCode = code
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.handleListenerState(state) }
            }
            newListener.start(queue: networkQueue)
        } catch {
            fail("Polyphony could not start: \(error.localizedDescription)")
        }
    }

    private func beginCodeRotation(leaderName: String) {
        codeRotationTask?.cancel()
        codeRotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.codeRotationInterval)
                guard !Task.isCancelled, let self, self.isLeading,
                      let sessionID = self.leaderSessionID else { return }
                var nextCode: String
                repeat {
                    nextCode = String(format: "%06d", Int.random(in: 0...999_999))
                } while nextCode == self.joinCode
                // Existing TLS channels remain authenticated. Only the
                // listener is replaced, so new joins need the rotated code.
                self.listener?.cancel()
                self.listener = nil
                self.startLeaderListener(sessionID: sessionID, code: nextCode, leaderName: leaderName)
            }
        }
    }

    func join(_ session: NearbySession, code rawCode: String) {
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            fail("Enter the six-digit code shown by the leader.")
            return
        }
        guard let endpoint = endpoints[session.id] else {
            fail("That Polyphony session is no longer nearby.")
            return
        }
        guestChannel?.cancel()
        guestSyncTask?.cancel()
        lastAppliedRevision = 0
        remoteSnapshot = nil
        mode = .connecting(leaderName: session.leaderName)
        let parameters = LinkTLS.makeParameters(
            sessionId: session.id,
            secret: PolyphonyWire.secret(sessionID: session.id, code: code),
            info: LinkTLS.polyphonyPSKInfo
        )
        let channel = PolyphonyChannel(
            connection: NWConnection(to: endpoint, using: parameters),
            queue: networkQueue
        )
        guestChannel = channel
        channel.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.guestChannel === channel else { return }
                self.mode = .speaker(leaderName: session.leaderName)
                self.stopBrowser()
                self.beginForeplay(on: channel)
                let proposal = PolyphonySourcing.propose(
                    conditions: self.currentDeviceConditions(),
                    deviceClass: .current,
                    isSignedIn: SoundCloudCredentialSource.shared.isAuthenticated
                )
                self.sourcing = proposal
                channel.send(.sourcingProposal(proposal))
            }
        }
        channel.onEnvelope = { [weak self] envelope in
            Task { @MainActor [weak self] in self?.handleGuestEnvelope(envelope) }
        }
        channel.onClose = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.guestChannel === channel else { return }
                self.guestChannel = nil
                self.player.pause()
                self.fail(message.map { "Polyphony disconnected: \($0)" } ?? "The leader ended Polyphony.")
            }
        }
        channel.start()
    }

    func leave() { leave(returnsToIdle: true) }

    private func leave(returnsToIdle: Bool) {
        let wasGuest = isSpeaker
        hostBroadcastTask?.cancel()
        hostBroadcastTask = nil
        codeRotationTask?.cancel()
        codeRotationTask = nil
        guestSyncTask?.cancel()
        guestSyncTask = nil
        guestTransportTask?.cancel()
        guestTransportTask = nil
        foreplayTask?.cancel()
        foreplayTask = nil
        listener?.cancel()
        listener = nil
        speakerChannels.values.forEach { $0.cancel() }
        speakerChannels = [:]
        authenticatedSpeakerIDs = []
        guestChannel?.cancel()
        guestChannel = nil
        leaderSessionID = nil
        joinCode = nil
        speakerCount = 0
        remoteSnapshot = nil
        lastHostSignature = nil
        lastAppliedRevision = 0
        leaderClockOffset = 0
        bestForeplayRTT = .infinity
        sourcing = .ownAccount
        borrowedAccessToken = nil
        speakerProposals = [:]
        if wasGuest { player.pause() }
        if returnsToIdle { mode = .idle }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            mode = .leading
            beginHostBroadcasting()
        case .failed(let error), .waiting(let error):
            fail("Polyphony stopped: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let peerKey = peerAttemptKey(for: connection.endpoint)
        guard isLeading, mayAttemptConnection(from: peerKey) else {
            connection.cancel()
            return
        }
        let id = UUID()
        let channel = PolyphonyChannel(connection: connection, queue: networkQueue)
        speakerChannels[id] = channel
        channel.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let channel = self.speakerChannels[id] else { return }
                self.authenticatedSpeakerIDs.insert(id)
                self.failedAttemptsByPeer[peerKey] = nil
                self.lockedPeersUntil[peerKey] = nil
                self.speakerCount = self.authenticatedSpeakerIDs.count
                if let snapshot = self.makeHostSnapshot() { channel.send(.snapshot(snapshot)) }
            }
        }
        channel.onEnvelope = { [weak self] envelope in
            Task { @MainActor [weak self] in
                guard let self, let channel = self.speakerChannels[id] else { return }
                switch envelope.kind {
                case .sourcingProposal:
                    guard let proposal = envelope.sourcingProposal else { return }
                    self.speakerProposals[id] = proposal
                    let confirmation = PolyphonySourcing.confirm(
                        proposal: proposal,
                        leaderCanRelay: self.leaderCanRelayAudio,
                        leaderWillShareCredentials: self.leaderWillShareCredentials
                    )
                    channel.send(.sourcingConfirmation(confirmation))
                case .foreplayPing:
                    guard let ping = envelope.foreplayProbe else { return }
                    let receivedAt = Date.timeIntervalSinceReferenceDate
                    channel.send(.foreplayPong(.init(
                        id: ping.id,
                        guestSentAt: ping.guestSentAt,
                        leaderReceivedAt: receivedAt,
                        leaderSentAt: Date.timeIntervalSinceReferenceDate
                    )))
                case .snapshot, .sourcingConfirmation, .foreplayPong:
                    break
                }
            }
        }
        channel.onClose = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAuthenticated = self.authenticatedSpeakerIDs.remove(id) != nil
                self.speakerChannels.removeValue(forKey: id)
                self.speakerProposals.removeValue(forKey: id)
                self.speakerCount = self.authenticatedSpeakerIDs.count
                if !wasAuthenticated { self.recordFailedAttempt(from: peerKey) }
            }
        }
        channel.start()
    }

    private func peerAttemptKey(for endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return String(describing: host) }
        return String(describing: endpoint)
    }

    private func mayAttemptConnection(from peer: String, now: Date = Date()) -> Bool {
        purgeAttemptHistory(now: now)
        if let globallyLockedUntil, globallyLockedUntil > now { return false }
        if let lockedUntil = lockedPeersUntil[peer], lockedUntil > now { return false }
        return true
    }

    private func recordFailedAttempt(from peer: String, now: Date = Date()) {
        purgeAttemptHistory(now: now)
        failedAttemptsByPeer[peer, default: []].append(now)
        globalFailedAttempts.append(now)
        if failedAttemptsByPeer[peer, default: []].count >= Self.peerAttemptLimit {
            lockedPeersUntil[peer] = now.addingTimeInterval(Self.lockoutDuration)
            failedAttemptsByPeer[peer] = []
        }
        if globalFailedAttempts.count >= Self.globalAttemptLimit {
            globallyLockedUntil = now.addingTimeInterval(Self.lockoutDuration)
            globalFailedAttempts = []
        }
    }

    private func purgeAttemptHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.attemptWindow)
        globalFailedAttempts.removeAll { $0 < cutoff }
        for peer in Array(failedAttemptsByPeer.keys) {
            failedAttemptsByPeer[peer]?.removeAll { $0 < cutoff }
            if failedAttemptsByPeer[peer]?.isEmpty == true { failedAttemptsByPeer[peer] = nil }
        }
        lockedPeersUntil = lockedPeersUntil.filter { $0.value > now }
        if let globallyLockedUntil, globallyLockedUntil <= now { self.globallyLockedUntil = nil }
    }

    private func beginHostBroadcasting() {
        hostBroadcastTask?.cancel()
        hostBroadcastTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.broadcastHostStateIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Post-TLS timing calibration. The lowest-RTT samples give us a useful
    /// estimate of leader clock offset without microphone access or audible
    /// signalling. Periodic probes adapt when Wi-Fi conditions change.
    private func beginForeplay(on channel: PolyphonyChannel) {
        foreplayTask?.cancel()
        foreplayTask = Task { @MainActor [weak self, weak channel] in
            var sample = 0
            while !Task.isCancelled, let self, let channel, self.guestChannel === channel {
                channel.send(.foreplayPing(.init(
                    id: UUID(),
                    guestSentAt: Date.timeIntervalSinceReferenceDate,
                    leaderReceivedAt: nil,
                    leaderSentAt: nil
                )))
                sample += 1
                // Calibrate quickly on join, then maintain the estimate gently.
                try? await Task.sleep(for: sample < 8 ? .milliseconds(120) : .seconds(2))
            }
        }
    }

    private func broadcastHostStateIfNeeded() {
        guard mode == .leading, !speakerChannels.isEmpty else { return }
        let signature = LeaderSignature(player: player)
        let heartbeatDue = signature.isPlaying && Date().timeIntervalSince(lastBroadcastAt) >= 0.25
        guard signature != lastHostSignature || heartbeatDue, let snapshot = makeHostSnapshot() else { return }
        lastHostSignature = signature
        lastBroadcastAt = Date()
        let envelope = PolyphonyWire.Envelope.snapshot(snapshot)
        speakerChannels.values.forEach { $0.send(envelope) }
    }

    private func makeHostSnapshot() -> PolyphonyWire.Snapshot? {
        guard let roomID = leaderSessionID else { return nil }
        hostRevision &+= 1
        let sampledAt = Date.timeIntervalSinceReferenceDate
        let effectiveAt: TimeInterval? = {
            guard let previous = lastHostSignature, previous.isPlaying != player.isPlaying else { return nil }
            // Allow calibrated guests to execute discrete transport changes on
            // one shared timeline while keeping perceived control latency low.
            return sampledAt + 0.12
        }()
        return PolyphonyWire.Snapshot(
            roomID: roomID,
            revision: hostRevision,
            trackID: player.currentTrack?.id,
            queueTrackIDs: player.queue.map(\.id),
            currentIndex: player.currentIndex,
            position: player.currentTime,
            duration: player.duration,
            isPlaying: player.isPlaying,
            title: player.currentTrack?.title,
            artist: player.currentTrack?.user.displayName,
            artworkURL: player.currentTrack?.artworkURL?.absoluteString,
            hostTime: sampledAt,
            effectiveAt: effectiveAt
        )
    }

    private func handleGuestEnvelope(_ envelope: PolyphonyWire.Envelope) {
        switch envelope.kind {
        case .sourcingConfirmation:
            guard let confirmation = envelope.sourcingConfirmation else { return }
            sourcing = confirmation
            if confirmation != .leaderCredentials { borrowedAccessToken = nil }
        case .sourcingProposal:
            break
        case .snapshot:
            guard let snapshot = envelope.snapshot, snapshot.revision > lastAppliedRevision else { return }
            lastAppliedRevision = snapshot.revision
            remoteSnapshot = snapshot
            applyGuestSnapshot(snapshot)
        case .foreplayPong:
            guard let probe = envelope.foreplayProbe,
                  let leaderReceivedAt = probe.leaderReceivedAt,
                  let leaderSentAt = probe.leaderSentAt else { return }
            let guestReceivedAt = Date.timeIntervalSinceReferenceDate
            let rtt = max(0, (guestReceivedAt - probe.guestSentAt) - (leaderSentAt - leaderReceivedAt))
            let offset = ((leaderReceivedAt - probe.guestSentAt) + (leaderSentAt - guestReceivedAt)) / 2
            if rtt <= bestForeplayRTT * 1.15 {
                leaderClockOffset = bestForeplayRTT.isFinite
                    ? leaderClockOffset * 0.75 + offset * 0.25
                    : offset
                bestForeplayRTT = min(bestForeplayRTT, rtt)
            }
        case .foreplayPing:
            break
        }
    }

    private func applyGuestSnapshot(_ snapshot: PolyphonyWire.Snapshot) {
        guard let trackID = snapshot.trackID else {
            guestSyncTask?.cancel()
            guestTransportTask?.cancel()
            player.pause()
            return
        }
        let receivedAt = Date()
        if player.currentTrack?.id == trackID {
            scheduleOrReconcileGuestTransport(snapshot, receivedAt: receivedAt)
            return
        }
        guestSyncTask?.cancel()
        guestSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let track = try await self.fetchTrackForGuestPlayback(id: trackID)
                guard !Task.isCancelled, self.remoteSnapshot?.trackID == trackID, self.isSpeaker else { return }
                await self.player.adoptHandoff(
                    track: track,
                    queue: [track],
                    index: 0,
                    position: self.projectedPosition(snapshot, receivedAt: receivedAt),
                    autoplay: snapshot.isPlaying
                )
                self.scheduleOrReconcileGuestTransport(snapshot, receivedAt: receivedAt)
            } catch {
                self.fail("This device could not play \(snapshot.title ?? "the leader's track") with its SoundCloud account.")
            }
        }
    }

    private func scheduleOrReconcileGuestTransport(_ snapshot: PolyphonyWire.Snapshot, receivedAt: Date) {
        guestTransportTask?.cancel()
        let guestEffectiveAt = snapshot.effectiveAt.map { $0 - leaderClockOffset }
        let delay = guestEffectiveAt.map { $0 - Date.timeIntervalSinceReferenceDate } ?? 0
        guard delay > 0.006 else {
            reconcileGuestTransport(snapshot, receivedAt: receivedAt)
            return
        }
        guestTransportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcileGuestTransport(snapshot, receivedAt: receivedAt)
        }
    }

    private func fetchTrackForGuestPlayback(id trackID: String) async throws -> Track {
        switch sourcing {
        case .ownAccount:
            return try await SoundCloudAPI.shared.getTrack(id: trackID)
        case .leaderCredentials:
            return try await SoundCloudAPI.shared.getTrack(id: trackID)
        case .leaderRelay:
            return try await SoundCloudAPI.shared.getTrack(id: trackID)
        }
    }

    private func currentDeviceConditions() -> DeviceConditions {
        var isPluggedIn = false
        var batteryFraction: Double?
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        isPluggedIn = state == .charging || state == .full
        let level = UIDevice.current.batteryLevel
        batteryFraction = level >= 0 ? Double(level) : nil
        #endif
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let isOnWiFi = guestChannel?.connection.currentPath?.usesInterfaceType(.wifi) ?? true
        return DeviceConditions(
            isPluggedIn: isPluggedIn,
            batteryFraction: batteryFraction,
            isOnWiFi: isOnWiFi,
            isLowPowerMode: isLowPowerMode
        )
    }

    private func reconcileGuestTransport(_ snapshot: PolyphonyWire.Snapshot, receivedAt: Date) {
        let target = projectedPosition(snapshot, receivedAt: receivedAt)
        let drift = target - player.currentTime
        if abs(drift) > 0.35 {
            player.seek(to: target)
        } else if snapshot.isPlaying, abs(drift) > 0.025 {
            // Correct ordinary Wi-Fi jitter inaudibly. At most ±2% for under a
            // second; only genuinely large divergence causes a hard seek.
            let rate = 1 + min(0.02, max(-0.02, drift * 0.18))
            player.nudgeSynchronizationRate(rate, for: 0.8)
        } else {
            player.resetSynchronizationRate()
        }
        if snapshot.isPlaying != player.isPlaying {
            snapshot.isPlaying ? player.play() : player.pause()
        }
    }

    private func projectedPosition(_ snapshot: PolyphonyWire.Snapshot, receivedAt: Date) -> TimeInterval {
        guard snapshot.isPlaying else { return max(0, snapshot.position) }
        let elapsed: TimeInterval
        if let hostTime = snapshot.hostTime {
            let estimatedLeaderNow = Date.timeIntervalSinceReferenceDate + leaderClockOffset
            elapsed = max(0, estimatedLeaderNow - hostTime)
        } else {
            elapsed = Date().timeIntervalSince(receivedAt) + 0.04
        }
        return min(max(0, snapshot.duration), max(0, snapshot.position + elapsed))
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        nearbySessions = []
        endpoints = [:]
    }

    private func fail(_ message: String) { mode = .failed(message: message) }

    private struct LeaderSignature: Equatable {
        let trackID: String?
        let queueTrackIDs: [String]
        let currentIndex: Int
        let isPlaying: Bool
        let durationBucket: Int

        @MainActor
        init(player: PlayerService) {
            trackID = player.currentTrack?.id
            queueTrackIDs = player.queue.map(\.id)
            currentIndex = player.currentIndex
            isPlaying = player.isPlaying
            durationBucket = Int(player.duration.rounded())
        }
    }
}
