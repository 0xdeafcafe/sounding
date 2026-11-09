#if os(macOS) || DEBUG
import Foundation

enum DJLinkDestination: Equatable, Sendable {
    case broadcast(UInt16)
    case unicast(DJLinkIPv4, UInt16)

    var port: UInt16 {
        switch self {
        case .broadcast(let port), .unicast(_, let port): return port
        }
    }
}

struct DJLinkOutbound: Equatable, Sendable {
    var packet: DJLinkPacket
    var destination: DJLinkDestination
}

enum DJLinkEngineEvent: Equatable, Sendable {
    case syncCommand(on: Bool)
    case numberTaken(Int)
    case becameMaster
    case resignedMaster
}

struct DJLinkEngineTiming: Sendable {
    var listenWindow: TimeInterval = 2.2
    var keepAliveInterval: TimeInterval = 1.5
    var claimInterval: TimeInterval = 0.3
    var statusInterval: TimeInterval = 0.2
    var deviceTimeout: TimeInterval = 8
    var lateBeatTolerance: TimeInterval = 0.05
}

final class DJLinkEngine {
    static let observerNumbers = Array(7...15)
    static let standardPlayerNumbers = [4, 3, 2, 1]
    static let extendedPlayerNumbers = [6, 5]
    static let firmware = "1.00"

    let name: String
    let identity: DJLinkIdentity
    let timing: DJLinkEngineTiming
    var localIP: DJLinkIPv4
    var localMAC: DJLinkMAC

    private(set) var phase: DJLinkEnginePhase = .idle
    private var devices: [Int: DJPlayer] = [:]
    private var outbox: [DJLinkOutbound] = []
    private var events: [DJLinkEngineEvent] = []

    private var listenUntil: TimeInterval?
    private var nextKeepAlive: TimeInterval?
    private var nextStatus: TimeInterval?
    private var nextClaimAt: TimeInterval?
    private var claimStage = 0
    private var claimCounter: UInt8 = 1
    private var rejectedNumbers: Set<Int> = []
    private var firstOnNetwork = false
    private var awaitingMixerAssignment = false

    private var deck: DJVirtualDeckSnapshot = .empty
    private var nextBeatIndex: Int?
    private(set) var isMaster = false
    private(set) var isSynced = false
    private var masterHandoffTo: UInt8 = 0xff
    private var pendingMasterFrom: Int?
    private var syncCounter: UInt32 = 1
    private var packetCounter: UInt32 = 0
    private var masterBeat: (number: Int, at: TimeInterval, bpm: Double, beatWithinBar: Int)?

    init(name: String = "Sounding", identity: DJLinkIdentity, localIP: DJLinkIPv4, localMAC: DJLinkMAC, timing: DJLinkEngineTiming = DJLinkEngineTiming()) {
        self.name = name
        self.identity = identity
        self.localIP = localIP
        self.localMAC = localMAC
        self.timing = timing
    }

    // MARK: - Lifecycle

    func start(now: TimeInterval) {
        devices.removeAll()
        rejectedNumbers.removeAll()
        isMaster = false
        isSynced = false
        masterHandoffTo = 0xff
        pendingMasterFrom = nil
        masterBeat = nil
        phase = .listening
        listenUntil = now + timing.listenWindow
        nextKeepAlive = nil
        nextStatus = nil
        nextClaimAt = nil
    }

    func stop() {
        phase = .idle
        listenUntil = nil
        nextKeepAlive = nil
        nextStatus = nil
        nextClaimAt = nil
        nextBeatIndex = nil
        isMaster = false
    }

    func drainOutbox() -> [DJLinkOutbound] {
        defer { outbox.removeAll() }
        return outbox
    }

    func drainEvents() -> [DJLinkEngineEvent] {
        defer { events.removeAll() }
        return events
    }

    var ownNumber: Int? {
        switch phase {
        case .active(let number), .claiming(let number): return number
        default: return nil
        }
    }

    var isVirtualDeck: Bool {
        if case .virtualDeck = identity { return true }
        return false
    }

    var usesCDJ3000Packets: Bool {
        if let own = ownNumber, own == 5 || own == 6 { return true }
        return devices.values.contains { $0.isCDJ3000 || $0.number == 5 || $0.number == 6 }
    }

    func snapshot(now: TimeInterval) -> DJPlayersSnapshot {
        DJPlayersSnapshot(
            phase: phase,
            players: devices.values.sorted { $0.number < $1.number },
            tempo: tempoReference(now: now),
            isVirtualDeckMaster: isVirtualDeck && isMaster,
            isVirtualDeckSynced: isSynced,
            usesCDJ3000Packets: usesCDJ3000Packets
        )
    }

    func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        var candidates = [listenUntil, nextKeepAlive, nextClaimAt, nextStatus].compactMap { $0 }
        if let beat = nextBeatTime() { candidates.append(beat) }
        if !devices.isEmpty { candidates.append(now + 1) }
        return candidates.min()
    }

    // MARK: - Virtual deck control

    func setDeck(_ snapshot: DJVirtualDeckSnapshot, now: TimeInterval) {
        let changed = snapshot.isMeaningfullyDifferent(from: deck, at: now)
        deck = snapshot
        if changed { realignBeats(now: now) }
    }

    func requestMaster(now: TimeInterval) {
        guard isVirtualDeck, case .active(let own) = phase, !isMaster else { return }
        guard let current = devices.values.first(where: { $0.number != own && $0.status?.isMaster == true }) else {
            becomeMaster()
            return
        }
        pendingMasterFrom = current.number
        send(.masterRequest(DJLinkMasterRequest(name: name, device: UInt8(own))), to: .unicast(current.ip, DJLinkPort.beat))
    }

    func setSynced(_ synced: Bool) {
        isSynced = synced
    }

    // MARK: - Inbound

    func receive(_ data: Data, from address: DJLinkIPv4, port: UInt16, now: TimeInterval) {
        guard let packet = DJLinkPacket.decode(data, port: port) else { return }
        handle(packet, from: address, now: now)
    }

    func handle(_ packet: DJLinkPacket, from address: DJLinkIPv4, now: TimeInterval) {
        guard phase != .idle else { return }
        switch packet {
        case .keepAlive(let p):
            guard !isOwn(mac: p.mac, device: Int(p.device), name: p.name) else { return }
            let number = Int(p.device)
            var device = devices[number] ?? DJPlayer(
                number: number, name: p.name, ip: p.ip, mac: p.mac, lastSeen: now, reportsAsMixer: p.isMixer, status: nil
            )
            if device.mac != p.mac, device.mac != .zero, now - device.lastSeen < timing.deviceTimeout {
                device.status = nil
            }
            device.name = p.name
            device.ip = p.ip == .zero ? address : p.ip
            device.mac = p.mac
            device.reportsAsMixer = p.isMixer
            device.lastSeen = now
            devices[number] = device
            if number == ownNumber, p.mac != localMAC { lose(number: number) }

        case .claimStage2(let p):
            guard p.mac != localMAC else { return }
            if case .active(let own) = phase, isVirtualDeck, Int(p.device) == own, !p.isMixerRequest {
                send(.conflict(DJLinkConflict(name: name, device: UInt8(own), ip: localIP)), to: .unicast(p.ip, DJLinkPort.announce))
            }

        case .conflict(let p):
            if case .claiming(let number) = phase, Int(p.device) == number { lose(number: number) }

        case .assignmentFinished:
            if case .claiming(let number) = phase, claimStage >= 3 {
                activate(number: number, now: now)
            }

        case .assignIntention(let p):
            guard case .claiming = phase else { return }
            awaitingMixerAssignment = true
            send(.claimStage2(DJLinkClaimStage2(
                name: name, ip: localIP, mac: localMAC, device: 0, counter: 1, autoAssign: true,
                cdj3000Compatible: usesCDJ3000Packets, isMixerRequest: true
            )), to: .unicast(p.ip, DJLinkPort.announce))

        case .mixerAssignment(let p):
            guard case .claiming = phase, awaitingMixerAssignment else { return }
            awaitingMixerAssignment = false
            let number = Int(p.device)
            send(.claimStage3(DJLinkClaimStage3(name: name, device: p.device, counter: 1, cdj3000Compatible: usesCDJ3000Packets)), to: .broadcast(DJLinkPort.announce))
            activate(number: number, now: now)

        case .announce, .claimStage1, .claimStage3:
            break

        case .beat(let p):
            let number = Int(p.device)
            guard !isOwn(device: number, name: p.name) else { return }
            touch(number: number, name: p.name, address: address, now: now)
            if var status = devices[number]?.status {
                status.beatWithinBar = Int(p.beatWithinBar)
                status.pitch = p.pitch.multiplier
                if p.bpmHundredths != 0xffff { status.trackBPM = p.trackBPM }
                devices[number]?.status = status
            }
            if masterNumber() == number {
                masterBeat = (number, now, p.effectiveBPM, Int(p.beatWithinBar))
            }

        case .absolutePosition(let p):
            let number = Int(p.device)
            guard !isOwn(device: number, name: p.name) else { return }
            touch(number: number, name: p.name, address: address, now: now)
            var status = devices[number]?.status ?? DJPlayerStatus()
            status.playheadMillis = Int(p.playheadMillis)
            status.trackLengthSeconds = Int(p.trackLengthSeconds)
            devices[number]?.status = status

        case .syncControl(let p):
            guard isVirtualDeck, case .active = phase else { return }
            switch DJLinkSyncCommand(rawValue: p.command) {
            case .syncOn:
                isSynced = true
                events.append(.syncCommand(on: true))
            case .syncOff:
                isSynced = false
                events.append(.syncCommand(on: false))
            case .becomeMaster:
                requestMaster(now: now)
            case nil:
                break
            }

        case .masterRequest(let p):
            guard isVirtualDeck, isMaster, let requester = devices[Int(p.device)] else { return }
            guard case .active(let own) = phase else { return }
            masterHandoffTo = p.device
            send(.masterResponse(DJLinkMasterResponse(name: name, device: UInt8(own), accepted: true)), to: .unicast(requester.ip, DJLinkPort.beat))

        case .masterResponse:
            break

        case .cdjStatus(let p):
            let number = Int(p.device)
            guard !isOwn(device: number, name: p.name) else { return }
            touch(number: number, name: p.name, address: address, now: now)
            let previous = devices[number]?.status
            var status = DJPlayerStatus()
            status.activity = DJPlayerActivity(p.playState, isPlayingFlag: p.isPlaying)
            status.trackBPM = p.trackBPM
            status.pitch = p.pitch1.multiplier
            status.isMaster = p.isMaster
            status.isSynced = p.isSynced
            status.isOnAir = p.isOnAir
            if p.hasTrack {
                status.track = DJPlayerTrackKey(
                    sourcePlayer: Int(p.sourcePlayer),
                    slot: DJPlayerMediaSlot(raw: p.sourceSlot),
                    trackType: p.trackType,
                    rekordboxId: p.rekordboxId
                )
                status.key = p.key?.displayName
            }
            status.beatNumber = p.beat.map(Int.init)
            status.beatWithinBar = p.beatWithinBar == 0 ? nil : Int(p.beatWithinBar)
            if previous?.track == status.track {
                status.playheadMillis = previous?.playheadMillis
                status.trackLengthSeconds = previous?.trackLengthSeconds
            }
            status.firmware = p.firmware.isEmpty ? nil : p.firmware
            status.syncCounter = p.syncCounter
            status.masterHandoff = p.masterHandoff
            status.updatedAt = now
            devices[number]?.status = status
            reconcileMaster(with: number, isMaster: p.isMaster, handoff: p.masterHandoff, now: now)

        case .mixerStatus(let p):
            let number = Int(p.device)
            guard !isOwn(device: number, name: p.name) else { return }
            touch(number: number, name: p.name, address: address, now: now)
            devices[number]?.reportsAsMixer = true
            var status = devices[number]?.status ?? DJPlayerStatus()
            status.activity = .playing
            status.trackBPM = p.bpm
            status.pitch = p.pitch.multiplier
            status.isMaster = p.isMaster
            status.masterHandoff = p.masterHandoff
            status.updatedAt = now
            devices[number]?.status = status
            reconcileMaster(with: number, isMaster: p.isMaster, handoff: p.masterHandoff, now: now)
        }
    }

    // MARK: - Timers

    func tick(now: TimeInterval) {
        guard phase != .idle else { return }
        expireDevices(now: now)

        if let until = listenUntil, now >= until {
            listenUntil = nil
            beginIdentity(now: now)
        }

        if let at = nextClaimAt, now >= at {
            advanceClaim(now: now, scheduled: at)
        }

        if let at = nextKeepAlive, now >= at {
            sendKeepAlive()
            nextKeepAlive = max(at + timing.keepAliveInterval, now + timing.keepAliveInterval / 2)
        }

        if let at = nextStatus, now >= at {
            sendStatus(now: now)
            nextStatus = max(at + timing.statusInterval, now + timing.statusInterval / 2)
        }

        emitDueBeats(now: now)
    }

    // MARK: - Identity

    private func beginIdentity(now: TimeInterval) {
        firstOnNetwork = devices.isEmpty
        switch identity {
        case .observer:
            guard let number = Self.observerNumbers.first(where: { devices[$0] == nil }) else {
                phase = .numberTaken(number: Self.observerNumbers.last ?? 15)
                events.append(.numberTaken(Self.observerNumbers.last ?? 15))
                return
            }
            phase = .active(number: number)
            sendKeepAlive()
            nextKeepAlive = now + timing.keepAliveInterval
        case .virtualDeck:
            startClaim(now: now)
        }
    }

    private func candidateNumbers() -> [Int] {
        guard case .virtualDeck(let preferred) = identity else { return [] }
        if let preferred { return [preferred] }
        var numbers = Self.standardPlayerNumbers
        if devices.values.contains(where: \.isCDJ3000) { numbers += Self.extendedPlayerNumbers }
        return numbers
    }

    private func startClaim(now: TimeInterval) {
        let candidates = candidateNumbers()
        guard let number = candidates.first(where: { devices[$0] == nil && !rejectedNumbers.contains($0) }) else {
            let taken = candidates.first ?? 1
            phase = .numberTaken(number: taken)
            events.append(.numberTaken(taken))
            return
        }
        phase = .claiming(number: number)
        claimStage = 0
        claimCounter = 1
        awaitingMixerAssignment = false
        nextClaimAt = now
        advanceClaim(now: now, scheduled: now)
    }

    private func advanceClaim(now: TimeInterval, scheduled: TimeInterval) {
        guard case .claiming(let number) = phase else {
            nextClaimAt = nil
            return
        }
        let compatible = usesCDJ3000Packets
        let device = UInt8(number)
        switch claimStage {
        case 0:
            send(.announce(DJLinkAnnounce(name: name, cdj3000Compatible: compatible)), to: .broadcast(DJLinkPort.announce))
        case 1:
            send(.claimStage1(DJLinkClaimStage1(name: name, counter: claimCounter, mac: localMAC, cdj3000Compatible: compatible)), to: .broadcast(DJLinkPort.announce))
        case 2:
            send(.claimStage2(DJLinkClaimStage2(
                name: name, ip: localIP, mac: localMAC, device: device, counter: claimCounter,
                autoAssign: false, cdj3000Compatible: compatible
            )), to: .broadcast(DJLinkPort.announce))
        default:
            send(.claimStage3(DJLinkClaimStage3(name: name, device: device, counter: claimCounter, cdj3000Compatible: compatible)), to: .broadcast(DJLinkPort.announce))
        }
        if claimCounter >= 3 {
            claimCounter = 1
            claimStage += 1
        } else {
            claimCounter += 1
        }
        let next = max(scheduled + timing.claimInterval, now + timing.claimInterval / 2)
        if claimStage > 3 {
            activate(number: number, now: next)
        } else {
            nextClaimAt = next
        }
    }

    private func activate(number: Int, now: TimeInterval) {
        nextClaimAt = nil
        awaitingMixerAssignment = false
        phase = .active(number: number)
        sendKeepAlive()
        nextKeepAlive = now + timing.keepAliveInterval
        if isVirtualDeck {
            nextStatus = now
            realignBeats(now: now)
        }
    }

    private func lose(number: Int) {
        rejectedNumbers.insert(number)
        nextClaimAt = nil
        nextStatus = nil
        nextKeepAlive = nil
        nextBeatIndex = nil
        if isMaster {
            isMaster = false
            events.append(.resignedMaster)
        }
        let canRetry: Bool
        switch identity {
        case .observer:
            canRetry = Self.observerNumbers.contains { devices[$0] == nil }
        case .virtualDeck(let preferred):
            canRetry = preferred == nil && candidateNumbers().contains { devices[$0] == nil && !rejectedNumbers.contains($0) }
        }
        if canRetry {
            phase = .listening
            listenUntil = 0
            return
        }
        phase = .numberTaken(number: number)
        events.append(.numberTaken(number))
    }

    // MARK: - Master

    private func masterNumber() -> Int? {
        devices.values.first { $0.status?.isMaster == true }?.number
    }

    private func reconcileMaster(with number: Int, isMaster remoteIsMaster: Bool, handoff: UInt8, now: TimeInterval) {
        guard isVirtualDeck, case .active(let own) = phase else { return }
        if !isMaster, handoff == UInt8(own), pendingMasterFrom == number || (isSynced && deck.isPlaying) {
            pendingMasterFrom = nil
            becomeMaster()
            return
        }
        if isMaster, remoteIsMaster, number != own, handoff != UInt8(own) {
            isMaster = false
            masterHandoffTo = 0xff
            let highest = devices.values.compactMap { $0.status?.syncCounter }.max() ?? syncCounter
            syncCounter = max(syncCounter, highest) + 1
            events.append(.resignedMaster)
        }
    }

    private func becomeMaster() {
        isMaster = true
        masterHandoffTo = 0xff
        masterBeat = nil
        events.append(.becameMaster)
    }

    private func tempoReference(now: TimeInterval) -> DJPlayersTempoReference? {
        guard !(isVirtualDeck && isMaster), let number = masterNumber(), let master = devices[number],
              let status = master.status, let bpm = status.effectiveBPM, bpm > 0 else { return nil }
        let beat = masterBeat.flatMap { $0.number == number ? $0 : nil }
        let period = 60 / bpm
        let fresh = beat.map { now - $0.at < max(2, period * 3) } ?? false
        return DJPlayersTempoReference(
            masterNumber: number,
            bpm: beat.map(\.bpm).flatMap { $0 > 0 ? $0 : nil } ?? bpm,
            lastBeatAt: beat?.at,
            beatWithinBar: beat?.beatWithinBar ?? status.beatWithinBar ?? 1,
            isRunning: status.activity.isAudible && fresh
        )
    }

    // MARK: - Outbound

    private func send(_ packet: DJLinkPacket, to destination: DJLinkDestination) {
        outbox.append(DJLinkOutbound(packet: packet, destination: destination))
    }

    private func sendKeepAlive() {
        guard let own = ownNumber else { return }
        send(.keepAlive(DJLinkKeepAlive(
            name: name,
            device: UInt8(own),
            mac: localMAC,
            ip: localIP,
            peerCount: UInt8(min(255, devices.count + 1)),
            isMixer: false,
            firstOnNetwork: firstOnNetwork,
            cdj3000Compatible: usesCDJ3000Packets
        )), to: .broadcast(DJLinkPort.announce))
    }

    func statusPacket(now: TimeInterval) -> DJLinkCDJStatus? {
        guard case .active(let own) = phase else { return nil }
        let device = UInt8(own)
        var status = DJLinkCDJStatus(name: name, device: device)
        let loaded = deck.isLoaded
        let playing = loaded && deck.isPlaying
        let bpm = deck.trackBPM.flatMap { $0 > 0 && $0 < 655 ? $0 : nil }
        status.activity = playing ? 0x01 : 0x00
        status.sourcePlayer = loaded ? device : 0
        status.sourceSlot = loaded ? 0x04 : 0
        status.trackType = loaded ? 0x01 : 0
        status.rekordboxId = loaded ? 1 : 0
        status.trackNumber = loaded ? 1 : 0
        status.playStateRaw = !loaded ? DJLinkPlayState.noTrack.rawValue : (playing ? DJLinkPlayState.playing.rawValue : DJLinkPlayState.paused.rawValue)
        status.firmware = Self.firmware
        status.syncCounter = syncCounter
        var flags = DJLinkStatusFlags.fixedBits
        if playing { flags.insert(.playing) }
        if isMaster { flags.insert(.master) }
        if isSynced { flags.insert(.synced) }
        status.flags = flags
        status.playState2 = playing ? 0x7a : 0x7e
        let pitch = DJLinkPitch(multiplier: deck.rate)
        status.pitch1 = pitch
        status.pitch2 = playing ? pitch : DJLinkPitch(raw: 0)
        status.pitch3 = pitch
        status.pitch4 = playing ? pitch : DJLinkPitch(raw: 0)
        status.tempoMasterValidity = !loaded ? 0x7fff : (bpm == nil ? 0x0000 : 0x8000)
        status.bpmHundredths = bpm.map { UInt16(($0 * 100).rounded()) } ?? 0xffff
        status.playState3 = !loaded ? 0x00 : (playing ? 0x0d : 0x01)
        status.masterMeaning = isMaster ? (bpm == nil ? 0x02 : 0x01) : 0x00
        status.masterHandoff = masterHandoffTo
        if loaded, let index = deck.beatIndex(at: now) {
            status.beatNumber = UInt32(max(0, index + 1))
            status.beatWithinBar = UInt8(deck.beatWithinBar(ofBeat: index))
        }
        packetCounter &+= 1
        status.packetCounter = packetCounter
        status.nexusMarker = 0x0f
        return status
    }

    private func sendStatus(now: TimeInterval) {
        guard isVirtualDeck, let status = statusPacket(now: now) else { return }
        for device in devices.values where !device.isComputer {
            send(.cdjStatus(status), to: .unicast(device.ip, DJLinkPort.status))
        }
    }

    // MARK: - Beats

    private func realignBeats(now: TimeInterval) {
        guard isVirtualDeck, case .active = phase, deck.isLoaded, deck.isPlaying, let index = deck.beatIndex(at: now) else {
            nextBeatIndex = nil
            return
        }
        if let time = deck.time(ofBeat: index), now - time < 0.004 {
            nextBeatIndex = index
        } else {
            nextBeatIndex = index + 1
        }
    }

    private func nextBeatTime() -> TimeInterval? {
        guard let index = nextBeatIndex else { return nil }
        return deck.time(ofBeat: index)
    }

    private func emitDueBeats(now: TimeInterval) {
        guard isVirtualDeck, case .active(let own) = phase else { return }
        var guardCount = 0
        while let index = nextBeatIndex, let time = deck.time(ofBeat: index), time <= now + 0.001, guardCount < 8 {
            guardCount += 1
            nextBeatIndex = index + 1
            guard now - time <= timing.lateBeatTolerance, let beat = beatPacket(index: index, device: UInt8(own)) else { continue }
            send(.beat(beat), to: .broadcast(DJLinkPort.beat))
        }
        if guardCount >= 8 { realignBeats(now: now) }
    }

    func beatPacket(index: Int, device: UInt8) -> DJLinkBeat? {
        guard let period = deck.trackBeatPeriod, let bpm = deck.trackBPM, index >= 0 else { return nil }
        let withinBar = deck.beatWithinBar(ofBeat: index)
        let beatsToNextBar = 5 - withinBar
        func interval(_ beats: Int) -> UInt32 {
            guard let seconds = deck.trackSeconds(ofBeat: index + beats) else { return DJLinkBeat.unavailable }
            if deck.durationSeconds > 0, seconds > deck.durationSeconds { return DJLinkBeat.unavailable }
            return UInt32((Double(beats) * period * 1000).rounded())
        }
        return DJLinkBeat(
            name: name,
            device: device,
            nextBeat: interval(1),
            secondBeat: interval(2),
            nextBar: interval(beatsToNextBar),
            fourthBeat: interval(4),
            secondBar: interval(beatsToNextBar + 4),
            eighthBeat: interval(8),
            pitch: DJLinkPitch(multiplier: deck.rate),
            bpmHundredths: UInt16(min(65534, (bpm * 100).rounded())),
            beatWithinBar: UInt8(withinBar)
        )
    }

    // MARK: - Devices

    private func isOwn(mac: DJLinkMAC, device: Int, name: String) -> Bool {
        if mac == localMAC, mac != .zero { return true }
        return isOwn(device: device, name: name)
    }

    private func isOwn(device: Int, name: String) -> Bool {
        device == ownNumber && name == self.name
    }

    private func touch(number: Int, name: String, address: DJLinkIPv4, now: TimeInterval) {
        if devices[number] == nil {
            devices[number] = DJPlayer(number: number, name: name, ip: address, mac: .zero, lastSeen: now, reportsAsMixer: false, status: nil)
        }
        devices[number]?.lastSeen = now
    }

    private func expireDevices(now: TimeInterval) {
        let expired = devices.values.filter { now - $0.lastSeen > timing.deviceTimeout }.map(\.number)
        for number in expired {
            devices[number] = nil
            if masterBeat?.number == number { masterBeat = nil }
            if pendingMasterFrom == number { pendingMasterFrom = nil }
        }
    }
}
#endif
