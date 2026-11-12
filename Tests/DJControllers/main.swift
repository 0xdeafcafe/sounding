import Foundation

@MainActor
final class RecordingSurface: DeckControlSurface {
    var values: [DeckControlAddress: Double] = [:]
    var playing: Set<MixEngine.Deck> = []
    var cueHeld: Set<MixEngine.Deck> = []
    var looping: Set<MixEngine.Deck> = []
    var pendingLoopIn: Set<MixEngine.Deck> = []
    var hotCues: [MixEngine.Deck: Set<Int>] = [:]
    var syncs: [MixEngine.Deck] = []
    var jogTicks: [MixEngine.Deck: Double] = [:]
    var jogTouched: Set<MixEngine.Deck> = []
    var performed = 0

    func value(of address: DeckControlAddress) -> Double? { values[address] }

    func setValue(_ value: Double, for address: DeckControlAddress) {
        performed += 1
        values[address] = value
    }

    func press(_ address: DeckControlAddress, isDown: Bool) {
        performed += 1
        guard let deck = address.group.deck else { return }
        switch address.control {
        case .play: if isDown { if playing.contains(deck) { playing.remove(deck) } else { playing.insert(deck) } }
        case .cue: if isDown { cueHeld.insert(deck) } else { cueHeld.remove(deck) }
        case .sync: if isDown { syncs.append(deck) }
        case .hotCue: if isDown { hotCues[deck, default: []].insert(address.index) }
        case .loopIn: if isDown { pendingLoopIn.insert(deck) }
        case .loopOut: if isDown, pendingLoopIn.remove(deck) != nil { looping.insert(deck) }
        case .loopToggle: if isDown { if looping.contains(deck) { looping.remove(deck) } else { looping.insert(deck) } }
        case .jogTouch: if isDown { jogTouched.insert(deck) } else { jogTouched.remove(deck) }
        default: break
        }
    }

    func jog(_ group: DeckGroup, ticks: Double) {
        performed += 1
        guard let deck = group.deck else { return }
        jogTicks[deck, default: 0] += ticks
    }
}

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() { failures.append("\(name) (line \(line))") }
}

func note(_ status: UInt8, _ number: UInt8, _ velocity: UInt8) -> ControllerMIDIMessage {
    ControllerMIDIMessage(status: status, data1: number, data2: velocity)!
}

func cc(_ status: UInt8, _ number: UInt8, _ value: UInt8) -> ControllerMIDIMessage {
    ControllerMIDIMessage(status: status, data1: number, data2: value)!
}

func loadFixture(_ path: String) -> [ControllerMIDIMessage] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        failures.append("fixture missing at \(path)")
        return []
    }
    return text.split(separator: "\n").compactMap { line -> ControllerMIDIMessage? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let bytes = trimmed.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 3 else {
            failures.append("bad fixture line: \(trimmed)")
            return nil
        }
        return ControllerMIDIMessage(status: bytes[0], data1: bytes[1], data2: bytes[2])
    }
}

let a = DeckGroup.deck(.a)
let b = DeckGroup.deck(.b)

// MARK: MIDI parsing

do {
    expect(note(0x90, 0x0B, 0).kind == .noteOff, "note on with velocity 0 is note off")
    expect(ControllerMIDIMessage(status: 0xF8, data1: 0, data2: 0) == nil, "clock is ignored")
    let bend = ControllerMIDIMessage(status: 0xE1, data1: 0x7F, data2: 0x7F)!
    expect(bend.kind == .pitchBend && bend.value == 16383 && bend.channel == 1, "pitch bend combines 14 bits")
    let words: [UInt32] = [0x2090_0B7F, 0x3000_0000, 0x2000_0000, 0x20B6_1F40, 0x1000_0000]
    let parsed = ControllerMIDIMessage.parse(universalPacketWords: words)
    expect(parsed.count == 2, "UMP parse skips 64-bit sysex payload words")
    expect(parsed.first == note(0x90, 0x0B, 0x7F), "UMP note on")
    expect(parsed.last == cc(0xB6, 0x1F, 0x40), "UMP control change")
}

// MARK: Profiles

do {
    let profile = ControllerProfiles.pioneerDDJ400
    expect(profile.mapping.problems.isEmpty, "DDJ-400 table is valid: \(profile.mapping.problems)")
    expect(profile.feedback.problems.isEmpty, "DDJ-400 light table is valid: \(profile.feedback.problems)")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "Network Session 1", model: "DDJ-400 Bridge")) != nil, "network session named after a DDJ-400 host matches")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "DDJ-400")) != nil, "matches DDJ-400 port")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "PIONEER DDJ-400 MIDI 1")) != nil, "matches case-insensitively")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "Port 1", manufacturer: "Pioneer DJ", model: "DDJ400")) != nil, "matches on model")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "DDJ-FLX4")) == nil, "unknown controllers do nothing")
    expect(ControllerProfiles.profile(for: ControllerDeviceInfo(name: "IAC Driver Bus 1")) == nil, "IAC bus ignored")
    expect(ControllerProfile.glob("a*c?e", matches: "abbbcde"), "glob star and question mark")
    expect(!ControllerProfile.glob("a*c", matches: "abd"), "glob mismatch")

    let broken = ControllerMapping(entries: [
        .note(0, 1, .mixer, .play),
        .note(0, 2, a, .crossfader),
        .note(0, 3, a, .hotCue, index: 9),
        ControllerMapping.Entry(midi: .note, channel: 0, number: 4, lsb: 5, address: DeckControlAddress(group: a, control: .play)),
        .note(0, 6, a, .cue),
        .note(0, 6, a, .play),
    ])
    expect(broken.problems.count == 5, "invalid tables are reported: \(broken.problems)")
}

// MARK: Static mapping

MainActor.assumeIsolated {
    let resolver = ControllerMappingResolver(ControllerProfiles.pioneerDDJ400.mapping)
    expect(resolver.resolve(note(0x90, 0x0B, 127)) == .press(DeckControlAddress(group: a, control: .play), isDown: true), "deck A play down")
    expect(resolver.resolve(note(0x90, 0x0B, 0)) == .press(DeckControlAddress(group: a, control: .play), isDown: false), "deck A play up")
    expect(resolver.resolve(note(0x91, 0x0C, 127)) == .press(DeckControlAddress(group: b, control: .cue), isDown: true), "deck B cue")
    expect(resolver.resolve(note(0x97, 0x02, 100)) == .press(DeckControlAddress(group: a, control: .hotCue, index: 2), isDown: true), "deck A hot cue 3")
    expect(resolver.resolve(note(0x99, 0x00, 127)) == .press(DeckControlAddress(group: b, control: .hotCue, index: 0), isDown: true), "deck B hot cue 1")
    expect(resolver.resolve(note(0x98, 0x02, 127)) == nil, "hot cue clear page unmapped")
    expect(resolver.resolve(cc(0xB0, 0x22, 70)) == .jog(a, ticks: 6), "deck A jog +6")
    expect(resolver.resolve(cc(0xB1, 0x23, 60)) == .jog(b, ticks: -4), "deck B jog -4")
    expect(resolver.resolve(cc(0xB0, 0x22, 64)) == nil, "centred jog is silent")
    expect(resolver.resolve(cc(0xB0, 0x29, 70)) == nil, "jog search unmapped")
    let crossfader = DeckControlAddress(group: .mixer, control: .crossfader)
    expect(resolver.resolve(cc(0xB6, 0x1F, 127)) == .set(crossfader, Double(127 << 7) / 16383), "crossfader MSB alone")
    expect(resolver.resolve(cc(0xB6, 0x3F, 127)) == .set(crossfader, 1), "crossfader full scale")
    _ = resolver.resolve(cc(0xB1, 0x0F, 127))
    expect(resolver.resolve(cc(0xB1, 0x2F, 127)) == .set(DeckControlAddress(group: b, control: .eqLow), 1), "deck B EQ low full")
    _ = resolver.resolve(cc(0xB6, 0x17, 0))
    expect(resolver.resolve(cc(0xB6, 0x37, 0)) == .set(DeckControlAddress(group: a, control: .filter), 0), "deck A filter zero")
    expect(resolver.resolve(cc(0xB3, 0x22, 70)) == nil, "channel 4 unmapped")

    let twos = ControllerMappingResolver(ControllerMapping(entries: [.cc(0, 1, a, .jog, encoding: .twosComplement)]))
    expect(twos.resolve(cc(0xB0, 1, 0x7E)) == .jog(a, ticks: -2), "twos complement jog")
}

// MARK: Replay

let fixturePath = CommandLine.arguments.dropFirst().first ?? "Tests/DJControllers/Fixtures/ddj400-session.midi.txt"
let session = loadFixture(fixturePath)

MainActor.assumeIsolated {
    let surface = RecordingSurface()
    let router = ControllerInputRouter(
        profile: ControllerProfiles.pioneerDDJ400,
        surface: surface,
        access: { ControllerDeckAccess() },
        content: { _ in .ownMusic }
    )
    var unmapped = 0
    for message in session {
        if router.handle(message) == .unmapped { unmapped += 1 }
    }
    expect(session.count == 32, "fixture has 32 messages, got \(session.count)")
    expect(unmapped == 4, "three unmapped messages and a centred jog, got \(unmapped)")
    expect(surface.playing == [.a], "deck A playing")
    expect(surface.cueHeld.isEmpty, "cues released")
    expect(surface.hotCues[.a] == [2] && surface.hotCues[.b] == [0], "hot cues hit")
    expect(surface.jogTicks[.a] == 2, "jog nets +2 ticks, got \(String(describing: surface.jogTicks[.a]))")
    expect(surface.jogTouched.isEmpty, "jog touch released")
    expect(surface.syncs == [.b], "deck B synced")
    expect(surface.looping == [], "loop in/out then toggle closes the loop")
    expect(abs((surface.values[DeckControlAddress(group: a, control: .tempo)] ?? -1) - Double(64 << 7) / 16383) < 1e-9, "tempo centred")
    expect(surface.values[DeckControlAddress(group: a, control: .volume)] == 1, "deck A volume full")
    expect(surface.values[DeckControlAddress(group: a, control: .eqLow)] == 0, "deck A EQ low killed")
    expect(surface.values[DeckControlAddress(group: b, control: .filter)] == 0, "deck B filter closed")
    expect(surface.values[DeckControlAddress(group: .mixer, control: .crossfader)] == 1, "crossfader right")
}

// MARK: Own-music gate

MainActor.assumeIsolated {
    let local = ControllerDeckContent(source: .local(LocalTrackFile(folderID: "f", relativePath: "a.mp3")))
    let streaming = ControllerDeckContent(source: .soundCloud)
    expect(local == .ownMusic && streaming == .streaming && ControllerDeckContent(source: nil) == .empty, "content from track source")

    var contents: [MixEngine.Deck: ControllerDeckContent] = [.a: .streaming, .b: .ownMusic]
    var unlocked = false
    let surface = RecordingSurface()
    let router = ControllerInputRouter(
        profile: ControllerProfiles.pioneerDDJ400,
        surface: surface,
        access: { ControllerDeckAccess(allowsStreaming: unlocked) },
        content: { contents[$0] ?? .empty }
    )

    var blocked = 0
    for message in session {
        if case .blocked = router.handle(message) { blocked += 1 }
    }
    expect(surface.playing.isEmpty, "SoundCloud deck A ignores play")
    expect(surface.hotCues[.a] == nil, "SoundCloud deck A ignores pads")
    expect(surface.jogTicks[.a] == nil, "SoundCloud deck A ignores jog")
    expect(surface.values[DeckControlAddress(group: a, control: .tempo)] == nil, "SoundCloud deck A ignores tempo")
    expect(surface.values[DeckControlAddress(group: a, control: .volume)] == nil, "SoundCloud deck A ignores faders")
    expect(surface.values[DeckControlAddress(group: .mixer, control: .crossfader)] == nil, "crossfader ignored while a SoundCloud track is loaded")
    expect(surface.syncs == [.b] && surface.hotCues[.b] == [0], "own-music deck B still works")
    expect(blocked == 18, "18 messages blocked, got \(blocked)")

    contents[.a] = .ownMusic
    expect(router.handle(note(0x90, 0x0B, 127)) == .performed(.press(DeckControlAddress(group: a, control: .play), isDown: true)), "local file on deck A plays")
    expect(surface.playing == [.a], "deck A now playing")

    contents[.a] = .streaming
    unlocked = true
    expect(router.handle(note(0x90, 0x0B, 127)) == .performed(.press(DeckControlAddress(group: a, control: .play), isDown: true)), "unlocked access drives SoundCloud decks")
    expect(ControllerDeckAccess().allows(.streaming) == false, "default access never allows streaming")
}

if failures.isEmpty {
    print("DJ controller tests: \(checks) checks passed")
    exit(0)
} else {
    print("DJ controller tests: \(failures.count) of \(checks) checks failed")
    for failure in failures { print("  FAIL \(failure)") }
    exit(1)
}
