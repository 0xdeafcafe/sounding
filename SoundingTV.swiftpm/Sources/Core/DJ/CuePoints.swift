import Foundation

enum CueTime {
    static func millis(fromSeconds seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let scaled = (seconds * 1000).rounded()
        guard scaled >= Double(Int64.min), scaled < Double(Int64.max) else {
            return scaled < 0 ? Int64.min : Int64.max
        }
        return Int64(scaled)
    }

    static func seconds(fromMillis millis: Int64) -> TimeInterval {
        TimeInterval(millis) / 1000
    }

    static func nowMillis() -> Int64 { millis(fromSeconds: Date().timeIntervalSince1970) }
}

struct CueColor: Codable, Hashable, Sendable {
    let rgb: UInt32

    init(rgb: UInt32) { self.rgb = rgb & 0x00FF_FFFF }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        rgb = (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
    }

    var red: UInt8 { UInt8((rgb >> 16) & 0xFF) }
    var green: UInt8 { UInt8((rgb >> 8) & 0xFF) }
    var blue: UInt8 { UInt8(rgb & 0xFF) }

    static let hotCuePalette: [CueColor] = [
        CueColor(red: 40, green: 226, blue: 20),    // A — rekordbox's default green
        CueColor(red: 224, green: 100, blue: 27),   // B — orange-red
        CueColor(red: 195, green: 175, blue: 4),    // C — yellow
        CueColor(red: 48, green: 90, blue: 255),    // D — rekordbox blue
        CueColor(red: 0, green: 200, blue: 200),    // E — cyan
        CueColor(red: 222, green: 68, blue: 207),   // F — pink
        CueColor(red: 136, green: 0, blue: 204),    // G — purple
        CueColor(red: 255, green: 255, blue: 255),  // H — white
    ]

    static let mixIn = CueColor(rgb: 0x2E_D5_7B)
    static let mixOut = CueColor(rgb: 0xFF_5A_3C)
    static let memory = CueColor(rgb: 0x9A_A4_B2)
    static let loop = CueColor(rgb: 0x00_B4_D8)

    static func `default`(for kind: CueKind, hotCueIndex: Int? = nil) -> CueColor {
        switch kind {
        case .hotCue:
            let index = max(0, hotCueIndex ?? 0) % hotCuePalette.count
            return hotCuePalette[index]
        case .mixIn:  return .mixIn
        case .mixOut: return .mixOut
        case .memory: return .memory
        case .loop:   return .loop
        }
    }
}

enum CueKind: String, Codable, Sendable, CaseIterable {
    case mixIn
    case hotCue
    case loop
    case memory
    case mixOut

    var sortRank: Int {
        switch self {
        case .mixIn:  return 0
        case .hotCue: return 1
        case .loop:   return 2
        case .memory: return 3
        case .mixOut: return 4
        }
    }

    var isSingleton: Bool {
        switch self {
        case .mixIn, .mixOut: return true
        case .hotCue, .loop, .memory: return false
        }
    }

    var displayName: String {
        switch self {
        case .hotCue: return "hot cue"
        case .memory: return "memory cue"
        case .mixIn:  return "mix-in point"
        case .mixOut: return "mix-out point"
        case .loop:   return "loop"
        }
    }
}

enum CueOrigin: String, Codable, Sendable {
    case user
    case suggested
}

struct CueSuggesterIdentity: Codable, Hashable, Sendable {
    let name: String
    let version: Int

    init(name: String, version: Int) {
        self.name = name
        self.version = version
    }
}

struct CuePoint: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let trackId: String
    let kind: CueKind
    var positionMillis: Int64
    var endMillis: Int64?
    var hotCueIndex: Int?
    var label: String
    var color: CueColor

    let createdAtMillis: Int64
    var updatedAtMillis: Int64
    var isDeleted: Bool

    var promotedFrom: CueSuggesterIdentity?

    var writerId: String

    var positionSeconds: TimeInterval { CueTime.seconds(fromMillis: positionMillis) }
    var endSeconds: TimeInterval? { endMillis.map(CueTime.seconds(fromMillis:)) }
    var origin: CueOrigin { .user }

    static func slotId(trackId: String, kind: CueKind, hotCueIndex: Int?) -> String? {
        switch kind {
        case .mixIn:  return "\(trackId)#mixin"
        case .mixOut: return "\(trackId)#mixout"
        case .hotCue:
            guard let hotCueIndex else { return nil }
            return "\(trackId)#hot#\(hotCueIndex)"
        case .memory, .loop:
            return nil
        }
    }

    static let hotCueSlotCount = 8

    init(
        id: String? = nil,
        trackId: String,
        kind: CueKind,
        positionMillis: Int64,
        endMillis: Int64? = nil,
        hotCueIndex: Int? = nil,
        label: String = "",
        color: CueColor? = nil,
        createdAtMillis: Int64 = CueTime.nowMillis(),
        updatedAtMillis: Int64? = nil,
        isDeleted: Bool = false,
        promotedFrom: CueSuggesterIdentity? = nil,
        writerId: String = ""
    ) {
        let normalisedIndex: Int? = kind == .hotCue
            ? min(max(0, hotCueIndex ?? 0), CuePoint.hotCueSlotCount - 1)
            : nil
        let position = max(0, positionMillis)
        let normalisedEnd: Int64? = kind == .loop
            ? max(position + 1, endMillis ?? (position + 1))
            : nil

        self.trackId = trackId
        self.kind = kind
        self.positionMillis = position
        self.endMillis = normalisedEnd
        self.hotCueIndex = normalisedIndex
        self.label = label
        self.color = color ?? CueColor.default(for: kind, hotCueIndex: normalisedIndex)
        self.createdAtMillis = createdAtMillis
        self.updatedAtMillis = updatedAtMillis ?? createdAtMillis
        self.isDeleted = isDeleted
        self.promotedFrom = promotedFrom
        self.writerId = writerId
        self.id = id
            ?? CuePoint.slotId(trackId: trackId, kind: kind, hotCueIndex: normalisedIndex)
            ?? "\(trackId)#\(kind.rawValue)#\(UUID().uuidString)"
    }

}

struct CueSuggestion: Hashable, Sendable, Identifiable {
    let trackId: String
    let kind: CueKind
    let positionMillis: Int64
    let endMillis: Int64?
    let suggester: CueSuggesterIdentity
    let confidence: Double
    let reasoning: String
    let snappedToGrid: Bool
    let label: String
    let color: CueColor

    var positionSeconds: TimeInterval { CueTime.seconds(fromMillis: positionMillis) }
    var origin: CueOrigin { .suggested }

    var id: String {
        "\(trackId)#\(suggester.name)#\(suggester.version)#\(kind.rawValue)#\(positionMillis)"
    }

    func promoted(
        asKind: CueKind? = nil,
        hotCueIndex: Int? = nil,
        label overrideLabel: String? = nil,
        writerId: String,
        now: Int64 = CueTime.nowMillis()
    ) -> CuePoint {
        let targetKind = asKind ?? kind
        return CuePoint(
            trackId: trackId,
            kind: targetKind,
            positionMillis: positionMillis,
            endMillis: targetKind == .loop ? endMillis : nil,
            hotCueIndex: targetKind == .hotCue ? (hotCueIndex ?? 0) : nil,
            label: overrideLabel ?? label,
            color: targetKind == kind ? color : nil,
            createdAtMillis: now,
            updatedAtMillis: now,
            promotedFrom: suggester,
            writerId: writerId
        )
    }
}

struct CueDismissal: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let trackId: String
    let suggesterName: String
    let suggesterVersion: Int
    let kind: CueKind
    let positionMillis: Int64
    let dismissedAtMillis: Int64
    let writerId: String

    init(
        suggestion: CueSuggestion,
        writerId: String,
        now: Int64 = CueTime.nowMillis()
    ) {
        id = suggestion.id
        trackId = suggestion.trackId
        suggesterName = suggestion.suggester.name
        suggesterVersion = suggestion.suggester.version
        kind = suggestion.kind
        positionMillis = suggestion.positionMillis
        dismissedAtMillis = now
        self.writerId = writerId
    }

    init(
        id: String,
        trackId: String,
        suggesterName: String,
        suggesterVersion: Int,
        kind: CueKind,
        positionMillis: Int64,
        dismissedAtMillis: Int64,
        writerId: String
    ) {
        self.id = id
        self.trackId = trackId
        self.suggesterName = suggesterName
        self.suggesterVersion = suggesterVersion
        self.kind = kind
        self.positionMillis = positionMillis
        self.dismissedAtMillis = dismissedAtMillis
        self.writerId = writerId
    }
}

enum ResolvedCue: Hashable, Sendable, Identifiable {
    case user(CuePoint)
    case suggested(CueSuggestion)

    var id: String {
        switch self {
        case .user(let cue): return cue.id
        case .suggested(let suggestion): return suggestion.id
        }
    }

    var origin: CueOrigin {
        switch self {
        case .user: return .user
        case .suggested: return .suggested
        }
    }

    var isSuggestion: Bool { origin == .suggested }

    var kind: CueKind {
        switch self {
        case .user(let cue): return cue.kind
        case .suggested(let suggestion): return suggestion.kind
        }
    }

    var trackId: String {
        switch self {
        case .user(let cue): return cue.trackId
        case .suggested(let suggestion): return suggestion.trackId
        }
    }

    var positionMillis: Int64 {
        switch self {
        case .user(let cue): return cue.positionMillis
        case .suggested(let suggestion): return suggestion.positionMillis
        }
    }

    var positionSeconds: TimeInterval { CueTime.seconds(fromMillis: positionMillis) }

    var endMillis: Int64? {
        switch self {
        case .user(let cue): return cue.endMillis
        case .suggested(let suggestion): return suggestion.endMillis
        }
    }

    var label: String {
        switch self {
        case .user(let cue): return cue.label
        case .suggested(let suggestion): return suggestion.label
        }
    }

    var color: CueColor {
        switch self {
        case .user(let cue): return cue.color
        case .suggested(let suggestion): return suggestion.color
        }
    }

    var confidence: Double? {
        switch self {
        case .user: return nil
        case .suggested(let suggestion): return suggestion.confidence
        }
    }

    var hotCueIndex: Int? {
        switch self {
        case .user(let cue): return cue.hotCueIndex
        case .suggested: return nil
        }
    }

    var reasoning: String {
        switch self {
        case .user(let cue):
            guard let from = cue.promotedFrom else { return "" }
            return "Kept from a \(from.name) v\(from.version) suggestion."
        case .suggested(let suggestion):
            return suggestion.reasoning
        }
    }

    var userCue: CuePoint? {
        if case .user(let cue) = self { return cue }
        return nil
    }

    var suggestion: CueSuggestion? {
        if case .suggested(let suggestion) = self { return suggestion }
        return nil
    }
}

struct CueSheet: Sendable, Equatable {
    let trackId: String
    let entries: [ResolvedCue]

    init(trackId: String, entries: [ResolvedCue]) {
        self.trackId = trackId
        self.entries = entries
    }

    static func empty(trackId: String) -> CueSheet { CueSheet(trackId: trackId, entries: []) }

    var userCues: [CuePoint] { entries.compactMap(\.userCue) }
    var suggestions: [CueSuggestion] { entries.compactMap(\.suggestion) }

    var hotCues: [ResolvedCue] { entries.filter { $0.kind == .hotCue } }
    func hotCue(at index: Int) -> ResolvedCue? { entries.first { $0.hotCueIndex == index } }

    var mixIn: ResolvedCue? { entries.first { $0.kind == .mixIn } }
    var mixOut: ResolvedCue? { entries.first { $0.kind == .mixOut } }
    var loops: [ResolvedCue] { entries.filter { $0.kind == .loop } }
    var memoryCues: [ResolvedCue] { entries.filter { $0.kind == .memory } }

    func first(kind: CueKind, origin: CueOrigin) -> ResolvedCue? {
        entries.first { $0.kind == kind && $0.origin == origin }
    }
}

enum CueResolution {

    static let collisionWindowMillis: Int64 = 1_000

    static func resolve(
        trackId: String,
        userCues: [CuePoint],
        suggestions: [CueSuggestion],
        dismissedIds: Set<String>
    ) -> CueSheet {
        let live = userCues.filter { !$0.isDeleted && $0.trackId == trackId }

        let occupiedSingletons = Set(live.filter { $0.kind.isSingleton }.map(\.kind))
        let byKind = Dictionary(grouping: live, by: \.kind)

        let surviving = suggestions.filter { suggestion in
            guard suggestion.trackId == trackId else { return false }
            guard !dismissedIds.contains(suggestion.id) else { return false }
            if suggestion.kind.isSingleton, occupiedSingletons.contains(suggestion.kind) { return false }
            guard let sameKind = byKind[suggestion.kind] else { return true }
            return !sameKind.contains { cue in
                abs(cue.positionMillis - suggestion.positionMillis) <= collisionWindowMillis
            }
        }

        let entries = (live.map(ResolvedCue.user) + surviving.map(ResolvedCue.suggested))
            .sorted(by: isOrderedBefore)

        return CueSheet(trackId: trackId, entries: entries)
    }

    static func isOrderedBefore(_ lhs: ResolvedCue, _ rhs: ResolvedCue) -> Bool {
        if lhs.positionMillis != rhs.positionMillis { return lhs.positionMillis < rhs.positionMillis }
        if lhs.origin != rhs.origin { return lhs.origin == .user }
        if lhs.kind != rhs.kind { return lhs.kind.sortRank < rhs.kind.sortRank }
        if let l = lhs.hotCueIndex, let r = rhs.hotCueIndex, l != r { return l < r }
        return lhs.id < rhs.id
    }
}

enum CueSource: String, Sendable, Equatable {
    case userCue
    case suggestion
    case planner
}

enum CuePolicy {

    static let minimumTailSeconds: TimeInterval = 0.25

    static func clamp(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        guard duration.isFinite, duration > minimumTailSeconds else { return max(0, seconds) }
        return min(max(0, seconds), duration - minimumTailSeconds)
    }

    struct Resolution: Sendable, Equatable {
        let seconds: TimeInterval
        let source: CueSource
    }

    static func entry(
        sheet: CueSheet,
        plannedEntrySeconds: TimeInterval,
        duration: TimeInterval,
        allowSuggestions: Bool = false
    ) -> Resolution {
        if let user = sheet.first(kind: .mixIn, origin: .user) {
            return Resolution(seconds: clamp(user.positionSeconds, duration: duration), source: .userCue)
        }
        if plannedEntrySeconds.isFinite, plannedEntrySeconds > 0 {
            return Resolution(seconds: clamp(plannedEntrySeconds, duration: duration), source: .planner)
        }
        if allowSuggestions, let suggested = sheet.first(kind: .mixIn, origin: .suggested) {
            return Resolution(seconds: clamp(suggested.positionSeconds, duration: duration), source: .suggestion)
        }
        return Resolution(seconds: 0, source: .planner)
    }

    static func exit(
        sheet: CueSheet,
        plannedExitSeconds: TimeInterval,
        duration: TimeInterval
    ) -> Resolution {
        if let user = sheet.first(kind: .mixOut, origin: .user) {
            return Resolution(seconds: clamp(user.positionSeconds, duration: duration), source: .userCue)
        }
        return Resolution(seconds: clamp(plannedExitSeconds, duration: duration), source: .planner)
    }

}
