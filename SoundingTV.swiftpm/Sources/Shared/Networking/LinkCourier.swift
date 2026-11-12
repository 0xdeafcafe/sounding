import Foundation
import Network

@MainActor
final class LinkCourier {
    enum Outcome: Equatable {
        case delivered
        case status(needsSignIn: Bool)
        case revoked(explicit: Bool)
        case unreachable(CompanionFailure)
    }

    private let channel: CompanionChannel
    private let sessionId: String
    private let secret: Data
    private let outgoing: TokenTransferMessage?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeout: Task<Void, Never>?

    private init(endpoint: NWEndpoint, sessionId: String, secret: Data, outgoing: TokenTransferMessage?) {
        channel = CompanionChannel(to: endpoint, sessionId: sessionId, secret: secret, keepalive: false)
        self.sessionId = sessionId
        self.secret = secret
        self.outgoing = outgoing
    }

    static func deliver(
        _ message: TokenTransferMessage,
        to endpoint: NWEndpoint,
        sessionId: String,
        secret: Data,
        timeout: Duration = .seconds(8)
    ) async -> Outcome {
        await LinkCourier(endpoint: endpoint, sessionId: sessionId, secret: secret, outgoing: message).run(timeout: timeout)
    }

    static func probe(
        _ endpoint: NWEndpoint,
        sessionId: String,
        secret: Data,
        timeout: Duration = .seconds(6)
    ) async -> Outcome {
        await LinkCourier(endpoint: endpoint, sessionId: sessionId, secret: secret, outgoing: nil).run(timeout: timeout)
    }

    private func run(timeout duration: Duration) async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled, let self else { return }
                self.finish(.unreachable(CompanionFailure.classify(self.channel.lastError, fallback: .notFound)))
            }
            channel.start(
                onEvent: { [weak self] event in self?.handle(event) },
                onMessage: { [weak self] message in self?.handle(message) }
            )
        }
    }

    private func handle(_ event: CompanionChannel.Event) {
        switch event {
        case .ready:
            if let outgoing { channel.send(outgoing) }
        case .waiting:
            break
        case .failed:
            finish(.unreachable(CompanionFailure.classify(channel.lastError)))
        case .closed:
            finish(.unreachable(.closed))
        }
    }

    private func handle(_ message: TokenTransferMessage) {
        guard message.sessionId == sessionId else { return }
        switch message.type {
        case .linkRevoke:
            guard let revoke = message.verifiedRevoke(sessionId: sessionId, secret: secret) else { return }
            channel.send(.acknowledgment(sessionId: sessionId)) { [weak self] _ in
                self?.finish(.revoked(explicit: revoke.isExplicitUnlink))
            }
        case .acknowledgment where outgoing != nil:
            finish(.delivered)
        case .deviceStatus where outgoing == nil:
            guard let status = message.deviceStatus,
                  status.verify(sessionId: sessionId, secret: secret),
                  status.isFresh() else { return }
            finish(.status(needsSignIn: status.needsSignIn))
        default:
            break
        }
    }

    private func finish(_ outcome: Outcome) {
        timeout?.cancel()
        timeout = nil
        channel.cancel()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}
