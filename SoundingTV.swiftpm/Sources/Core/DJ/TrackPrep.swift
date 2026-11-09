import Foundation

enum PrepSource: String, Codable, Sendable, CaseIterable {
    case sounding
    case rekordbox
    case user

    var rank: Int {
        switch self {
        case .sounding:  return 0
        case .rekordbox: return 1
        case .user:      return 2
        }
    }
}

struct PrepField<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    var value: Value
    var source: PrepSource
    var updatedAtMillis: Int64
    var writerId: String

    init(_ value: Value, source: PrepSource, updatedAtMillis: Int64 = CueTime.nowMillis(), writerId: String = "") {
        self.value = value
        self.source = source
        self.updatedAtMillis = updatedAtMillis
        self.writerId = writerId
    }
}

struct PrepTempoSegment: Codable, Hashable, Sendable {
    var startMillis: Int64
    var bpm: Double
    var beatsPerBar: Int
    var beatInBar: Int

    init(startMillis: Int64, bpm: Double, beatsPerBar: Int = 4, beatInBar: Int = 1) {
        self.startMillis = startMillis
        self.bpm = bpm
        self.beatsPerBar = max(1, beatsPerBar)
        self.beatInBar = ((beatInBar - 1) % max(1, beatsPerBar) + max(1, beatsPerBar)) % max(1, beatsPerBar) + 1
    }

    var beatPeriodMillis: Double { bpm > 0 ? 60_000 / bpm : 0 }
}

struct PrepGrid: Codable, Hashable, Sendable {
    var segments: [PrepTempoSegment]
    var downbeats: [Int64]?
    var locked: Bool

    init(segments: [PrepTempoSegment], downbeats: [Int64]? = nil, locked: Bool = false) {
        self.segments = segments.sorted { $0.startMillis < $1.startMillis }
        self.downbeats = downbeats
        self.locked = locked
    }

    var bpm: Double { segments.first?.bpm ?? 0 }
    var isVariable: Bool { Set(segments.map(\.bpm)).count > 1 }

    func segmentIndex(containing millis: Int64) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.startMillis <= millis } ?? 0
    }

    func beats(throughMillis endMillis: Int64) -> [(millis: Int64, beatInBar: Int)] {
        guard !segments.isEmpty else { return [] }
        var out: [(Int64, Int)] = []
        for (index, segment) in segments.enumerated() {
            let period = segment.beatPeriodMillis
            guard period > 0 else { continue }
            let segmentEnd = index + 1 < segments.count ? segments[index + 1].startMillis : endMillis
            var beat = 0
            var position = Double(segment.startMillis)
            if index == 0 {
                while position - period >= 0 {
                    position -= period
                    beat -= 1
                }
            }
            while Int64(position.rounded()) < segmentEnd, out.count < 200_000 {
                let inBar = ((segment.beatInBar - 1 + beat) % segment.beatsPerBar + segment.beatsPerBar) % segment.beatsPerBar + 1
                out.append((Int64(position.rounded()), inBar))
                beat += 1
                position += period
            }
        }
        return out
    }

    func downbeatMillis(throughMillis endMillis: Int64) -> [Int64] {
        if let downbeats, !downbeats.isEmpty { return downbeats.filter { $0 <= endMillis } }
        return beats(throughMillis: endMillis).filter { $0.beatInBar == 1 }.map(\.millis)
    }

    func beatGrid(durationSeconds: TimeInterval, confidence: Double) -> BeatGrid? {
        guard let first = segments.first, first.bpm > 20, first.bpm < 300 else { return nil }
        let beatPeriod = 60.0 / first.bpm
        let firstSeconds = CueTime.seconds(fromMillis: first.startMillis)
        let anchor = firstSeconds - (firstSeconds / beatPeriod).rounded(.down) * beatPeriod
        let beatsBeforeStart = Int(((firstSeconds - anchor) / beatPeriod).rounded())
        let anchorBeatInBar = ((first.beatInBar - 1 - beatsBeforeStart) % 4 + 4) % 4
        let downbeatOffset = (4 - anchorBeatInBar) % 4
        guard isVariable || downbeats != nil else {
            return BeatGrid(anchor: anchor, beatPeriod: beatPeriod, downbeatOffset: downbeatOffset, confidence: confidence)
        }
        let endMillis = CueTime.millis(fromSeconds: max(durationSeconds, firstSeconds + 1))
        let beatSeconds = beats(throughMillis: endMillis).map { CueTime.seconds(fromMillis: $0.millis) }
        let barSeconds = downbeatMillis(throughMillis: endMillis).map(CueTime.seconds(fromMillis:))
        return BeatGrid(
            anchor: beatSeconds.first ?? anchor,
            beatPeriod: beatPeriod,
            downbeatOffset: downbeatOffset,
            confidence: confidence,
            beats: beatSeconds.isEmpty ? nil : beatSeconds,
            downbeats: barSeconds.isEmpty ? nil : barSeconds
        )
    }

    static func from(_ grid: BeatGrid) -> PrepGrid? {
        guard grid.beatPeriod > 0, grid.bpm > 20, grid.bpm < 300 else { return nil }
        let start = grid.downbeats?.first ?? grid.firstDownbeat
        return PrepGrid(segments: [
            PrepTempoSegment(startMillis: CueTime.millis(fromSeconds: max(0, start)), bpm: grid.bpm, beatInBar: 1)
        ])
    }
}

struct PrepKey: Codable, Hashable, Sendable {
    var camelot: String
    var original: String

    init(camelot: String, original: String) {
        self.camelot = camelot
        self.original = original
    }

    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let key = CamelotKey.parse(trimmed) else { return nil }
        self.init(camelot: key.label, original: trimmed)
    }
}

struct PrepPhrase: Codable, Hashable, Sendable {
    var startMillis: Int64
    var kind: SectionKind
    var mood: String?
    var rekordbox: RekordboxPhraseCode? = nil
}

struct TrackPrep: Codable, Hashable, Sendable {
    let trackId: String
    var grid: PrepField<PrepGrid>?
    var key: PrepField<PrepKey>?
    var energy: PrepField<Int>?
    var phrases: PrepField<[PrepPhrase]>?
    var colour: PrepField<UInt32>?
    var comment: PrepField<String>?

    init(trackId: String) {
        self.trackId = trackId
    }

    var updatedAtMillis: Int64 {
        [grid?.updatedAtMillis, key?.updatedAtMillis, energy?.updatedAtMillis,
         phrases?.updatedAtMillis, colour?.updatedAtMillis, comment?.updatedAtMillis]
            .compactMap { $0 }.max() ?? 0
    }

    var latestWriterId: String {
        let fields: [(Int64, String)] = [
            grid.map { ($0.updatedAtMillis, $0.writerId) },
            key.map { ($0.updatedAtMillis, $0.writerId) },
            energy.map { ($0.updatedAtMillis, $0.writerId) },
            phrases.map { ($0.updatedAtMillis, $0.writerId) },
            colour.map { ($0.updatedAtMillis, $0.writerId) },
            comment.map { ($0.updatedAtMillis, $0.writerId) },
        ].compactMap { $0 }
        return fields.max { $0.0 < $1.0 }?.1 ?? ""
    }

    var isEmpty: Bool {
        grid == nil && key == nil && energy == nil && phrases == nil && colour == nil && comment == nil
    }

    var hasLockedGrid: Bool { grid?.value.locked == true }
    var hasTrustedGrid: Bool { hasLockedGrid || grid?.source == .user }
}

enum PrepItem: Hashable, Sendable {
    case grid
    case key
    case energy
    case phrases
    case colour
    case comment
}

enum TrackPrepPolicy {

    static func isProtected<V>(_ field: PrepField<V>, item: PrepItem) -> Bool {
        if field.source == .user { return true }
        if item == .grid, let grid = field.value as? PrepGrid, grid.locked { return true }
        return false
    }

    static func incomingWins<V>(local: PrepField<V>?, incoming: PrepField<V>?, item: PrepItem) -> Bool {
        guard let incoming else { return false }
        guard let local else { return true }
        if local == incoming { return false }
        if isProtected(local, item: item), incoming.source != .user { return false }
        if incoming.source.rank != local.source.rank { return incoming.source.rank > local.source.rank }
        if incoming.updatedAtMillis != local.updatedAtMillis { return incoming.updatedAtMillis > local.updatedAtMillis }
        return incoming.writerId > local.writerId
    }

    static func merge(local: TrackPrep?, incoming: TrackPrep) -> TrackPrep {
        var merged = local ?? TrackPrep(trackId: incoming.trackId)
        if incomingWins(local: merged.grid, incoming: incoming.grid, item: .grid) { merged.grid = incoming.grid }
        if incomingWins(local: merged.key, incoming: incoming.key, item: .key) { merged.key = incoming.key }
        if incomingWins(local: merged.energy, incoming: incoming.energy, item: .energy) { merged.energy = incoming.energy }
        if incomingWins(local: merged.phrases, incoming: incoming.phrases, item: .phrases) { merged.phrases = incoming.phrases }
        if incomingWins(local: merged.colour, incoming: incoming.colour, item: .colour) { merged.colour = incoming.colour }
        if incomingWins(local: merged.comment, incoming: incoming.comment, item: .comment) { merged.comment = incoming.comment }
        return merged
    }

    static func blockedItems(local: TrackPrep?, incoming: TrackPrep) -> [PrepItem] {
        guard let local else { return [] }
        var out: [PrepItem] = []
        func check<V>(_ l: PrepField<V>?, _ r: PrepField<V>?, _ item: PrepItem) {
            guard let l, let r, l.value != r.value, isProtected(l, item: item), r.source != .user else { return }
            out.append(item)
        }
        if let l = local.grid, let r = incoming.grid,
           l.value.withoutLock != r.value.withoutLock, isProtected(l, item: .grid), r.source != .user {
            out.append(.grid)
        }
        check(local.key, incoming.key, .key)
        check(local.energy, incoming.energy, .energy)
        check(local.phrases, incoming.phrases, .phrases)
        check(local.colour, incoming.colour, .colour)
        check(local.comment, incoming.comment, .comment)
        return out
    }
}

extension PrepGrid {
    var withoutLock: PrepGrid {
        var copy = self
        copy.locked = false
        return copy
    }
}

enum PrepGridEditor {

    static let nudgeStepMillis: Int64 = 10

    static func setDownbeat(_ grid: PrepGrid, atMillis millis: Int64) -> PrepGrid {
        guard let index = grid.segmentIndex(containing: millis) else { return grid }
        var segments = grid.segments
        let segment = segments[index]
        let period = segment.beatPeriodMillis
        guard period > 0 else { return grid }
        let beatsFromStart = (Double(millis - segment.startMillis) / period).rounded()
        let alignedStart = Double(millis) - beatsFromStart * period
        let k = Int(beatsFromStart)
        let inBar = ((-k) % segment.beatsPerBar + segment.beatsPerBar) % segment.beatsPerBar + 1
        segments[index] = PrepTempoSegment(
            startMillis: Int64(alignedStart.rounded()),
            bpm: segment.bpm,
            beatsPerBar: segment.beatsPerBar,
            beatInBar: inBar
        )
        return PrepGrid(segments: segments, downbeats: nil, locked: grid.locked)
    }

    static func nudge(_ grid: PrepGrid, byMillis delta: Int64) -> PrepGrid {
        PrepGrid(
            segments: grid.segments.map {
                PrepTempoSegment(startMillis: $0.startMillis + delta, bpm: $0.bpm, beatsPerBar: $0.beatsPerBar, beatInBar: $0.beatInBar)
            },
            downbeats: grid.downbeats?.map { $0 + delta },
            locked: grid.locked
        )
    }

    static func double(_ grid: PrepGrid) -> PrepGrid {
        scaled(grid, factor: 2) { inBar, perBar in ((inBar - 1) * 2) % perBar + 1 }
    }

    static func halve(_ grid: PrepGrid) -> PrepGrid {
        scaled(grid, factor: 0.5) { inBar, perBar in ((inBar - 1) / 2) % perBar + 1 }
    }

    static func setBPM(_ grid: PrepGrid, bpm: Double) -> PrepGrid {
        guard bpm.isFinite, bpm > 20, bpm < 300, let first = grid.segments.first else { return grid }
        return PrepGrid(
            segments: [PrepTempoSegment(startMillis: first.startMillis, bpm: bpm, beatsPerBar: first.beatsPerBar, beatInBar: first.beatInBar)],
            downbeats: nil,
            locked: grid.locked
        )
    }

    static func setLocked(_ grid: PrepGrid, _ locked: Bool) -> PrepGrid {
        var copy = grid
        copy.locked = locked
        return copy
    }

    private static func scaled(_ grid: PrepGrid, factor: Double, beatInBar: (Int, Int) -> Int) -> PrepGrid {
        let segments = grid.segments.compactMap { segment -> PrepTempoSegment? in
            let bpm = segment.bpm * factor
            guard bpm > 20, bpm < 300 else { return nil }
            return PrepTempoSegment(
                startMillis: segment.startMillis,
                bpm: bpm,
                beatsPerBar: segment.beatsPerBar,
                beatInBar: beatInBar(segment.beatInBar, segment.beatsPerBar)
            )
        }
        guard segments.count == grid.segments.count else { return grid }
        return PrepGrid(segments: segments, downbeats: nil, locked: grid.locked)
    }
}

struct RekordboxPhraseCode: Codable, Hashable, Sendable {
    var mood: Int
    var kind: Int

    var label: String {
        switch mood {
        case 1:
            switch kind {
            case 1: return "Intro"
            case 2: return "Up"
            case 3: return "Down"
            case 5: return "Chorus"
            case 6: return "Outro"
            default: return "Phrase"
            }
        case 2:
            switch kind {
            case 1: return "Intro"
            case 2 ... 7: return "Verse \(kind - 1)"
            case 8: return "Bridge"
            case 9: return "Chorus"
            case 10: return "Outro"
            default: return "Phrase"
            }
        case 3:
            switch kind {
            case 1: return "Intro"
            case 2 ... 4: return "Verse 1"
            case 5 ... 7: return "Verse 2"
            case 8: return "Bridge"
            case 9: return "Chorus"
            case 10: return "Outro"
            default: return "Phrase"
            }
        default:
            return "Phrase"
        }
    }

    var sectionKind: SectionKind {
        switch label {
        case "Intro": return .intro
        case "Up": return .buildup
        case "Down", "Bridge": return .breakdown
        case "Chorus": return .drop
        case "Outro": return .outro
        default: return label.hasPrefix("Verse") ? .bridge : .unknown
        }
    }
}
