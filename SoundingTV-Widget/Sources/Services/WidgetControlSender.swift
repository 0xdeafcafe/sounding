import Foundation
import Network

@MainActor
final class WidgetControlSender {

    enum SendError: LocalizedError {
        case notPaired
        case discoveryFailed(String)
        case connectionFailed(String)
        case rejected(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notPaired:
                return "This iPhone isn't paired with an Apple TV."
            case .discoveryFailed(let message):
                return "Couldn't find the Apple TV: \(message)"
            case .connectionFailed(let message):
                return "Lost the connection to the Apple TV: \(message)"
            case .rejected(let message):
                return message
            case .timedOut:
                return "The Apple TV didn't respond in time."
            }
        }
    }

    private nonisolated(unsafe) var browser: NWBrowser?
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?

    private var framer = MessageFramer()
    private var continuation: CheckedContinuation<PlaybackStatePayload, Error>?
    private var playbackStatesSeen = 0

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        timeoutTask?.cancel()
        browser?.cancel()
        connection?.cancel()
    }

    func send(
        _ type: MessageType,
        deck: ControlDeck = .none,
        parameter: ControlParameter = .none,
        value: Double = 0,
        value2: Double = 0,
        timeout: Duration = .seconds(5)
    ) async throws -> PlaybackStatePayload {
        guard let link = LinkedCompanionStore.load(), let secret = link.secret else {
            throw SendError.notPaired
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(SendError.timedOut))
            }
            self.startDiscovery(
                sessionId: link.sessionId, secret: secret,
                type: type, deck: deck, parameter: parameter, value: value, value2: value2
            )
        }
    }

    private func startDiscovery(
        sessionId: String, secret: Data,
        type: MessageType, deck: ControlDeck, parameter: ControlParameter, value: Double, value2: Double
    ) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let newBrowser = NWBrowser(
            for: .bonjour(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )

        let prefix = String(sessionId.prefix(8))

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard name.hasPrefix(BonjourConstants.companionServiceName), name.contains(prefix) else { continue }

                    self.browser?.cancel()
                    self.browser = nil

                    self.connect(
                        to: result.endpoint, sessionId: sessionId, secret: secret,
                        type: type, deck: deck, parameter: parameter, value: value, value2: value2
                    )
                    return
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard case .failed(let error) = state else { return }
                self?.finish(.failure(SendError.discoveryFailed(error.localizedDescription)))
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)
    }

    private func connect(
        to endpoint: NWEndpoint, sessionId: String, secret: Data,
        type: MessageType, deck: ControlDeck, parameter: ControlParameter, value: Double, value2: Double
    ) {
        framer = MessageFramer()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false

        let newConnection = NWConnection(to: endpoint, using: parameters)
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, newConnection === self.connection else { return }
                switch state {
                case .ready:
                    self.receive(on: newConnection, sessionId: sessionId, secret: secret)
                    self.sendCommand(
                        on: newConnection, sessionId: sessionId, secret: secret,
                        type: type, deck: deck, parameter: parameter, value: value, value2: value2
                    )
                case .failed(let error):
                    self.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    self.connection = nil
                default:
                    break
                }
            }
        }

        connection = newConnection
        newConnection.start(queue: .main)
    }

    private func sendCommand(
        on connection: NWConnection, sessionId: String, secret: Data,
        type: MessageType, deck: ControlDeck, parameter: ControlParameter, value: Double, value2: Double
    ) {
        let control = ControlCommandPayload.create(
            type: type, deck: deck, parameter: parameter, value: value, value2: value2,
            sequence: 0,
            sessionId: sessionId, secret: secret
        )

        guard let data = try? TokenTransferMessage
            .controlCommand(type, sessionId: sessionId, control: control)
            .framed()
        else {
            finish(.failure(SendError.connectionFailed("Failed to encode command")))
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
            }
        })
    }

    private func receive(on connection: NWConnection, sessionId: String, secret: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }

                if let error {
                    self.finish(.failure(SendError.connectionFailed(error.localizedDescription)))
                    return
                }

                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        if self.handle(message, sessionId: sessionId, secret: secret) {
                            return // Resolved — no need to keep reading.
                        }
                    }
                }

                if isComplete {
                    self.finish(.failure(SendError.connectionFailed("The Apple TV closed the connection.")))
                } else {
                    self.receive(on: connection, sessionId: sessionId, secret: secret)
                }
            }
        }
    }

    private func handle(_ message: TokenTransferMessage, sessionId: String, secret: Data) -> Bool {
        guard message.sessionId == sessionId else { return false }

        switch message.type {
        case .error:
            finish(.failure(SendError.rejected(message.error ?? "The Apple TV rejected the command.")))
            return true

        case .playbackState:
            guard let playback = message.playback,
                  playback.verify(sessionId: sessionId, secret: secret) else {
                return false // Unsigned or forged — silently drop.
            }
            playbackStatesSeen += 1
            guard playbackStatesSeen >= 2 else { return false }
            finish(.success(playback))
            return true

        default:
            return false // `queue_state`, `dj_state`, etc. — not what this client is waiting for.
        }
    }

    private func finish(_ result: Result<PlaybackStatePayload, Error>) {
        guard let continuation else { return } // Already resolved.
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        continuation.resume(with: result)
    }
}
