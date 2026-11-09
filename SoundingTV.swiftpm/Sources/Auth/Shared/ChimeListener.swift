import Foundation
import AVFoundation
import Network
import Combine
import os

private final class ChimeDecodePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "red.forbes.sounding.chime-decoder", qos: .userInitiated)
    private var decoder: ChimeDecoder?
    private let deliver: @Sendable ([ChimeDecoder.Detection]) -> Void

    init(sampleRate: Double, deliver: @escaping @Sendable ([ChimeDecoder.Detection]) -> Void) {
        self.deliver = deliver
        queue.sync { decoder = ChimeDecoder(sampleRate: sampleRate) }
    }

    func consume(_ samples: [Float]) {
        queue.async { [self] in
            guard let decoder else { return }
            let detections = decoder.process(samples)
            if !detections.isEmpty { deliver(detections) }
        }
    }

    func close() {
        queue.async { [self] in decoder = nil }
    }
}

final class ChimeInputLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func record(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        let normalised = min(1, max(0, (decibels + 70) / 60))
        lock.lock()
        value = normalised
        lock.unlock()
    }

    var current: Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class ChimeListener {
    enum Permission {
        case undetermined
        case granted
        case denied
    }

    enum Failure: Error {
        case noInput
    }

    static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var onDetection: ((ChimeDecoder.Detection) -> Void)?

    private let engine = AVAudioEngine()
    private var pipeline: ChimeDecodePipeline?
    let level = ChimeInputLevel()
    private(set) var isRunning = false

    #if os(iOS)
    private var previousSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    #endif

    func start() throws {
        guard !isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        previousSession = (session.category, session.mode, session.categoryOptions)
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPreferredSampleRate(48_000)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            restoreSession()
            throw Failure.noInput
        }

        let pipeline = ChimeDecodePipeline(sampleRate: format.sampleRate) { [weak self] detections in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                for detection in detections { self.onDetection?(detection) }
            }
        }
        self.pipeline = pipeline
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(feeding: pipeline, level: level))

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            pipeline.close()
            self.pipeline = nil
            restoreSession()
            throw error
        }
        isRunning = true
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        Log.link.info("[ChimeListener] listening at \(format.sampleRate, privacy: .public) Hz, category=\(AVAudioSession.sharedInstance().category.rawValue, privacy: .public) mode=\(AVAudioSession.sharedInstance().mode.rawValue, privacy: .public) input=\(route, privacy: .public)")
        #else
        Log.link.info("[ChimeListener] listening at \(format.sampleRate, privacy: .public) Hz")
        #endif
    }

    nonisolated private static func tapBlock(feeding pipeline: ChimeDecodePipeline, level: ChimeInputLevel) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            level.record(samples)
            pipeline.consume(Array(samples))
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pipeline?.close()
        pipeline = nil
        restoreSession()
    }

    private func restoreSession() {
        #if os(iOS)
        guard let previousSession else { return }
        try? AVAudioSession.sharedInstance().setCategory(
            previousSession.category,
            mode: previousSession.mode,
            options: previousSession.options
        )
        self.previousSession = nil
        #endif
    }
}

@MainActor
final class ChimeLinkHandshake {
    enum State: Equatable {
        case connecting
        case verified(name: String, kind: DeviceClass)
        case confirming
        case succeeded(sessionId: String, secret: Data, tvName: String)
        case failed
    }

    let offer: LinkOfferBrowser.Offer
    let code: ChimeCode
    var onChange: ((State) -> Void)?

    private(set) var state: State = .connecting {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private var connection: NWConnection?
    private var framer = MessageFramer()
    private var phoneNonce: Data?
    private var session: ChimeLinkCrypto.Session?
    private var timeout: Task<Void, Never>?

    init(offer: LinkOfferBrowser.Offer, code: ChimeCode) {
        self.offer = offer
        self.code = code
    }

    func start() {
        guard let nonce = ChimeLinkCrypto.makeNonce() else {
            state = .failed
            return
        }
        phoneNonce = nonce

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: offer.endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
        connection.start(queue: .main)
        arm(seconds: 10)
    }

    func confirm() {
        guard case .verified = state, let session else { return }
        state = .confirming
        send(.chime(.chimeConfirm, sessionId: offer.sessionIdPrefix, payload: ChimeLinkPayload(
            version: ChimeLinkCrypto.protocolVersion,
            confirmationBase64: ChimeLinkCrypto.confirmation(session, role: .phone).base64EncodedString()
        )))
        arm(seconds: 15)
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
    }

    private func fail() {
        cancel()
        if case .succeeded = state { return }
        state = .failed
    }

    private func arm(seconds: Double) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            switch self.state {
            case .connecting, .confirming: self.fail()
            default: break
            }
        }
    }

    private func handle(_ update: NWConnection.State) {
        switch update {
        case .ready:
            guard let phoneNonce else { return fail() }
            send(.chime(.chimeHello, sessionId: offer.sessionIdPrefix, payload: ChimeLinkPayload(
                version: ChimeLinkCrypto.protocolVersion,
                nonceBase64: phoneNonce.base64EncodedString()
            )))
            receive()
        case .failed, .cancelled:
            switch state {
            case .connecting, .confirming: fail()
            default: break
            }
        default:
            break
        }
    }

    private func send(_ message: TokenTransferMessage) {
        guard let data = try? message.framed() else { return fail() }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() { self.handle(message) }
                }
                if error != nil || isComplete {
                    switch self.state {
                    case .connecting, .confirming: self.fail()
                    default: break
                    }
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: TokenTransferMessage) {
        switch (message.type, state) {
        case (.chimeHelloAck, .connecting):
            guard let phoneNonce,
                  let transcript = ChimeLinkCrypto.transcript(from: message.chime, phoneNonce: phoneNonce, sessionIdPrefix: offer.sessionIdPrefix),
                  let confirmation = message.chime?.confirmationBase64.flatMap({ Data(base64Encoded: $0) }),
                  let session = ChimeLinkCrypto.session(code: code, transcript: transcript),
                  ChimeLinkCrypto.verifyConfirmation(confirmation, session: session, role: .tv),
                  let kind = DeviceClass(rawValue: transcript.tvKind) else {
                return fail()
            }
            self.session = session
            timeout?.cancel()
            state = .verified(name: transcript.tvName, kind: kind)

        case (.chimeCredentials, .confirming):
            guard let session,
                  let sealed = message.chime?.sealedBase64.flatMap({ Data(base64Encoded: $0) }),
                  let opened = try? ChimeLinkCrypto.open(sealed, session: session),
                  let decoded = try? JSONDecoder().decode(LinkOffer.self, from: opened),
                  !decoded.isExpired,
                  decoded.sessionId == session.transcript.sessionId,
                  decoded.tvName == session.transcript.tvName,
                  let secret = decoded.secret else {
                return fail()
            }
            cancel()
            state = .succeeded(sessionId: decoded.sessionId, secret: secret, tvName: decoded.tvName)

        case (.error, _):
            fail()

        default:
            break
        }
    }
}

@MainActor
final class ChimePlayRequest {
    private var connection: NWConnection?
    private var framer = MessageFramer()
    private var timeout: Task<Void, Never>?
    private var sessionIdPrefix = ""
    private var completion: ((Bool) -> Void)?

    func send(to offer: LinkOfferBrowser.Offer, completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        sessionIdPrefix = offer.sessionIdPrefix
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: offer.endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.finish(false)
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        completion = nil
        framer = MessageFramer()
    }

    private func finish(_ played: Bool) {
        let completion = self.completion
        cancel()
        completion?(played)
    }

    private func handle(_ update: NWConnection.State) {
        switch update {
        case .ready:
            let request = TokenTransferMessage.chime(
                .chimePlayRequest,
                sessionId: sessionIdPrefix,
                payload: ChimeLinkPayload(version: ChimeLinkCrypto.protocolVersion)
            )
            guard let data = try? request.framed() else { return finish(false) }
            connection?.send(content: data, completion: .contentProcessed { _ in })
            receive()
        case .failed, .cancelled:
            finish(false)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        switch message.type {
                        case .chimePlaying:
                            self.finish(true)
                            return
                        case .error:
                            self.finish(false)
                            return
                        default: break
                        }
                    }
                }
                if error != nil || isComplete {
                    self.finish(false)
                } else {
                    self.receive()
                }
            }
        }
    }
}

@MainActor
final class NearbyTVSignIn: ObservableObject {
    enum Phase: Equatable {
        case idle
        case needsPermission
        case permissionDenied
        case listening
        case checking
        case found(name: String, kind: DeviceClass)
        case signingIn(name: String)
        case failed(String)
    }

    struct Linked: Equatable {
        let sessionId: String
        let secret: Data
        let name: String
        let kind: DeviceClass
    }

    private struct Attempt: Hashable {
        let sessionIdPrefix: String
        let code: ChimeCode
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var linked: Linked?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var isHearingNothing = false

    static let quietHint: TimeInterval = 20
    private var levelTask: Task<Void, Never>?
    @Published var invitedName: String?
    var preferredRendezvous: String?
    var preferredSessionIdPrefix: String?

    var invitedOffer: LinkOfferBrowser.Offer? {
        guard let preferredRendezvous else { return nil }
        return SignInRequest.matchingOffer(preferredRendezvous, in: browser.offers, key: \.rendezvous)
    }

    var nearbyOffers: [LinkOfferBrowser.Offer] { browser.offers.filter { $0.kind == .tv } }

    var localNetworkDenied: Bool { browser.localNetworkDenied }

    private let browser: LinkOfferBrowser
    private let listener = ChimeListener()
    private var handshakes: [ChimeLinkHandshake] = []
    private var chosen: ChimeLinkHandshake?
    private var chosenKind: DeviceClass?
    private var heard: [ChimeCode: Date] = [:]
    private var attempted: Set<Attempt> = []
    private var budget = ChimeAttemptBudget()
    private var offersSubscription: AnyCancellable?
    private let forcedPhase: Phase?

    init(browser: LinkOfferBrowser, forcedPhase: Phase? = nil) {
        self.browser = browser
        self.forcedPhase = forcedPhase
        listener.onDetection = { [weak self] detection in self?.didHear(detection.code) }
    }

    func start() {
        if let forcedPhase {
            phase = forcedPhase
            return
        }
        linked = nil
        switch ChimeListener.permission {
        case .undetermined: phase = .needsPermission
        case .denied: phase = .permissionDenied
        case .granted: beginListening()
        }
    }

    func continueAfterPriming() {
        guard forcedPhase == nil else { return }
        Task {
            let granted = await ChimeListener.requestPermission()
            if granted {
                beginListening()
            } else {
                phase = .permissionDenied
            }
        }
    }

    func signIn() {
        guard let chosen, case .found(let name, _) = phase else { return }
        phase = .signingIn(name: name)
        chosen.confirm()
    }

    func retry() {
        stop()
        start()
    }

    func stop() {
        listener.stop()
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
        isHearingNothing = false
        offersSubscription = nil
        handshakes.forEach { $0.cancel() }
        handshakes = []
        chosen?.cancel()
        chosen = nil
        chosenKind = nil
        heard = [:]
        attempted = []
        budget.reset()
        if forcedPhase == nil { phase = .idle }
    }

    private func beginListening() {
        browser.startIfNeeded()
        offersSubscription = browser.$offers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.tryPendingCodes()
            }
        do {
            try listener.start()
            phase = .listening
            startLevelUpdates()
        } catch {
            Log.link.error("[NearbyTVSignIn] couldn't listen: \(error.localizedDescription, privacy: .public)")
            phase = .failed("This device can't listen right now. Use the QR code instead.")
        }
    }

    private func startLevelUpdates() {
        levelTask?.cancel()
        let started = Date()
        isHearingNothing = false
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.listener.isRunning else { return }
                self.inputLevel = self.listener.level.current
                if !self.isHearingNothing, self.phase == .listening, Date().timeIntervalSince(started) > Self.quietHint {
                    Log.link.info("[NearbyTVSignIn] no code after \(Self.quietHint, privacy: .public) s; \(self.browser.offers.count, privacy: .public) offers, level \(self.inputLevel, privacy: .public)")
                    self.isHearingNothing = true
                }
            }
        }
    }

    private func didHear(_ code: ChimeCode) {
        guard chosen == nil else { return }
        Log.link.info("[NearbyTVSignIn] heard a code; \(self.browser.offers.count, privacy: .public) offers on the network")
        heard[code] = Date()
        tryPendingCodes()
    }

    private func tryPendingCodes() {
        guard chosen == nil, listener.isRunning else { return }
        heard = heard.filter { Date().timeIntervalSince($0.value) < 30 }
        for code in heard.keys {
            for offer in orderedOffers {
                let key = Attempt(sessionIdPrefix: offer.sessionIdPrefix, code: code)
                guard !attempted.contains(key) else { continue }
                guard budget.admit(code, active: handshakes.count, at: .now) else { continue }
                attempted.insert(key)
                let handshake = ChimeLinkHandshake(offer: offer, code: code)
                handshake.onChange = { [weak self, weak handshake] state in
                    guard let self, let handshake else { return }
                    self.handshake(handshake, changedTo: state)
                }
                handshakes.append(handshake)
                handshake.start()
            }
        }
        if phase == .listening, !handshakes.isEmpty { phase = .checking }
    }

    private var orderedOffers: [LinkOfferBrowser.Offer] {
        let isPreferred: (LinkOfferBrowser.Offer) -> Bool = { [preferredRendezvous, preferredSessionIdPrefix] offer in
            if let preferredSessionIdPrefix, offer.sessionIdPrefix == preferredSessionIdPrefix { return true }
            if let preferredRendezvous, offer.rendezvous == preferredRendezvous { return true }
            return false
        }
        return browser.offers.filter(isPreferred) + browser.offers.filter { !isPreferred($0) }
    }

    private func handshake(_ handshake: ChimeLinkHandshake, changedTo state: ChimeLinkHandshake.State) {
        switch state {
        case .verified(let name, let kind):
            guard chosen == nil else {
                handshake.cancel()
                return
            }
            chosen = handshake
            chosenKind = kind
            handshakes.filter { $0 !== handshake }.forEach { $0.cancel() }
            handshakes = []
            listener.stop()
            phase = .found(name: name, kind: kind)

        case .succeeded(let sessionId, let secret, let tvName):
            listener.stop()
            guard case .signingIn = phase, let kind = chosenKind else { return }
            linked = Linked(sessionId: sessionId, secret: secret, name: tvName, kind: kind)

        case .failed:
            Log.link.error("[NearbyTVSignIn] handshake with \(handshake.offer.sessionIdPrefix, privacy: .public) failed")
            if handshake === chosen {
                chosen = nil
                chosenKind = nil
                phase = .failed("Couldn't finish linking. Make sure Sounding is still open on the Apple TV, then try again.")
                return
            }
            handshakes.removeAll { $0 === handshake }
            if handshakes.isEmpty, chosen == nil, phase == .checking { phase = .listening }
            tryPendingCodes()

        case .connecting, .confirming:
            break
        }
    }
}
