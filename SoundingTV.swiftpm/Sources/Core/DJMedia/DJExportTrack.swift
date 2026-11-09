import Foundation

protocol DJExportTrack: Sendable {
    var exportID: String { get }
    var audioFileURL: URL { get }
    var metadata: DJExportMetadata { get }
    var beatGrid: DJExportBeatGrid? { get }
    var cues: [DJExportCue] { get }
    var phrases: DJExportPhrases? { get }
    var waveform: DJExportWaveform? { get }
    var key: DJExportKey? { get }
}

struct DJExportMetadata: Equatable, Sendable {
    var title: String
    var artist: String = ""
    var album: String = ""
    var genre: String = ""
    var label: String = ""
    var remixer: String = ""
    var composer: String = ""
    var originalArtist: String = ""
    var comment: String = ""
    var mixName: String = ""
    var isrc: String = ""
    var year: Int = 0
    var trackNumber: Int = 0
    var discNumber: Int = 0
    var rating: Int = 0
    var colorRGB: UInt32?
    var durationSeconds: Double
    var sampleRate: Int = 44100
    var bitDepth: Int = 16
    var bitrateKbps: Int = 0
    var fileSize: Int64 = 0
    var dateAdded: Date?
    var releaseDate: String = ""
    var artworkJPEG: Data?
}

struct DJExportBeatGrid: Equatable, Sendable {
    var bpm: Double
    var firstBeatSeconds: Double
    var firstDownbeatOffset: Int = 0
    var beatsPerBar: Int = 4
    var beats: [Double]?
    var downbeats: [Double]?

    var beatPeriod: Double { bpm > 0 ? 60 / bpm : 0 }
}

struct DJExportCue: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case hotCue(slot: Int)
        case memory
        case mixIn
        case mixOut
    }

    var role: Role
    var startSeconds: Double
    var endSeconds: Double?
    var label: String = ""
    var colorRGB: UInt32?

    var isLoop: Bool { (endSeconds ?? startSeconds) > startSeconds }
}

struct DJExportPhrase: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case intro
        case up
        case down
        case chorus
        case verse(Int)
        case bridge
        case outro
    }

    var startSeconds: Double
    var kind: Kind
}

struct DJExportPhrases: Equatable, Sendable {
    var mood: ANLZMood?
    var phrases: [DJExportPhrase]
    var endSeconds: Double?
}

struct DJExportWaveform: Equatable, Sendable {
    var amplitude: [Float]
    var low: [Float]?
    var mid: [Float]?
    var high: [Float]?

    var hasBands: Bool {
        guard let low, let mid, let high else { return false }
        return low.count == amplitude.count && mid.count == amplitude.count && high.count == amplitude.count
    }
}

struct DJExportKey: Equatable, Sendable {
    enum Notation: Sendable {
        case classic
        case camelot
    }

    var pitchClass: Int
    var isMinor: Bool

    static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]
    static let camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]

    func name(_ notation: Notation) -> String {
        let pc = ((pitchClass % 12) + 12) % 12
        switch notation {
        case .classic:
            return isMinor ? Self.minorNames[pc] : Self.majorNames[pc]
        case .camelot:
            let wheel = Self.camelotMajor[isMinor ? (pc + 3) % 12 : pc]
            return "\(wheel)\(isMinor ? "A" : "B")"
        }
    }

    static func parse(_ raw: String) -> DJExportKey? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let i = majorNames.firstIndex(of: s) { return DJExportKey(pitchClass: i, isMinor: false) }
        if let i = minorNames.firstIndex(of: s) { return DJExportKey(pitchClass: i, isMinor: true) }
        let sharps = ["C#": 1, "D#": 3, "Gb": 6, "G#": 8, "A#": 10, "Db": 1, "Eb": 3, "Ab": 8, "Bb": 10]
        let body = s.hasSuffix("m") ? String(s.dropLast()) : s
        if let pc = sharps[body] { return DJExportKey(pitchClass: pc, isMinor: s.hasSuffix("m")) }
        if let last = s.last, last == "A" || last == "B", let n = Int(s.dropLast()), (1 ... 12).contains(n),
           let majorPC = camelotMajor.firstIndex(of: n) {
            let minor = last == "A"
            return DJExportKey(pitchClass: minor ? (majorPC + 9) % 12 : majorPC, isMinor: minor)
        }
        return nil
    }
}

struct DJExportPlaylist: Equatable, Sendable {
    var name: String
    var trackIDs: [String] = []
    var children: [DJExportPlaylist] = []
    var isFolder: Bool = false

    static func folder(_ name: String, _ children: [DJExportPlaylist]) -> DJExportPlaylist {
        DJExportPlaylist(name: name, trackIDs: [], children: children, isFolder: true)
    }
}

struct DJExportTrackRecord: DJExportTrack, Equatable {
    var exportID: String
    var audioFileURL: URL
    var metadata: DJExportMetadata
    var beatGrid: DJExportBeatGrid?
    var cues: [DJExportCue] = []
    var phrases: DJExportPhrases?
    var waveform: DJExportWaveform?
    var key: DJExportKey?

    init(
        exportID: String,
        audioFileURL: URL,
        metadata: DJExportMetadata,
        beatGrid: DJExportBeatGrid? = nil,
        cues: [DJExportCue] = [],
        phrases: DJExportPhrases? = nil,
        waveform: DJExportWaveform? = nil,
        key: DJExportKey? = nil
    ) {
        self.exportID = exportID
        self.audioFileURL = audioFileURL
        self.metadata = metadata
        self.beatGrid = beatGrid
        self.cues = cues
        self.phrases = phrases
        self.waveform = waveform
        self.key = key
    }

    init(_ track: any DJExportTrack) {
        self.init(
            exportID: track.exportID,
            audioFileURL: track.audioFileURL,
            metadata: track.metadata,
            beatGrid: track.beatGrid,
            cues: track.cues,
            phrases: track.phrases,
            waveform: track.waveform,
            key: track.key
        )
    }
}
