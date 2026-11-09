import Combine
import Foundation

@MainActor
final class SonosOutputController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(groupID: String)
        case streaming
        case failed(String)
    }

    static let shared = SonosOutputController()

    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var activeCoordinatorID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reportedVolume: Double = 0.3
    @Published private(set) var isMuted = false
    @Published private(set) var latency: TimeInterval = 0
    @Published private(set) var pendingGroupChange: String?

    let streamFormat: SonosStreamFormat = .aacADTS

    var qualityLabel: String { "AAC 256 kbps" }

    var activeGroup: SonosGroup? {
        guard let activeCoordinatorID else { return nil }
        return groups.first { $0.coordinator.id == activeCoordinatorID }
            ?? groups.first { group in group.members.contains { $0.id == activeCoordinatorID } }
    }

    var isActive: Bool { activeCoordinatorID != nil }

    var volume: Double { volumeChannel.value(echo: reportedVolume) ?? reportedVolume }

    private lazy var volumeChannel: RemoteVolumeChannel = {
        let channel = RemoteVolumeChannel { [weak self] level in self?.transmitVolume(level) }
        channel.willChange = { [weak self] in self?.objectWillChange.send() }
        return channel
    }()

    private let discovery: SonosDiscovery
    private let player: PlayerService
    private var server: SonosStreamServer?
    private var estimator = SonosLatencyEstimator()
    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var playingSince: Date?
    private var cancellables = Set<AnyCancellable>()
    private var titleCancellable: AnyCancellable?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif
    private let isFixture: Bool

    init(player: PlayerService = .shared) {
        self.player = player
        self.discovery = SonosDiscovery()
        #if DEBUG
        let fixture = ProcessInfo.processInfo.environment["SOUNDING_TV_SONOS_FIXTURE"]
        isFixture = fixture != nil
        if let fixture {
            groups = (try? SonosTopology.parseZoneGroupState(SonosOutputFixture.topology)) ?? []
            if fixture == "active", let group = groups.first(where: { $0.members.count > 1 }) ?? groups.first {
                activeCoordinatorID = group.coordinator.id
                phase = .streaming
                reportedVolume = 0.42
                latency = 1.8
            }
            return
        }
        #else
        isFixture = false
        #endif
        discovery.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] groups in self?.groups = groups }
            .store(in: &cancellables)
    }

    func startDiscovery() {
        guard !isFixture else { return }
        discovery.start()
    }

    func stopDiscovery() {
        guard !isFixture, !isActive else { return }
        discovery.stop()
    }

    func refresh() async {
        guard !isFixture else { return }
        await discovery.refreshTopology()
    }

    func isPlaying(on group: SonosGroup) -> Bool {
        guard let activeCoordinatorID else { return false }
        return group.coordinator.id == activeCoordinatorID
    }

    // MARK: - Streaming

    func play(on group: SonosGroup) async -> String? {
        if isFixture {
            activeCoordinatorID = group.coordinator.id
            phase = .streaming
            return nil
        }
        if isActive, activeCoordinatorID != group.coordinator.id {
            await stopRemote()
        }
        phase = .connecting(groupID: group.id)
        do {
            let server = self.server ?? SonosStreamServer(format: streamFormat)
            self.server = server
            let url = try await server.start()
            await player.setRequiresMixEngineOutput(true)
            MixEngine.shared.installStreamTap(ring: server.ringBuffer)
            MixEngine.shared.mutesLocalOutput = true
            let client = SonosClient(host: group.coordinator.host, port: group.coordinator.port)
            let metadata = SonosDIDL.streamMetadata(
                title: player.currentTrack?.title ?? "Sounding",
                artist: player.currentTrack?.user.username,
                album: "Sounding",
                artworkURL: player.currentTrack?.artworkURL.flatMap { $0.isFileURL ? nil : $0 },
                streamURL: url,
                mimeType: streamFormat.mimeType
            )
            try await client.setAVTransportURI(SonosDIDL.radioURI(for: url), metadata: metadata)
            try await client.play()
            activeCoordinatorID = group.coordinator.id
            phase = .streaming
            playingSince = Date()
            estimator = SonosLatencyEstimator()
            beginKeepAwake()
            observeTitles(server)
            startPolling(client, grouped: group.members.count > 1)
            volumeChannel.reset()
            if let level = try? await (group.members.count > 1 ? client.groupVolume() : client.volume()) {
                reportedVolume = Double(level) / 100
            }
            return nil
        } catch {
            await teardownStream()
            let message = "Couldn't play on \(group.displayName). Make sure it's on the same Wi-Fi."
            phase = .failed(message)
            return message
        }
    }

    func stop() async {
        guard isActive else { return }
        if isFixture {
            activeCoordinatorID = nil
            phase = .idle
            return
        }
        await stopRemote()
        await teardownStream()
        phase = .idle
    }

    private func stopRemote() async {
        guard let group = activeGroup else { return }
        let client = SonosClient(host: group.coordinator.host, port: group.coordinator.port)
        try? await client.stop()
    }

    private func teardownStream() async {
        pollTask?.cancel()
        pollTask = nil
        titleCancellable = nil
        activeCoordinatorID = nil
        playingSince = nil
        latency = 0
        MixEngine.shared.additionalOutputLatency = 0
        MixEngine.shared.mutesLocalOutput = false
        MixEngine.shared.removeStreamTap()
        server?.stop()
        server = nil
        endKeepAwake()
        await player.setRequiresMixEngineOutput(false)
    }

    private func observeTitles(_ server: SonosStreamServer) {
        titleCancellable = player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { track in
                guard let track else { return }
                server.setStreamTitle("\(track.user.username) - \(track.title)")
            }
    }

    private func startPolling(_ client: SonosClient, grouped: Bool) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let server = self.server else { return }
                if !self.volumeChannel.isHolding,
                   let level = try? await (grouped ? client.groupVolume() : client.volume()) {
                    let reported = Double(level) / 100
                    if abs(reported - self.reportedVolume) > 0.004 { self.reportedVolume = reported }
                }
                let nowPlaying = try? await client.nowPlaying()
                let elapsed = nowPlaying?.position.flatMap { $0 > 0 ? $0 : nil }
                    ?? self.playingSince.map { Date().timeIntervalSince($0) }
                guard let elapsed else { continue }
                if let measured = self.estimator.add(
                    producedFrame: server.producedFrame,
                    streamStartFrame: server.clientStreamStartFrame,
                    sonosElapsed: elapsed,
                    sampleRate: server.sampleRate
                ) {
                    self.latency = measured
                    MixEngine.shared.additionalOutputLatency = measured
                }
            }
        }
    }

    // MARK: - Volume

    func setVolume(_ value: Double) {
        volumeChannel.set(value)
    }

    func beginVolumeChange() {
        volumeChannel.begin()
    }

    func endVolumeChange() {
        volumeChannel.end()
    }

    func stepVolume(_ steps: Int) {
        volumeChannel.step(steps, echo: reportedVolume)
    }

    private func transmitVolume(_ value: Double) {
        guard !isFixture else {
            reportedVolume = value
            return
        }
        guard let group = activeGroup else { return }
        let previous = volumeTask
        volumeTask = Task { @MainActor [weak self] in
            await previous?.value
            let client = SonosClient(host: group.coordinator.host, port: group.coordinator.port)
            let level = Int((value * 100).rounded())
            do {
                if group.members.count > 1 {
                    try await client.setGroupVolume(level)
                } else {
                    try await client.setVolume(level)
                }
                self?.reportedVolume = Double(level) / 100
            } catch {}
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        guard !isFixture, let group = activeGroup else { return }
        Task {
            let client = SonosClient(host: group.coordinator.host, port: group.coordinator.port)
            if group.members.count > 1 {
                try? await client.setGroupMuted(muted)
            } else {
                try? await client.setMuted(muted)
            }
        }
    }

    // MARK: - Grouping

    func add(_ room: SonosPlayer, to group: SonosGroup) async -> String? {
        guard !isFixture else { return nil }
        pendingGroupChange = room.id
        defer { pendingGroupChange = nil }
        do {
            try await SonosClient(host: room.host, port: room.port).join(coordinatorID: group.coordinator.id)
            await discovery.refreshTopology()
            return nil
        } catch {
            return "Couldn't add \(room.roomName) to \(group.displayName)."
        }
    }

    func remove(_ room: SonosPlayer) async -> String? {
        guard !isFixture else { return nil }
        pendingGroupChange = room.id
        defer { pendingGroupChange = nil }
        do {
            try await SonosClient(host: room.host, port: room.port).leaveGroup()
            await discovery.refreshTopology()
            return nil
        } catch {
            return "Couldn't remove \(room.roomName) from the group."
        }
    }

    func rooms(addableTo group: SonosGroup) -> [SonosPlayer] {
        groups
            .filter { $0.id != group.id }
            .flatMap(\.members)
            .sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
    }

    // MARK: - Keep awake

    private func beginKeepAwake() {
        #if os(macOS)
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Playing on Sonos"
        )
        #endif
    }

    private func endKeepAwake() {
        #if os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }
}

#if DEBUG
enum SonosOutputFixture {
    static let topology = """
    <ZoneGroupState><ZoneGroups>\
    <ZoneGroup Coordinator="RINCON_000000000001" ID="RINCON_000000000001:1">\
    <ZoneGroupMember UUID="RINCON_000000000001" Location="http://192.0.2.10:1400/xml/device_description.xml" ZoneName="Soundbar" Invisible="0"/>\
    <ZoneGroupMember UUID="RINCON_000000000002" Location="http://192.0.2.11:1400/xml/device_description.xml" ZoneName="Den" Invisible="0"/>\
    </ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_000000000003" ID="RINCON_000000000003:7">\
    <ZoneGroupMember UUID="RINCON_000000000003" Location="http://192.0.2.12:1400/xml/device_description.xml" ZoneName="Kitchen" Invisible="0"/>\
    </ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_000000000004" ID="RINCON_000000000004:3">\
    <ZoneGroupMember UUID="RINCON_000000000004" Location="http://192.0.2.13:1400/xml/device_description.xml" ZoneName="Bedroom" Invisible="0"/>\
    </ZoneGroup>\
    </ZoneGroups></ZoneGroupState>
    """
}
#endif
