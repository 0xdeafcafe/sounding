#if os(macOS) || DEBUG
import Foundation

enum DJPlayerMediaSlot: Hashable, Sendable {
    case none
    case cd
    case sd
    case usb
    case collection
    case streaming
    case other(UInt8)

    init(raw: UInt8) {
        switch raw {
        case 0x00: self = .none
        case 0x01: self = .cd
        case 0x02: self = .sd
        case 0x03, 0x07: self = .usb
        case 0x04: self = .collection
        case 0x05, 0x06, 0x08, 0x09, 0x0e: self = .streaming
        default: self = .other(raw)
        }
    }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .cd: return "CD"
        case .sd: return "SD"
        case .usb: return "USB"
        case .collection: return "rekordbox"
        case .streaming: return "Streaming"
        case .other: return "Other"
        }
    }
}

struct DJPlayerTrackKey: Hashable, Sendable {
    var sourcePlayer: Int
    var slot: DJPlayerMediaSlot
    var trackType: UInt8
    var rekordboxId: UInt32

    var isRekordboxTrack: Bool { trackType == 0x01 }
}

struct DJPlayersTrackInfo: Equatable, Sendable {
    var title: String
    var artist: String?
    var soundCloudTrackId: String?
}

struct DJPlayerTrackHint: Equatable, Sendable {
    var lengthSeconds: Int?
    var bpm: Double?
}

protocol DJPlayersTrackLookup: Sendable {
    func track(for key: DJPlayerTrackKey, hint: DJPlayerTrackHint?) async -> DJPlayersTrackInfo?
}

extension DJPlayersTrackLookup {
    func track(for key: DJPlayerTrackKey) async -> DJPlayersTrackInfo? {
        await track(for: key, hint: nil)
    }
}

enum DJPlayerActivity: Equatable, Sendable {
    case empty
    case loading
    case playing
    case looping
    case paused
    case cued
    case searching
    case ended

    init(_ state: DJLinkPlayState?, isPlayingFlag: Bool) {
        switch state {
        case .noTrack: self = .empty
        case .loading: self = .loading
        case .playing, .cuePlay, .cueScratch: self = .playing
        case .looping, .emergencyLoop: self = .looping
        case .paused, .spunDown: self = .paused
        case .cued: self = .cued
        case .searching: self = .searching
        case .ended: self = .ended
        case nil: self = isPlayingFlag ? .playing : .paused
        }
    }

    var isAudible: Bool { self == .playing || self == .looping }

    var displayName: String {
        switch self {
        case .empty: return "No Track"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .looping: return "Looping"
        case .paused: return "Paused"
        case .cued: return "Cued"
        case .searching: return "Searching"
        case .ended: return "Ended"
        }
    }
}

struct DJPlayerStatus: Equatable, Sendable {
    var activity: DJPlayerActivity = .empty
    var trackBPM: Double?
    var pitch: Double = 1
    var isMaster = false
    var isSynced = false
    var isOnAir = false
    var track: DJPlayerTrackKey?
    var beatNumber: Int?
    var beatWithinBar: Int?
    var playheadMillis: Int?
    var trackLengthSeconds: Int?
    var key: String?
    var firmware: String?
    var syncCounter: UInt32 = 0
    var masterHandoff: UInt8 = 0xff
    var updatedAt: TimeInterval = 0

    var effectiveBPM: Double? { trackBPM.map { $0 * pitch } }
    var pitchPercent: Double { (pitch - 1) * 100 }
}

struct DJPlayer: Identifiable, Equatable, Sendable {
    var number: Int
    var name: String
    var ip: DJLinkIPv4
    var mac: DJLinkMAC
    var lastSeen: TimeInterval
    var reportsAsMixer: Bool
    var status: DJPlayerStatus?

    var id: Int { number }

    var isMixer: Bool { reportsAsMixer || name.uppercased().hasPrefix("DJM") || number == 0x21 }
    var isComputer: Bool { name.lowercased().contains("rekordbox") }
    var isPlayer: Bool { !isMixer && !isComputer && (1...6).contains(number) }
    var isCDJ3000: Bool { name.uppercased().hasPrefix("CDJ-3000") }
}

struct DJPlayersTempoReference: Equatable, Sendable {
    var masterNumber: Int
    var bpm: Double
    var lastBeatAt: TimeInterval?
    var beatWithinBar: Int
    var isRunning: Bool

    var beatPeriod: Double { bpm > 0 ? 60 / bpm : 0 }

    func beatPhase(at time: TimeInterval) -> Double? {
        guard beatPeriod > 0, let lastBeatAt else { return nil }
        let elapsed = (time - lastBeatAt) / beatPeriod
        return elapsed - floor(elapsed)
    }

    func playbackRatio(forTrackBPM trackBPM: Double, maxPercent: Double) -> Double? {
        guard bpm > 0, trackBPM > 0 else { return nil }
        let ratio = bpm / trackBPM
        return abs(ratio - 1) <= maxPercent / 100 ? ratio : nil
    }

    func beatPhaseDifference(ofDeck deckBeatPhase: Double, at time: TimeInterval) -> Double? {
        guard isRunning, let referencePhase = beatPhase(at: time) else { return nil }
        var difference = deckBeatPhase - referencePhase
        if difference > 0.5 { difference -= 1 }
        if difference < -0.5 { difference += 1 }
        return difference
    }

    func barPhase(at time: TimeInterval) -> Double? {
        guard beatPeriod > 0, let lastBeatAt else { return nil }
        let beatsSinceDownbeat = Double(max(1, beatWithinBar) - 1) + (time - lastBeatAt) / beatPeriod
        let bars = beatsSinceDownbeat / 4
        return bars - floor(bars)
    }
}

struct DJVirtualDeckSnapshot: Equatable, Sendable {
    var isLoaded: Bool
    var isPlaying: Bool
    var trackBPM: Double?
    var rate: Double
    var positionSeconds: Double
    var anchorTime: TimeInterval
    var gridAnchorSeconds: Double
    var downbeatOffset: Int
    var durationSeconds: Double

    static let empty = DJVirtualDeckSnapshot(
        isLoaded: false,
        isPlaying: false,
        trackBPM: nil,
        rate: 1,
        positionSeconds: 0,
        anchorTime: 0,
        gridAnchorSeconds: 0,
        downbeatOffset: 0,
        durationSeconds: 0
    )

    var trackBeatPeriod: Double? {
        guard let trackBPM, trackBPM > 20, trackBPM < 400 else { return nil }
        return 60 / trackBPM
    }

    var effectiveBPM: Double? { trackBPM.map { $0 * rate } }

    func position(at time: TimeInterval) -> Double {
        guard isPlaying else { return positionSeconds }
        return positionSeconds + (time - anchorTime) * rate
    }

    func beatIndex(at time: TimeInterval) -> Int? {
        guard let period = trackBeatPeriod else { return nil }
        let beats = (position(at: time) - gridAnchorSeconds) / period
        guard beats.isFinite else { return nil }
        return Int(floor(beats + 1e-6))
    }

    func trackSeconds(ofBeat index: Int) -> Double? {
        trackBeatPeriod.map { gridAnchorSeconds + Double(index) * $0 }
    }

    func time(ofBeat index: Int) -> TimeInterval? {
        guard isPlaying, rate > 0, let seconds = trackSeconds(ofBeat: index) else { return nil }
        return anchorTime + (seconds - positionSeconds) / rate
    }

    func beatWithinBar(ofBeat index: Int) -> Int {
        let offset = index - downbeatOffset
        return ((offset % 4) + 4) % 4 + 1
    }

    func isMeaningfullyDifferent(from other: DJVirtualDeckSnapshot, at time: TimeInterval) -> Bool {
        if isLoaded != other.isLoaded || isPlaying != other.isPlaying { return true }
        if trackBPM != other.trackBPM || abs(rate - other.rate) > 0.0001 { return true }
        if gridAnchorSeconds != other.gridAnchorSeconds || downbeatOffset != other.downbeatOffset { return true }
        return abs(position(at: time) - other.position(at: time)) > 0.015
    }
}

enum DJLinkIdentity: Equatable, Sendable {
    case observer
    case virtualDeck(preferred: Int?)
}

enum DJLinkEnginePhase: Equatable, Sendable {
    case idle
    case listening
    case claiming(number: Int)
    case active(number: Int)
    case numberTaken(number: Int)
}

struct DJPlayersSnapshot: Equatable, Sendable {
    var phase: DJLinkEnginePhase = .idle
    var players: [DJPlayer] = []
    var tempo: DJPlayersTempoReference?
    var isVirtualDeckMaster = false
    var isVirtualDeckSynced = false
    var usesCDJ3000Packets = false

    var ownNumber: Int? {
        switch phase {
        case .active(let number), .claiming(let number): return number
        default: return nil
        }
    }

    var visiblePlayers: [DJPlayer] {
        players.filter { $0.number != ownNumber }.sorted { $0.number < $1.number }
    }
}
#endif
