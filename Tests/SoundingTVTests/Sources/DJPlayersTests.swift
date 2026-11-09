import XCTest
@testable import SoundingTV

enum DJLinkFixture {
    static func bytes(_ rows: [String]) -> [UInt8] {
        rows.joined(separator: " ").split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    static func sparse(length: Int, _ rows: [Int: String]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: length)
        for (offset, row) in rows {
            for (index, byte) in bytes([row]).enumerated() where offset + index < length {
                result[offset + index] = byte
            }
        }
        return result
    }

    static let keepAliveNXS2 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 06 00 43 44 4a 2d",
        "32 30 30 30 4e 58 53 32 00 00 00 00 00 00 00 00",
        "01 02 00 36 02 01 00 e0 36 a1 b2 c3 a9 fe 29 0c",
        "03 00 00 00 01 00",
    ])

    static let keepAliveCDJ3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 06 00 43 44 4a 2d",
        "33 30 30 30 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 02 00 36 05 02 00 e0 36 d4 e5 f6 a9 fe 29 0f",
        "04 00 00 00 01 64",
    ])

    static let soundingKeepAlive = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 06 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 02 00 36 07 01 3c 18 a0 11 22 33 a9 fe 29 07",
        "03 00 00 00 01 00",
    ])

    static let soundingAnnounce = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 0a 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 02 00 25 01",
    ])

    static let soundingAnnounce3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 0a 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 04 00 26 01 40",
    ])

    static let soundingClaim1For3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 00 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 03 00 2c 01 01 3c 18 a0 11 22 33",
    ])

    static let soundingClaim2For3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 02 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 03 00 32 a9 fe 29 07 3c 18 a0 11 22 33 06 02",
        "01 02",
    ])

    static let soundingClaim3For3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 04 00 53 6f 75 6e",
        "64 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00",
        "01 03 00 26 06 03",
    ])

    static let beatNXS2 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 28 43 44 4a 2d 32",
        "30 30 30 4e 58 53 32 00 00 00 00 00 00 00 00 01",
        "00 01 00 3c 00 00 01 e4 00 00 03 c8 00 00 05 ac",
        "00 00 07 90 00 00 0d 3c 00 00 0f 20 ff ff ff ff",
        "ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff",
        "ff ff ff ff 00 10 40 00 00 00 30 70 02 00 00 01",
    ])

    static let soundingBeat = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 28 53 6f 75 6e 64",
        "69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 01",
        "00 04 00 3c 00 00 01 d5 00 00 03 aa 00 00 07 53",
        "00 00 07 53 00 00 0e a6 00 00 0e a6 ff ff ff ff",
        "ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff",
        "ff ff ff ff 00 10 00 00 00 00 32 00 01 00 00 04",
    ])

    static let statusNXS2 = sparse(length: 0x11c, [
        0x00: "51 73 70 74 31 57 6d 4a 4f 4c 0a 43 44 4a 2d 32",
        0x10: "30 30 30 4e 58 53 32 00 00 00 00 00 00 00 00 01",
        0x20: "03 02 00 f8 02 00 01 01 02 03 01 00 00 00 04 b4",
        0x30: "00 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00",
        0x70: "00 00 00 00 00 00 00 00 01 00 00 03 31 2e 38 35",
        0x80: "00 00 00 00 00 00 00 05 00 fc ff fa 00 10 40 00",
        0x90: "80 00 30 70 7f ff ff ff 00 10 40 00 00 0d 01 ff",
        0xa0: "00 00 00 e9 01 ff 01 00 00 00 00 00 00 00 00 00",
        0xc0: "00 10 40 00 00 10 40 00 00 00 12 34 0f 00 00 00",
    ])

    static let statusCDJ3000 = sparse(length: 0x200, [
        0x000: "51 73 70 74 31 57 6d 4a 4f 4c 0a 43 44 4a 2d 33",
        0x010: "30 30 30 00 00 00 00 00 00 00 00 00 00 00 00 01",
        0x020: "06 01 01 dc 01 00 01 01 01 03 01 00 00 00 0c ef",
        0x070: "00 00 00 00 00 00 00 00 01 00 00 04 33 2e 31 31",
        0x080: "00 00 00 00 00 00 00 02 00 cc ff fa 00 10 00 00",
        0x090: "80 00 32 c8 7f ff ff ff 00 10 00 00 00 0d 00 ff",
        0x0a0: "00 00 02 00 00 20 03 00 00 00 00 00 00 00 00 00",
        0x0c0: "00 10 00 00 00 10 00 00 00 00 00 00 1f 00 00 00",
        0x150: "00 00 00 00 00 00 00 00 01 00 00 00 0a 00 00 00",
        0x1b0: "00 00 00 00 00 00 00 00 0b b8 00 00 00 00 00 00",
        0x1c0: "0b f4 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    ])

    static let absolutePositionCDJ3000 = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 0b 43 44 4a 2d 33",
        "30 30 30 00 00 00 00 00 00 00 00 00 00 00 00 02",
        "00 01 00 18 00 00 01 9c 00 02 fd a0 ff ff fe ba",
        "00 00 00 00 00 00 00 00 00 00 04 ea",
    ])

    static let mixerStatusDJM = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 29 44 4a 4d 2d 39",
        "30 30 4e 58 53 32 00 00 00 00 00 00 00 00 00 01",
        "00 21 00 14 21 00 00 f0 00 10 00 00 80 00 31 38",
        "00 10 00 00 00 09 ff 03",
    ])

    static let soundingSyncOn = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 2a 53 6f 75 6e 64",
        "69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 01",
        "00 04 00 08 00 00 00 04 00 00 00 10",
    ])

    static let soundingMasterRequest = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 26 53 6f 75 6e 64",
        "69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 01",
        "00 04 00 04 00 00 00 04",
    ])

    static let soundingMasterResponse = bytes([
        "51 73 70 74 31 57 6d 4a 4f 4c 27 53 6f 75 6e 64",
        "69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 01",
        "00 04 00 08 00 00 00 04 00 00 00 01",
    ])

    static let soundingIP = DJLinkIPv4(169, 254, 41, 7)
    static let soundingMAC = DJLinkMAC([0x3c, 0x18, 0xa0, 0x11, 0x22, 0x33])
}

final class DJLinkCodecTests: XCTestCase {
    private func decode(_ bytes: [UInt8], port: UInt16) -> DJLinkPacket? {
        DJLinkPacket.decode(Data(bytes), port: port)
    }

    func testKeepAliveNXS2RoundTrips() throws {
        guard case .keepAlive(let p) = decode(DJLinkFixture.keepAliveNXS2, port: DJLinkPort.announce) else { return XCTFail() }
        XCTAssertEqual(p.name, "CDJ-2000NXS2")
        XCTAssertEqual(p.device, 2)
        XCTAssertEqual(p.ip, DJLinkIPv4(169, 254, 41, 12))
        XCTAssertEqual(p.mac.description, "00:e0:36:a1:b2:c3")
        XCTAssertEqual(p.peerCount, 3)
        XCTAssertFalse(p.isMixer)
        XCTAssertFalse(p.firstOnNetwork)
        XCTAssertFalse(p.cdj3000Compatible)
        XCTAssertEqual([UInt8](DJLinkPacket.keepAlive(p).encode()), DJLinkFixture.keepAliveNXS2)
    }

    func testKeepAliveCDJ3000RoundTrips() {
        guard case .keepAlive(let p) = decode(DJLinkFixture.keepAliveCDJ3000, port: DJLinkPort.announce) else { return XCTFail() }
        XCTAssertEqual(p.name, "CDJ-3000")
        XCTAssertEqual(p.device, 5)
        XCTAssertTrue(p.firstOnNetwork)
        XCTAssertTrue(p.cdj3000Compatible)
        XCTAssertEqual([UInt8](DJLinkPacket.keepAlive(p).encode()), DJLinkFixture.keepAliveCDJ3000)
    }

    func testSoundingAnnouncementPacketsMatchPublishedLayout() {
        let keepAlive = DJLinkKeepAlive(name: "Sounding", device: 7, mac: DJLinkFixture.soundingMAC, ip: DJLinkFixture.soundingIP, peerCount: 3)
        XCTAssertEqual([UInt8](DJLinkPacket.keepAlive(keepAlive).encode()), DJLinkFixture.soundingKeepAlive)
        XCTAssertEqual([UInt8](DJLinkPacket.announce(DJLinkAnnounce(name: "Sounding")).encode()), DJLinkFixture.soundingAnnounce)
        XCTAssertEqual([UInt8](DJLinkPacket.announce(DJLinkAnnounce(name: "Sounding", cdj3000Compatible: true)).encode()), DJLinkFixture.soundingAnnounce3000)
        XCTAssertEqual(
            [UInt8](DJLinkPacket.claimStage1(DJLinkClaimStage1(name: "Sounding", counter: 1, mac: DJLinkFixture.soundingMAC, cdj3000Compatible: true)).encode()),
            DJLinkFixture.soundingClaim1For3000
        )
        XCTAssertEqual(
            [UInt8](DJLinkPacket.claimStage2(DJLinkClaimStage2(
                name: "Sounding", ip: DJLinkFixture.soundingIP, mac: DJLinkFixture.soundingMAC, device: 6, counter: 2,
                autoAssign: false, cdj3000Compatible: true
            )).encode()),
            DJLinkFixture.soundingClaim2For3000
        )
        XCTAssertEqual(
            [UInt8](DJLinkPacket.claimStage3(DJLinkClaimStage3(name: "Sounding", device: 6, counter: 3, cdj3000Compatible: true)).encode()),
            DJLinkFixture.soundingClaim3For3000
        )
        guard case .claimStage2(let decoded) = decode(DJLinkFixture.soundingClaim2For3000, port: DJLinkPort.announce) else { return XCTFail() }
        XCTAssertEqual(decoded.device, 6)
        XCTAssertFalse(decoded.autoAssign)
        XCTAssertTrue(decoded.cdj3000Compatible)
    }

    func testBeatNXS2Decodes() {
        guard case .beat(let p) = decode(DJLinkFixture.beatNXS2, port: DJLinkPort.beat) else { return XCTFail() }
        XCTAssertEqual(p.name, "CDJ-2000NXS2")
        XCTAssertEqual(p.device, 1)
        XCTAssertEqual(p.nextBeat, 484)
        XCTAssertEqual(p.nextBar, 1452)
        XCTAssertEqual(p.secondBar, 3388)
        XCTAssertEqual(p.beatWithinBar, 2)
        XCTAssertEqual(p.trackBPM, 124, accuracy: 0.001)
        XCTAssertEqual(p.pitch.percent, 1.5625, accuracy: 0.0001)
        XCTAssertEqual(p.effectiveBPM, 125.9375, accuracy: 0.0001)
        XCTAssertEqual([UInt8](DJLinkPacket.beat(p).encode()), DJLinkFixture.beatNXS2)
    }

    func testCDJStatusNXS2Decodes() {
        guard case .cdjStatus(let p) = decode(DJLinkFixture.statusNXS2, port: DJLinkPort.status) else { return XCTFail() }
        XCTAssertEqual(p.name, "CDJ-2000NXS2")
        XCTAssertEqual(p.device, 2)
        XCTAssertEqual(p.length, 0x11c)
        XCTAssertEqual(p.sourcePlayer, 2)
        XCTAssertEqual(DJPlayerMediaSlot(raw: p.sourceSlot), .usb)
        XCTAssertEqual(p.trackType, 1)
        XCTAssertEqual(p.rekordboxId, 1204)
        XCTAssertEqual(p.trackNumber, 7)
        XCTAssertEqual(p.playState, .playing)
        XCTAssertEqual(p.firmware, "1.85")
        XCTAssertTrue(p.isPlaying)
        XCTAssertTrue(p.isMaster)
        XCTAssertTrue(p.isSynced)
        XCTAssertTrue(p.isOnAir)
        XCTAssertEqual(p.trackBPM ?? 0, 124, accuracy: 0.001)
        XCTAssertEqual(p.effectiveBPM ?? 0, 125.9375, accuracy: 0.0001)
        XCTAssertEqual(p.beat, 233)
        XCTAssertEqual(p.beatWithinBar, 1)
        XCTAssertEqual(p.masterMeaning, 1)
        XCTAssertEqual(p.masterHandoff, 0xff)
        XCTAssertEqual(p.syncCounter, 5)
        XCTAssertEqual(p.packetCounter, 0x1234)
        XCTAssertNil(p.key)
    }

    func testCDJStatusCDJ3000Decodes() {
        guard case .cdjStatus(let p) = decode(DJLinkFixture.statusCDJ3000, port: DJLinkPort.status) else { return XCTFail() }
        XCTAssertEqual(p.name, "CDJ-3000")
        XCTAssertEqual(p.subtype, 0x06)
        XCTAssertEqual(p.length, 0x200)
        XCTAssertEqual(p.rekordboxId, 3311)
        XCTAssertEqual(p.playState, .looping)
        XCTAssertEqual(p.firmware, "3.11")
        XCTAssertTrue(p.isPlaying)
        XCTAssertFalse(p.isMaster)
        XCTAssertTrue(p.isOnAir)
        XCTAssertEqual(p.trackBPM ?? 0, 130, accuracy: 0.001)
        XCTAssertEqual(p.beat, 512)
        XCTAssertEqual(p.cueCountdown, 32)
        XCTAssertEqual(p.beatWithinBar, 3)
        XCTAssertEqual(p.nexusMarker, 0x1f)
        XCTAssertEqual(p.masterTempoEngaged, true)
        XCTAssertEqual(p.key?.displayName, "Gm")
        XCTAssertEqual(p.loopStartMillis ?? 0, 196_608, accuracy: 0.001)
        XCTAssertEqual(p.loopEndMillis ?? 0, 200_540.16, accuracy: 0.001)
    }

    func testAbsolutePositionDecodes() {
        guard case .absolutePosition(let p) = decode(DJLinkFixture.absolutePositionCDJ3000, port: DJLinkPort.beat) else { return XCTFail() }
        XCTAssertEqual(p.device, 1)
        XCTAssertEqual(p.trackLengthSeconds, 412)
        XCTAssertEqual(p.playheadMillis, 196_000)
        XCTAssertEqual(p.pitchHundredths, -326)
        XCTAssertEqual(p.effectiveBPM ?? 0, 125.8, accuracy: 0.001)
        XCTAssertEqual([UInt8](DJLinkPacket.absolutePosition(p).encode()), DJLinkFixture.absolutePositionCDJ3000)
    }

    func testMixerStatusRoundTrips() {
        guard case .mixerStatus(let p) = decode(DJLinkFixture.mixerStatusDJM, port: DJLinkPort.status) else { return XCTFail() }
        XCTAssertEqual(p.name, "DJM-900NXS2")
        XCTAssertEqual(p.device, 0x21)
        XCTAssertTrue(p.isMaster)
        XCTAssertEqual(p.bpm ?? 0, 126, accuracy: 0.001)
        XCTAssertEqual(p.beatWithinBar, 3)
        XCTAssertEqual([UInt8](DJLinkPacket.mixerStatus(p).encode()), DJLinkFixture.mixerStatusDJM)
    }

    func testControlPacketsMatchPublishedLayout() {
        XCTAssertEqual([UInt8](DJLinkPacket.syncControl(DJLinkSyncControl(name: "Sounding", device: 4, command: DJLinkSyncCommand.syncOn.rawValue)).encode()), DJLinkFixture.soundingSyncOn)
        XCTAssertEqual([UInt8](DJLinkPacket.masterRequest(DJLinkMasterRequest(name: "Sounding", device: 4)).encode()), DJLinkFixture.soundingMasterRequest)
        XCTAssertEqual([UInt8](DJLinkPacket.masterResponse(DJLinkMasterResponse(name: "Sounding", device: 4, accepted: true)).encode()), DJLinkFixture.soundingMasterResponse)
    }

    func testRejectsForeignAndTruncatedPackets() {
        XCTAssertNil(DJLinkPacket.decode(Data(repeating: 0, count: 64), port: DJLinkPort.announce))
        XCTAssertNil(DJLinkPacket.decode(Data(DJLinkFixture.statusNXS2.prefix(0x80)), port: DJLinkPort.status))
        XCTAssertNil(DJLinkPacket.decode(Data(DJLinkFixture.keepAliveNXS2), port: 9))
    }
}

final class FakeCDJ {
    var name: String
    var number: UInt8
    var ip: DJLinkIPv4
    var mac: DJLinkMAC
    var isCDJ3000: Bool
    var bpm: Double = 124
    var pitch: Double = 1
    var isPlaying = true
    var isMaster = false
    var isOnAir = true
    var trackId: UInt32 = 1204
    var beat: UInt32 = 1
    var beatWithinBar: UInt8 = 1
    var masterHandoff: UInt8 = 0xff
    var syncCounter: UInt32 = 1

    init(number: UInt8, cdj3000: Bool = false) {
        self.number = number
        self.isCDJ3000 = cdj3000
        name = cdj3000 ? "CDJ-3000" : "CDJ-2000NXS2"
        ip = DJLinkIPv4(169, 254, 41, 10 + number)
        mac = DJLinkMAC([0x00, 0xe0, 0x36, 0x00, 0x00, number])
    }

    func keepAlive() -> DJLinkPacket {
        .keepAlive(DJLinkKeepAlive(name: name, device: number, mac: mac, ip: ip, peerCount: 2, cdj3000Compatible: isCDJ3000))
    }

    func status() -> DJLinkPacket {
        var status = DJLinkCDJStatus(name: name, device: number)
        status.length = isCDJ3000 ? 0x200 : 0x11c
        status.subtype = isCDJ3000 ? 0x06 : 0x03
        status.activity = isPlaying ? 1 : 0
        status.sourcePlayer = number
        status.sourceSlot = 0x03
        status.trackType = 0x01
        status.rekordboxId = trackId
        status.playStateRaw = isPlaying ? DJLinkPlayState.playing.rawValue : DJLinkPlayState.cued.rawValue
        var flags = DJLinkStatusFlags.fixedBits
        if isPlaying { flags.insert(.playing) }
        if isMaster { flags.insert(.master) }
        if isOnAir { flags.insert(.onAir) }
        status.flags = flags
        status.pitch1 = DJLinkPitch(multiplier: pitch)
        status.tempoMasterValidity = 0x8000
        status.bpmHundredths = UInt16((bpm * 100).rounded())
        status.masterMeaning = isMaster ? 1 : 0
        status.masterHandoff = masterHandoff
        status.beatNumber = beat
        status.beatWithinBar = beatWithinBar
        status.syncCounter = syncCounter
        status.nexusMarker = isCDJ3000 ? 0x1f : 0x0f
        return .cdjStatus(status)
    }

    func beatPacket() -> DJLinkPacket {
        let period = UInt32((60 / bpm * 1000).rounded())
        return .beat(DJLinkBeat(
            name: name, device: number, nextBeat: period, secondBeat: period * 2, nextBar: period * UInt32(5 - Int(beatWithinBar)),
            fourthBeat: period * 4, secondBar: period * UInt32(9 - Int(beatWithinBar)), eighthBeat: period * 8,
            pitch: DJLinkPitch(multiplier: pitch), bpmHundredths: UInt16((bpm * 100).rounded()), beatWithinBar: beatWithinBar
        ))
    }

    func deliver(_ packet: DJLinkPacket, to engine: DJLinkEngine, at now: TimeInterval) {
        engine.receive(packet.encode(), from: ip, port: packet.port, now: now)
    }

    func announce(to engine: DJLinkEngine, at now: TimeInterval) {
        deliver(keepAlive(), to: engine, at: now)
        deliver(status(), to: engine, at: now)
    }
}

final class DJLinkEngineTests: XCTestCase {
    private func engine(_ identity: DJLinkIdentity) -> DJLinkEngine {
        DJLinkEngine(identity: identity, localIP: DJLinkFixture.soundingIP, localMAC: DJLinkFixture.soundingMAC)
    }

    private func packets(_ outbound: [DJLinkOutbound]) -> [DJLinkPacket] {
        outbound.map { DJLinkPacket.decode($0.packet.encode(), port: $0.destination.port)! }
    }

    func testObserverDiscoversPlayersAndJoinsAsSeven() {
        let engine = engine(.observer)
        let one = FakeCDJ(number: 1)
        let two = FakeCDJ(number: 2)
        one.isMaster = true
        two.isPlaying = false
        two.isOnAir = false
        engine.start(now: 0)
        one.announce(to: engine, at: 0.5)
        two.announce(to: engine, at: 0.6)
        engine.tick(now: 1)
        XCTAssertEqual(engine.phase, .listening)
        XCTAssertTrue(engine.drainOutbox().isEmpty)

        engine.tick(now: 2.3)
        XCTAssertEqual(engine.phase, .active(number: 7))
        let sent = engine.drainOutbox()
        XCTAssertEqual(sent.count, 1)
        guard case .keepAlive(let keepAlive) = sent[0].packet else { return XCTFail() }
        XCTAssertEqual(keepAlive.device, 7)
        XCTAssertEqual(keepAlive.peerCount, 3)
        XCTAssertEqual(sent[0].destination, .broadcast(DJLinkPort.announce))

        let snapshot = engine.snapshot(now: 2.3)
        XCTAssertEqual(snapshot.visiblePlayers.map(\.number), [1, 2])
        let first = snapshot.visiblePlayers[0]
        XCTAssertEqual(first.name, "CDJ-2000NXS2")
        XCTAssertEqual(first.status?.activity, .playing)
        XCTAssertEqual(first.status?.isMaster, true)
        XCTAssertEqual(first.status?.isOnAir, true)
        XCTAssertEqual(first.status?.track?.rekordboxId, 1204)
        XCTAssertEqual(first.status?.track?.slot, .usb)
        XCTAssertEqual(snapshot.visiblePlayers[1].status?.activity, .cued)

        engine.tick(now: 3.81)
        XCTAssertEqual(engine.drainOutbox().count, 1)
    }

    func testObserverSkipsTakenObserverNumbers() {
        let engine = engine(.observer)
        let squatter = FakeCDJ(number: 7)
        squatter.name = "Beat Link"
        engine.start(now: 0)
        squatter.deliver(squatter.keepAlive(), to: engine, at: 0.2)
        engine.tick(now: 2.5)
        XCTAssertEqual(engine.phase, .active(number: 8))
    }

    func testDevicesExpireAfterSilence() {
        let engine = engine(.observer)
        let one = FakeCDJ(number: 1)
        engine.start(now: 0)
        one.announce(to: engine, at: 0.1)
        engine.tick(now: 2.5)
        XCTAssertEqual(engine.snapshot(now: 2.5).visiblePlayers.count, 1)
        engine.tick(now: 9)
        XCTAssertEqual(engine.snapshot(now: 9).visiblePlayers.count, 0)
    }

    func testTempoReferenceFollowsMasterBeats() {
        let engine = engine(.observer)
        let one = FakeCDJ(number: 1)
        one.isMaster = true
        one.bpm = 124
        one.pitch = 1.015625
        engine.start(now: 0)
        one.announce(to: engine, at: 0.1)
        one.beatWithinBar = 3
        one.deliver(one.beatPacket(), to: engine, at: 0.5)
        let tempo = engine.snapshot(now: 0.6).tempo
        XCTAssertEqual(tempo?.masterNumber, 1)
        XCTAssertEqual(tempo?.bpm ?? 0, 125.9375, accuracy: 0.001)
        XCTAssertEqual(tempo?.beatWithinBar, 3)
        XCTAssertEqual(tempo?.isRunning, true)
        let period = 60 / 125.9375
        XCTAssertEqual(tempo?.beatPhase(at: 0.5 + period / 2) ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(tempo?.barPhase(at: 0.5) ?? 0, 0.5, accuracy: 0.0001)
    }

    func testVirtualDeckClaimsHighestFreeNumberWithFullSequence() {
        let engine = engine(.virtualDeck(preferred: nil))
        let one = FakeCDJ(number: 1)
        let four = FakeCDJ(number: 4)
        engine.start(now: 0)
        one.announce(to: engine, at: 0.1)
        four.announce(to: engine, at: 0.1)
        var now = 2.2
        var sent: [DJLinkPacket] = []
        while now < 7 {
            engine.tick(now: now)
            sent += packets(engine.drainOutbox())
            now += 0.05
        }
        XCTAssertEqual(engine.phase, .active(number: 3))
        let kinds = sent.prefix(12).map { packet -> String in
            switch packet {
            case .announce: return "A"
            case .claimStage1: return "1"
            case .claimStage2(let p): return p.device == 3 ? "2" : "?"
            case .claimStage3(let p): return p.device == 3 ? "3" : "?"
            default: return "x"
            }
        }
        XCTAssertEqual(kinds.joined(), "AAA111222333")
        XCTAssertTrue(sent.contains { if case .keepAlive(let k) = $0 { return k.device == 3 && !k.cdj3000Compatible } else { return false } })
        XCTAssertTrue(sent.contains { if case .cdjStatus(let s) = $0 { return s.device == 3 } else { return false } })
    }

    func testVirtualDeckOnCDJ3000RigUsesCompatiblePacketsAndExtendedNumbers() {
        let engine = engine(.virtualDeck(preferred: nil))
        let players = (1...4).map { FakeCDJ(number: UInt8($0), cdj3000: true) }
        engine.start(now: 0)
        for player in players { player.announce(to: engine, at: 0.1) }
        var now = 2.2
        var sent: [DJLinkPacket] = []
        while now < 7 {
            engine.tick(now: now)
            sent += packets(engine.drainOutbox())
            now += 0.05
        }
        XCTAssertEqual(engine.phase, .active(number: 6))
        guard case .announce(let announce) = sent.first else { return XCTFail() }
        XCTAssertTrue(announce.cdj3000Compatible)
        XCTAssertTrue(sent.contains { if case .claimStage2(let p) = $0 { return p.cdj3000Compatible && p.device == 6 } else { return false } })
        XCTAssertTrue(sent.contains { if case .keepAlive(let k) = $0 { return k.cdj3000Compatible && k.device == 6 } else { return false } })
    }

    func testConflictMovesAutomaticClaimToNextNumber() {
        let engine = engine(.virtualDeck(preferred: nil))
        let defender = FakeCDJ(number: 4)
        engine.start(now: 0)
        engine.tick(now: 2.3)
        XCTAssertEqual(engine.phase, .claiming(number: 4))
        defender.deliver(.conflict(DJLinkConflict(name: defender.name, device: 4, ip: defender.ip)), to: engine, at: 2.4)
        engine.tick(now: 2.5)
        XCTAssertEqual(engine.phase, .claiming(number: 3))
    }

    func testPreferredNumberInUseReportsTaken() {
        let engine = engine(.virtualDeck(preferred: 2))
        FakeCDJ(number: 2).announce(to: engine, at: 0.1)
        engine.start(now: 0)
        FakeCDJ(number: 2).announce(to: engine, at: 0.2)
        engine.tick(now: 2.3)
        XCTAssertEqual(engine.phase, .numberTaken(number: 2))
        XCTAssertEqual(engine.drainEvents(), [.numberTaken(2)])
    }

    func testAssignmentFinishedShortensClaim() {
        let engine = engine(.virtualDeck(preferred: nil))
        let one = FakeCDJ(number: 1)
        engine.start(now: 0)
        one.announce(to: engine, at: 0.1)
        var now = 2.2
        var sawFinalStage = false
        while now < 7, !sawFinalStage {
            engine.tick(now: now)
            sawFinalStage = engine.drainOutbox().contains { if case .claimStage3 = $0.packet { return true } else { return false } }
            now += 0.05
        }
        XCTAssertTrue(sawFinalStage)
        XCTAssertEqual(engine.phase, .claiming(number: 4))
        one.deliver(.assignmentFinished(DJLinkAssignmentFinished(name: one.name, device: 1)), to: engine, at: now)
        XCTAssertEqual(engine.phase, .active(number: 4))
    }

    private func activeVirtualDeck(players: [FakeCDJ], preferred: Int = 4) -> (DJLinkEngine, TimeInterval) {
        let engine = engine(.virtualDeck(preferred: preferred))
        engine.start(now: 0)
        for player in players { player.announce(to: engine, at: 0.1) }
        var now = 2.2
        while now < 7 {
            engine.tick(now: now)
            now += 0.05
        }
        _ = engine.drainOutbox()
        _ = engine.drainEvents()
        return (engine, now)
    }

    func testVirtualDeckBroadcastsBeatsOnTheGrid() {
        let one = FakeCDJ(number: 1)
        let (engine, start) = activeVirtualDeck(players: [one])
        XCTAssertEqual(engine.phase, .active(number: 4))
        let deck = DJVirtualDeckSnapshot(
            isLoaded: true, isPlaying: true, trackBPM: 128, rate: 1, positionSeconds: 10.0,
            anchorTime: start, gridAnchorSeconds: 0.2, downbeatOffset: 1, durationSeconds: 400
        )
        engine.setDeck(deck, now: start)
        var beats: [(time: TimeInterval, beat: DJLinkBeat)] = []
        var now = start
        while now < start + 2.01 {
            engine.tick(now: now)
            for outbound in engine.drainOutbox() {
                if case .beat(let beat) = outbound.packet {
                    XCTAssertEqual(outbound.destination, .broadcast(DJLinkPort.beat))
                    beats.append((now, beat))
                }
            }
            if let next = engine.nextDeadline(after: now) { now = max(now + 0.0005, min(next, now + 0.05)) } else { now += 0.05 }
        }
        XCTAssertEqual(beats.count, 5)
        let period = 60.0 / 128
        let firstIndex = Int(ceil((10.0 - 0.2) / period))
        let expectedFirst = start + (0.2 + Double(firstIndex) * period - 10.0)
        XCTAssertEqual(beats[0].time, expectedFirst, accuracy: 0.002)
        XCTAssertEqual(beats[1].time - beats[0].time, period, accuracy: 0.002)
        XCTAssertEqual(beats[0].beat.beatWithinBar, UInt8(deck.beatWithinBar(ofBeat: firstIndex)))
        XCTAssertEqual(beats[0].beat.bpmHundredths, 12800)
        XCTAssertEqual(beats[0].beat.nextBeat, 469)
        XCTAssertEqual(beats[0].beat.device, 4)
        let bars = beats.map(\.beat.beatWithinBar)
        XCTAssertTrue(zip(bars, bars.dropFirst()).allSatisfy { $1 == $0 % 4 + 1 })
        XCTAssertEqual([UInt8](DJLinkPacket.beat(engine.beatPacket(index: 4, device: 4)!).encode()).count, 0x60)
    }

    func testVirtualDeckGoldenBeatMatchesFixture() {
        let (engine, start) = activeVirtualDeck(players: [FakeCDJ(number: 1)])
        engine.setDeck(DJVirtualDeckSnapshot(
            isLoaded: true, isPlaying: true, trackBPM: 128, rate: 1, positionSeconds: 0,
            anchorTime: start, gridAnchorSeconds: 0, downbeatOffset: 0, durationSeconds: 600
        ), now: start)
        let beat = engine.beatPacket(index: 0, device: 4)!
        XCTAssertEqual([UInt8](DJLinkPacket.beat(beat).encode()), DJLinkFixture.soundingBeat)
    }

    func testVirtualDeckSendsStatusToEveryPlayerAndStopsBeatsWhenPaused() {
        let one = FakeCDJ(number: 1)
        let two = FakeCDJ(number: 2)
        let (engine, start) = activeVirtualDeck(players: [one, two])
        engine.setDeck(DJVirtualDeckSnapshot(
            isLoaded: true, isPlaying: false, trackBPM: 126, rate: 1.02, positionSeconds: 30.1,
            anchorTime: start, gridAnchorSeconds: 0, downbeatOffset: 0, durationSeconds: 300
        ), now: start)
        engine.tick(now: start + 0.25)
        let sent = engine.drainOutbox()
        let statuses = sent.compactMap { outbound -> (DJLinkIPv4, DJLinkCDJStatus)? in
            if case .cdjStatus(let s) = outbound.packet, case .unicast(let ip, let port) = outbound.destination, port == DJLinkPort.status { return (ip, s) }
            return nil
        }
        XCTAssertEqual(Set(statuses.map(\.0)), [one.ip, two.ip])
        XCTAssertFalse(sent.contains { if case .beat = $0.packet { return true } else { return false } })
        let status = statuses[0].1
        XCTAssertEqual(status.device, 4)
        XCTAssertEqual(status.playState, .paused)
        XCTAssertFalse(status.isPlaying)
        XCTAssertEqual(status.trackBPM ?? 0, 126, accuracy: 0.001)
        XCTAssertEqual(status.pitch1.multiplier, 1.02, accuracy: 0.0001)
        XCTAssertEqual(status.tempoMasterValidity, 0x8000)
        let decoded = DJLinkPacket.decode(DJLinkPacket.cdjStatus(status).encode(), port: DJLinkPort.status)
        guard case .cdjStatus(let roundTrip) = decoded else { return XCTFail() }
        XCTAssertEqual(roundTrip.beat, UInt32(Int(30.1 / (60.0 / 126)) + 1))
        XCTAssertEqual(roundTrip.length, DJLinkCDJStatus.nexusLength)
    }

    func testMasterHandoffWithCDJ() {
        let one = FakeCDJ(number: 1)
        one.isMaster = true
        let (engine, start) = activeVirtualDeck(players: [one])
        engine.setDeck(DJVirtualDeckSnapshot(
            isLoaded: true, isPlaying: true, trackBPM: 128, rate: 1, positionSeconds: 0,
            anchorTime: start, gridAnchorSeconds: 0, downbeatOffset: 0, durationSeconds: 300
        ), now: start)
        engine.requestMaster(now: start)
        let request = engine.drainOutbox().first { if case .masterRequest = $0.packet { return true } else { return false } }
        XCTAssertEqual(request?.destination, .unicast(one.ip, DJLinkPort.beat))
        XCTAssertFalse(engine.isMaster)

        one.deliver(.masterResponse(DJLinkMasterResponse(name: one.name, device: 1, accepted: true)), to: engine, at: start + 0.01)
        one.masterHandoff = 4
        one.deliver(one.status(), to: engine, at: start + 0.2)
        XCTAssertTrue(engine.isMaster)
        XCTAssertEqual(engine.drainEvents(), [.becameMaster])
        XCTAssertNil(engine.snapshot(now: start + 0.2).tempo)
        XCTAssertTrue(engine.snapshot(now: start + 0.2).isVirtualDeckMaster)

        engine.tick(now: start + 0.45)
        let status = engine.drainOutbox().compactMap { if case .cdjStatus(let s) = $0.packet { return s } else { return nil } }.last
        XCTAssertEqual(status?.isMaster, true)
        XCTAssertEqual(status?.masterMeaning, 1)

        one.isMaster = false
        one.masterHandoff = 0xff
        one.deliver(.masterRequest(DJLinkMasterRequest(name: one.name, device: 1)), to: engine, at: start + 0.5)
        let response = engine.drainOutbox().compactMap { outbound -> DJLinkMasterResponse? in
            if case .masterResponse(let r) = outbound.packet { return r } else { return nil }
        }.first
        XCTAssertEqual(response?.device, 4)
        XCTAssertEqual(response?.accepted, true)
        engine.tick(now: start + 0.65)
        let handing = engine.drainOutbox().compactMap { if case .cdjStatus(let s) = $0.packet { return s } else { return nil } }.last
        XCTAssertEqual(handing?.masterHandoff, 1)

        one.isMaster = true
        one.deliver(one.status(), to: engine, at: start + 0.7)
        XCTAssertFalse(engine.isMaster)
        XCTAssertEqual(engine.drainEvents(), [.resignedMaster])
    }

    func testSyncCommandsFromMixer() {
        let one = FakeCDJ(number: 1)
        let (engine, start) = activeVirtualDeck(players: [one])
        engine.receive(DJLinkPacket.syncControl(DJLinkSyncControl(name: "DJM-900NXS2", device: 0x21, command: 0x10)).encode(), from: one.ip, port: DJLinkPort.beat, now: start)
        XCTAssertTrue(engine.isSynced)
        engine.receive(DJLinkPacket.syncControl(DJLinkSyncControl(name: "DJM-900NXS2", device: 0x21, command: 0x20)).encode(), from: one.ip, port: DJLinkPort.beat, now: start)
        XCTAssertFalse(engine.isSynced)
        XCTAssertEqual(engine.drainEvents(), [.syncCommand(on: true), .syncCommand(on: false)])
    }

    func testDefendsClaimedNumber() {
        let one = FakeCDJ(number: 1)
        let (engine, start) = activeVirtualDeck(players: [one])
        let intruder = FakeCDJ(number: 3)
        intruder.deliver(.claimStage2(DJLinkClaimStage2(
            name: intruder.name, ip: intruder.ip, mac: intruder.mac, device: 4, counter: 1, autoAssign: false
        )), to: engine, at: start)
        let conflict = engine.drainOutbox().first
        XCTAssertEqual(conflict?.destination, .unicast(intruder.ip, DJLinkPort.announce))
        guard case .conflict(let packet) = conflict?.packet else { return XCTFail() }
        XCTAssertEqual(packet.device, 4)
        XCTAssertEqual(packet.ip, DJLinkFixture.soundingIP)
    }

    func testIgnoresOwnBroadcastEcho() {
        let (engine, start) = activeVirtualDeck(players: [FakeCDJ(number: 1)])
        let own = DJLinkKeepAlive(name: "Sounding", device: 4, mac: DJLinkFixture.soundingMAC, ip: DJLinkFixture.soundingIP, peerCount: 2)
        engine.receive(DJLinkPacket.keepAlive(own).encode(), from: DJLinkFixture.soundingIP, port: DJLinkPort.announce, now: start)
        XCTAssertEqual(engine.phase, .active(number: 4))
        XCTAssertEqual(engine.snapshot(now: start).players.map(\.number), [1])
    }
}

final class DJPlayersSetlistTests: XCTestCase {
    private func player(_ number: Int, track: UInt32?, activity: DJPlayerActivity = .playing, onAir: Bool = true, bpm: Double = 120) -> DJPlayer {
        var status = DJPlayerStatus()
        status.activity = activity
        status.trackBPM = bpm
        status.isOnAir = onAir
        status.track = track.map { DJPlayerTrackKey(sourcePlayer: number, slot: .usb, trackType: 1, rekordboxId: $0) }
        return DJPlayer(number: number, name: "CDJ-3000", ip: .zero, mac: .zero, lastSeen: 0, reportsAsMixer: false, status: status)
    }

    private let mixer = DJPlayer(number: 33, name: "DJM-A9", ip: .zero, mac: .zero, lastSeen: 0, reportsAsMixer: true, status: nil)

    func testRecordsOnceAfterMinimumBarsOnAir() {
        var recorder = DJPlayersSetlistRecorder(minimumBars: 16)
        let start = Date(timeIntervalSince1970: 1_000)
        var plays: [DJPlayersRecordedPlay] = []
        for step in 0...130 {
            let t = Double(step) * 0.25
            plays += recorder.observe([player(1, track: 42), player(2, track: 7, onAir: false), mixer], now: t, date: start.addingTimeInterval(t))
        }
        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays.first?.track.rekordboxId, 42)
        XCTAssertEqual(plays.first?.playerNumber, 1)
        XCTAssertEqual(plays.first?.startedAt, start)
    }

    func testBelowThresholdDoesNotRecord() {
        var recorder = DJPlayersSetlistRecorder(minimumBars: 16)
        var plays: [DJPlayersRecordedPlay] = []
        for step in 0...100 {
            plays += recorder.observe([player(1, track: 42), mixer], now: Double(step) * 0.25, date: Date())
        }
        XCTAssertTrue(plays.isEmpty)
    }

    func testWithoutMixerOnAirIsNotRequired() {
        var recorder = DJPlayersSetlistRecorder(minimumBars: 8)
        var plays: [DJPlayersRecordedPlay] = []
        for step in 0...70 {
            plays += recorder.observe([player(1, track: 9, onAir: false)], now: Double(step) * 0.25, date: Date())
        }
        XCTAssertEqual(plays.count, 1)
    }

    func testLoadingANewTrackStartsOver() {
        var recorder = DJPlayersSetlistRecorder(minimumBars: 8)
        var plays: [DJPlayersRecordedPlay] = []
        var t = 0.0
        while t < 40 {
            plays += recorder.observe([player(1, track: t < 20 ? 1 : 2), mixer], now: t, date: Date())
            t += 0.25
        }
        XCTAssertEqual(plays.map(\.track.rekordboxId), [1, 2])
        while t < 60 {
            plays += recorder.observe([player(1, track: 2, activity: .paused), mixer], now: t, date: Date())
            t += 0.25
        }
        XCTAssertEqual(plays.count, 2)
    }

    func testBuilderMakesASavedRecordedSetlist() {
        let start = Date(timeIntervalSince1970: 1_793_998_800)
        var builder = DJPlayersSetlistBuilder(startedAt: start)
        XCTAssertTrue(builder.setlist.trackTitle.hasPrefix("Recorded at "))
        XCTAssertTrue(builder.setlist.isSaved)
        let play = DJPlayersRecordedPlay(
            playerNumber: 2, playerName: "CDJ-3000",
            track: DJPlayerTrackKey(sourcePlayer: 2, slot: .usb, trackType: 1, rekordboxId: 3311),
            startedAt: start.addingTimeInterval(95)
        )
        _ = builder.append(play, info: nil, now: start.addingTimeInterval(130))
        let setlist = builder.append(
            DJPlayersRecordedPlay(playerNumber: 1, playerName: "CDJ-3000", track: DJPlayerTrackKey(sourcePlayer: 1, slot: .usb, trackType: 1, rekordboxId: 12), startedAt: start.addingTimeInterval(400)),
            info: DJPlayersTrackInfo(title: "Glue", artist: "Bicep"),
            now: start.addingTimeInterval(430)
        )
        XCTAssertTrue(setlist.trackId.hasPrefix(DJPlayersSetlistBuilder.trackIdPrefix))
        XCTAssertEqual(setlist.activeSegments.map(\.displayLabel), ["Unknown Track", "Bicep – Glue"])
        XCTAssertEqual(setlist.activeSegments.map(\.startSeconds), [95, 400])
        XCTAssertEqual(setlist.duration, 430, accuracy: 0.001)
        XCTAssertEqual(setlist.tracklist.entries.first?.endSeconds, 400)
    }
}

final class LoopbackFlags: @unchecked Sendable {
    private let lock = NSLock()
    var discovered = false
    var heard = false

    func mark(_ flag: ReferenceWritableKeyPath<LoopbackFlags, Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !self[keyPath: flag] else { return false }
        self[keyPath: flag] = true
        return true
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return discovered && heard
    }
}

final class DJLinkLoopbackTests: XCTestCase {
    func testRuntimeDiscoversFakeCDJOverLoopbackSockets() throws {
        let base: UInt16 = UInt16.random(in: 40_000...45_000)
        let soundingPorts = DJLinkPortMap.offset(local: base, remote: base + 10)
        let cdjPorts = DJLinkPortMap.offset(local: base + 10, remote: base)
        let transport = DJLinkSocketTransport(interfaceIndex: nil, broadcastAddress: .loopback, ports: soundingPorts)
        var timing = DJLinkEngineTiming()
        timing.listenWindow = 0.3
        timing.keepAliveInterval = 0.2
        let engine = DJLinkEngine(identity: .observer, localIP: .loopback, localMAC: DJLinkFixture.soundingMAC, timing: timing)
        let runtime = DJLinkRuntime(transport: transport, engine: engine, publishInterval: 0.05)

        let discovered = expectation(description: "player discovered")
        let heardKeepAlive = expectation(description: "fake CDJ heard Sounding")
        let flags = LoopbackFlags()
        runtime.onSnapshot = { snapshot in
            guard let player = snapshot.visiblePlayers.first,
                  player.number == 2, player.status?.track?.rekordboxId == 1204,
                  flags.mark(\.discovered) else { return }
            discovered.fulfill()
        }

        let cdj = FakeCDJ(number: 2)
        cdj.ip = .loopback
        let cdjTransport = DJLinkSocketTransport(interfaceIndex: nil, broadcastAddress: .loopback, ports: cdjPorts)
        let cdjQueue = DispatchQueue(label: "fake.cdj")
        try cdjTransport.open(on: cdjQueue) { data, _, port in
            guard case .keepAlive(let keepAlive) = DJLinkPacket.decode(data, port: port), keepAlive.name == "Sounding",
                  flags.mark(\.heard) else { return }
            heardKeepAlive.fulfill()
        }
        try runtime.start()
        defer {
            runtime.stop()
            cdjQueue.sync { cdjTransport.close() }
        }

        for _ in 0..<12 {
            cdjQueue.sync {
                _ = cdjTransport.send(cdj.keepAlive().encode(), to: .broadcast(DJLinkPort.announce))
                _ = cdjTransport.send(cdj.status().encode(), to: .unicast(.loopback, DJLinkPort.status))
            }
            if flags.isComplete { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        wait(for: [discovered, heardKeepAlive], timeout: 5)
    }
}
