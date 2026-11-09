import AppKit
import Combine
import Foundation

enum DJPlayersConnectionState: Equatable {
    case disconnected
    case priming
    case looking
    case connected
    case noPlayers
    case notAllowed
    case rekordboxRunning
    case portsInUse
    case noNetwork
    case numberTaken(Int)

    var isSessionActive: Bool {
        switch self {
        case .looking, .connected, .noPlayers, .notAllowed: return true
        default: return false
        }
    }
}

@MainActor
final class DJPlayersController: ObservableObject {
    static let shared = DJPlayersController()

    static let localNetworkSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    static let setlistBarChoices = [8, 16, 32, 64]
    static let noPlayersDelay: Duration = .seconds(6)
    static let lookupRetryInterval: TimeInterval = 5

    private enum Key {
        static let interface = "djPlayers.interface"
        static let virtualDeck = "djPlayers.virtualDeck"
        static let virtualDeckNumber = "djPlayers.virtualDeckNumber"
        static let recordSetlists = "djPlayers.recordSetlists"
        static let setlistBars = "djPlayers.setlistBars"
        static let primed = "djPlayers.localNetworkPrimed"
        static let syncDecks = "djPlayers.syncDecks"
    }

    @Published private(set) var state: DJPlayersConnectionState = .disconnected
    @Published private(set) var interfaces: [DJLinkInterface] = []
    @Published private(set) var players: [DJPlayer] = []
    @Published private(set) var ownNumber: Int?
    @Published private(set) var isClaimingNumber = false
    @Published private(set) var isVirtualDeckMaster = false
    @Published private(set) var tempo: DJPlayersTempoReference?
    @Published private(set) var trackInfo: [DJPlayerTrackKey: DJPlayersTrackInfo] = [:]
    @Published private(set) var recordingTitle: String?
    @Published private(set) var recordedCount = 0
    @Published private(set) var rigHasCDJ3000 = false

    @Published var selectedInterfaceName: String? {
        didSet {
            guard selectedInterfaceName != oldValue else { return }
            guard !isFixture else { return }
            defaults.set(selectedInterfaceName, forKey: Key.interface)
            if state.isSessionActive { restartSession() }
        }
    }

    @Published var usesVirtualDeck: Bool {
        didSet {
            guard usesVirtualDeck != oldValue else { return }
            guard !isFixture else { return }
            defaults.set(usesVirtualDeck, forKey: Key.virtualDeck)
            if state.isSessionActive || isNumberTaken { restartSession() }
        }
    }

    @Published var virtualDeckNumber: Int {
        didSet {
            guard virtualDeckNumber != oldValue else { return }
            guard !isFixture else { return }
            defaults.set(virtualDeckNumber, forKey: Key.virtualDeckNumber)
            if usesVirtualDeck, state.isSessionActive || isNumberTaken { restartSession() }
        }
    }

    @Published var recordsSetlists: Bool {
        didSet {
            guard !isFixture else { return }
            defaults.set(recordsSetlists, forKey: Key.recordSetlists)
        }
    }

    @Published var setlistBars: Int {
        didSet {
            recorder.minimumBars = setlistBars
            guard !isFixture else { return }
            defaults.set(setlistBars, forKey: Key.setlistBars)
        }
    }

    @Published var syncsDecks: Bool {
        didSet {
            guard syncsDecks != oldValue else { return }
            guard !isFixture else { return }
            defaults.set(syncsDecks, forKey: Key.syncDecks)
            runtime?.setSynced(syncsDecks)
            updateFollower()
        }
    }

    var trackLookup: any DJPlayersTrackLookup = DJPlayersController.liveLookup() {
        didSet {
            trackInfo = [:]
            lookupsInFlight = []
            lookupMisses = [:]
            resolveTitles()
        }
    }

    private let defaults: UserDefaults
    private var runtime: DJLinkRuntime?
    private var wantsConnection = false
    private var sessionInterface: DJLinkInterface?
    private var noPlayersTask: Task<Void, Never>?
    private var interfaceTimer: Timer?
    private var followerTimer: Timer?
    private var deckCancellable: AnyCancellable?
    private var lastDeckSnapshot: DJVirtualDeckSnapshot?
    private var recorder: DJPlayersSetlistRecorder
    private var setlistBuilder: DJPlayersSetlistBuilder?
    private var lookupsInFlight: Set<DJPlayerTrackKey> = []
    private var lookupMisses: [DJPlayerTrackKey: TimeInterval] = [:]
    private var sticksCancellable: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wasConnectedBeforeSleep = false
    private var isFixture = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedInterfaceName = defaults.string(forKey: Key.interface)
        usesVirtualDeck = defaults.bool(forKey: Key.virtualDeck)
        virtualDeckNumber = defaults.integer(forKey: Key.virtualDeckNumber)
        recordsSetlists = defaults.object(forKey: Key.recordSetlists) as? Bool ?? true
        let bars = defaults.integer(forKey: Key.setlistBars)
        setlistBars = Self.setlistBarChoices.contains(bars) ? bars : 16
        syncsDecks = defaults.bool(forKey: Key.syncDecks)
        recorder = DJPlayersSetlistRecorder(minimumBars: Self.setlistBarChoices.contains(bars) ? bars : 16)
        observeWorkspace()
        MacDJSticks.shared.start()
        sticksCancellable = MacDJSticks.shared.$generation.dropFirst().sink { [weak self] _ in
            self?.lookupMisses = [:]
            self?.resolveTitles()
        }
    }

    static func liveLookup() -> any DJPlayersTrackLookup {
        DJPlayersTrackResolver(
            sticks: MacDJPlayersStickCatalog(),
            collection: DJPlayersTrackLinkCollection(),
            library: { await MacRekordboxLibrary.liveCandidates() }
        )
    }

    var isNumberTaken: Bool {
        if case .numberTaken = state { return true }
        return false
    }

    var selectedInterface: DJLinkInterface? {
        guard let selectedInterfaceName else { return DJLinkInterface.preferred(from: interfaces) }
        return interfaces.first { $0.bsdName == selectedInterfaceName }
    }

    var visiblePlayers: [DJPlayer] {
        players.filter { $0.number != ownNumber }.sorted { $0.number < $1.number }
    }

    var masterPlayer: DJPlayer? {
        visiblePlayers.first { $0.status?.isMaster == true }
    }

    var autoMixTempo: DJPlayersTempoReference? {
        guard syncsDecks, !isVirtualDeckMaster else { return nil }
        return tempo
    }

    func availableVirtualNumbers() -> [Int] {
        rigHasCDJ3000 ? Array(1...6) : Array(1...4)
    }

    func isNumberInUse(_ number: Int) -> Bool {
        players.contains { $0.number == number && $0.number != ownNumber }
    }

    func title(for key: DJPlayerTrackKey) -> String {
        if let info = trackInfo[key] {
            return [info.artist, info.title].compactMap { $0 }.joined(separator: " – ")
        }
        return "Unknown Track"
    }

    // MARK: - Connection

    func refreshInterfaces() {
        guard !isFixture else { return }
        let found = DJLinkInterface.available()
        if found != interfaces { interfaces = found }
        let selectionMissing = selectedInterfaceName.map { name in !found.contains { $0.bsdName == name } } ?? true
        if selectionMissing, !wantsConnection, let preferred = DJLinkInterface.preferred(from: found) {
            selectedInterfaceName = preferred.bsdName
        }
    }

    func connect() {
        wantsConnection = true
        refreshInterfaces()
        guard selectedInterface != nil else {
            state = .noNetwork
            startInterfaceWatch()
            return
        }
        guard defaults.bool(forKey: Key.primed) else {
            state = .priming
            return
        }
        beginSession()
    }

    func continueAfterPriming() {
        defaults.set(true, forKey: Key.primed)
        beginSession()
    }

    func cancelPriming() {
        wantsConnection = false
        state = .disconnected
    }

    func retry() {
        wantsConnection = true
        refreshInterfaces()
        beginSession()
    }

    func disconnect() {
        wantsConnection = false
        endSession()
        finishSetlist()
        recorder.reset()
        stopInterfaceWatch()
        state = .disconnected
    }

    func becomeMaster() {
        runtime?.requestMaster()
    }

    func openLocalNetworkSettings() {
        if let url = Self.localNetworkSettings { NSWorkspace.shared.open(url) }
    }

    private func restartSession() {
        guard wantsConnection else { return }
        beginSession()
    }

    private func beginSession() {
        guard !isFixture else { return }
        endSession()
        wantsConnection = true
        startInterfaceWatch()
        guard let interface = selectedInterface else {
            state = .noNetwork
            return
        }
        if Self.isRekordboxRunning() {
            state = .rekordboxRunning
            return
        }
        guard DJLinkSocketTransport.conflictingPorts().isEmpty else {
            state = .portsInUse
            return
        }

        let identity: DJLinkIdentity = usesVirtualDeck
            ? .virtualDeck(preferred: virtualDeckNumber == 0 ? nil : virtualDeckNumber)
            : .observer
        let engine = DJLinkEngine(identity: identity, localIP: interface.ip, localMAC: interface.mac)
        let runtime = DJLinkRuntime(transport: DJLinkSocketTransport(interface: interface), engine: engine)
        runtime.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        runtime.onEvent = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        runtime.onSendResult = { [weak self] code in
            Task { @MainActor in self?.applySendResult(code) }
        }
        do {
            try runtime.start()
        } catch DJLinkTransportError.bind(_, let code) where code == EADDRINUSE {
            state = .portsInUse
            return
        } catch {
            Log.dj.error("DJ Players: could not open sockets: \(String(describing: error), privacy: .public)")
            state = .portsInUse
            return
        }
        self.runtime = runtime
        sessionInterface = interface
        state = .looking
        runtime.setSynced(syncsDecks)
        observeDecks()
        updateFollower()
        scheduleNoPlayersCheck()
        Log.dj.info("DJ Players: listening on \(interface.bsdName, privacy: .public) \(interface.ip.description, privacy: .public)")
    }

    private func endSession() {
        noPlayersTask?.cancel()
        noPlayersTask = nil
        runtime?.stop()
        runtime = nil
        sessionInterface = nil
        deckCancellable = nil
        lastDeckSnapshot = nil
        followerTimer?.invalidate()
        followerTimer = nil
        MacDJPlayersTempoFollower.reset()
        players = []
        ownNumber = nil
        isClaimingNumber = false
        isVirtualDeckMaster = false
        tempo = nil
    }

    private func scheduleNoPlayersCheck() {
        noPlayersTask?.cancel()
        noPlayersTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noPlayersDelay)
            guard !Task.isCancelled, let self else { return }
            if self.state == .looking, self.visiblePlayers.isEmpty { self.state = .noPlayers }
        }
    }

    // MARK: - Runtime callbacks

    private func apply(_ snapshot: DJPlayersSnapshot) {
        guard runtime != nil else { return }
        players = snapshot.players
        ownNumber = snapshot.ownNumber
        if case .claiming = snapshot.phase { isClaimingNumber = true } else { isClaimingNumber = false }
        isVirtualDeckMaster = snapshot.isVirtualDeckMaster
        tempo = snapshot.tempo
        let hasCDJ3000 = snapshot.players.contains(where: \.isCDJ3000)
        if hasCDJ3000 != rigHasCDJ3000 { rigHasCDJ3000 = hasCDJ3000 }

        switch state {
        case .looking, .noPlayers, .connected:
            state = visiblePlayers.isEmpty ? (state == .connected ? .noPlayers : state) : .connected
        default:
            break
        }
        resolveTitles()
        recordSetlist()
    }

    private func apply(_ event: DJLinkEngineEvent) {
        switch event {
        case .syncCommand(let on):
            if syncsDecks != on { syncsDecks = on }
        case .numberTaken(let number):
            runtime?.stop()
            runtime = nil
            state = .numberTaken(number)
        case .becameMaster, .resignedMaster:
            break
        }
    }

    private func applySendResult(_ code: Int32) {
        switch code {
        case 0:
            if state == .notAllowed { state = visiblePlayers.isEmpty ? .looking : .connected }
        case EHOSTUNREACH, EPERM, EACCES:
            state = .notAllowed
        default:
            Log.dj.error("DJ Players: send failed errno=\(code, privacy: .public)")
        }
    }

    private func resolveTitles() {
        let now = ProcessInfo.processInfo.systemUptime
        var hints: [DJPlayerTrackKey: DJPlayerTrackHint] = [:]
        for status in players.compactMap(\.status) {
            guard let key = status.track else { continue }
            hints[key] = DJPlayerTrackHint(lengthSeconds: status.trackLengthSeconds, bpm: status.trackBPM)
        }
        for (key, hint) in hints where trackInfo[key] == nil && !lookupsInFlight.contains(key) {
            if let missed = lookupMisses[key], now - missed < Self.lookupRetryInterval { continue }
            lookupsInFlight.insert(key)
            let lookup = trackLookup
            Task { [weak self] in
                let info = await lookup.track(for: key, hint: hint)
                guard let self else { return }
                self.lookupsInFlight.remove(key)
                if let info {
                    self.trackInfo[key] = info
                    self.lookupMisses[key] = nil
                    self.refreshSetlistTitles()
                } else {
                    self.lookupMisses[key] = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }

    // MARK: - Setlists

    private func recordSetlist() {
        guard recordsSetlists else { return }
        let plays = recorder.observe(visiblePlayers, now: ProcessInfo.processInfo.systemUptime, date: Date())
        for play in plays {
            if setlistBuilder == nil {
                setlistBuilder = DJPlayersSetlistBuilder(startedAt: play.startedAt)
                recordingTitle = setlistBuilder?.setlist.trackTitle
                recordedCount = 0
            }
            guard var builder = setlistBuilder else { continue }
            let setlist = builder.append(play, info: trackInfo[play.track], now: Date())
            setlistBuilder = builder
            recordedCount += 1
            SetlistIntelligenceStore.shared.recordExternalSetlist(setlist)
        }
    }

    private func refreshSetlistTitles() {
        guard var builder = setlistBuilder, let setlist = builder.fillTitles(from: trackInfo, now: Date()) else { return }
        setlistBuilder = builder
        SetlistIntelligenceStore.shared.recordExternalSetlist(setlist)
    }

    private func finishSetlist() {
        guard var builder = setlistBuilder else { return }
        let setlist = builder.extend(to: Date())
        SetlistIntelligenceStore.shared.recordExternalSetlist(setlist)
        setlistBuilder = nil
        recordingTitle = nil
        recordedCount = 0
    }

    // MARK: - Virtual deck and tempo follow

    private func observeDecks() {
        guard usesVirtualDeck else { return }
        deckCancellable = MixEngine.shared.$decks
            .sink { [weak self] decks in
                self?.pushDeckSnapshot(decks)
            }
    }

    private func pushDeckSnapshot(_ decks: [MixEngine.DeckState]) {
        guard let runtime else { return }
        let snapshot = MacDJPlayersDeckSource.snapshot(decks: decks, now: ProcessInfo.processInfo.systemUptime)
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastDeckSnapshot, !snapshot.isMeaningfullyDifferent(from: last, at: now) { return }
        lastDeckSnapshot = snapshot
        runtime.setDeck(snapshot)
    }

    private func updateFollower() {
        followerTimer?.invalidate()
        followerTimer = nil
        guard syncsDecks, runtime != nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followTempo() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followerTimer = timer
    }

    private func followTempo() {
        guard syncsDecks, let tempo = autoMixTempo else { return }
        MacDJPlayersTempoFollower.follow(tempo, now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - System

    static func isRekordboxRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if let bundle = app.bundleIdentifier?.lowercased(), bundle.hasPrefix("com.pioneerdj.rekordbox") { return true }
            return app.localizedName?.lowercased().hasPrefix("rekordbox") == true
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleApplicationsChanged() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleApplicationsChanged() }
        })
    }

    private func handleSleep() {
        wasConnectedBeforeSleep = wantsConnection && runtime != nil
        guard runtime != nil else { return }
        endSession()
        state = .looking
    }

    private func handleWake() {
        guard wasConnectedBeforeSleep else { return }
        wasConnectedBeforeSleep = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.wantsConnection else { return }
            self.refreshInterfaces()
            self.beginSession()
        }
    }

    private func handleApplicationsChanged() {
        guard wantsConnection, !isFixture else { return }
        let running = Self.isRekordboxRunning()
        if running, runtime != nil {
            endSession()
            state = .rekordboxRunning
        } else if !running, state == .rekordboxRunning {
            beginSession()
        }
    }

    private func startInterfaceWatch() {
        guard interfaceTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInterfaces() }
        }
        RunLoop.main.add(timer, forMode: .common)
        interfaceTimer = timer
    }

    private func stopInterfaceWatch() {
        interfaceTimer?.invalidate()
        interfaceTimer = nil
    }

    private func checkInterfaces() {
        guard wantsConnection, !isFixture else { return }
        refreshInterfaces()
        let current = selectedInterface
        if let session = sessionInterface {
            let live = interfaces.first { $0.bsdName == session.bsdName }
            if live?.ip != session.ip {
                endSession()
                if live == nil { state = .noNetwork } else { beginSession() }
            }
        } else if state == .noNetwork, current != nil {
            beginSession()
        }
    }

    #if DEBUG
    func installFixture(
        state: DJPlayersConnectionState,
        usesVirtualDeck: Bool = false,
        interfaces: [DJLinkInterface],
        players: [DJPlayer],
        ownNumber: Int?,
        trackInfo: [DJPlayerTrackKey: DJPlayersTrackInfo],
        recordingTitle: String?,
        recordedCount: Int
    ) {
        isFixture = true
        self.usesVirtualDeck = usesVirtualDeck
        recordsSetlists = true
        setlistBars = 16
        syncsDecks = state == .connected
        self.interfaces = interfaces
        selectedInterfaceName = interfaces.first?.bsdName
        self.players = players
        self.ownNumber = ownNumber
        self.trackInfo = trackInfo
        self.recordingTitle = recordingTitle
        self.recordedCount = recordedCount
        rigHasCDJ3000 = players.contains(where: \.isCDJ3000)
        tempo = players.first { $0.status?.isMaster == true }.flatMap { master in
            master.status?.effectiveBPM.map {
                DJPlayersTempoReference(masterNumber: master.number, bpm: $0, lastBeatAt: nil, beatWithinBar: 1, isRunning: true)
            }
        }
        self.state = state
    }
    #endif
}
