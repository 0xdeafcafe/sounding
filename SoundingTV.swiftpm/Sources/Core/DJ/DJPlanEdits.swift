import Foundation

enum DJPlanLane: String, Codable, CaseIterable, Sendable, Identifiable {
    case loop
    case fade
    case bass
    case filter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: return "Loop"
        case .fade: return "Fade"
        case .bass: return "Bass"
        case .filter: return "Filter"
        }
    }
}

enum DJPlanRole: String, Codable, Sendable {
    case outgoing
    case incoming
}

enum DJPlanPointID: String, Codable, CaseIterable, Sendable {
    case loopRelease
    case fadeInStart
    case fadeInEnd
    case fadeOutStart
    case fadeOutEnd
    case bassSwap
    case filterOutStart
    case filterOutEnd

    var lane: DJPlanLane {
        switch self {
        case .loopRelease: return .loop
        case .fadeInStart, .fadeInEnd, .fadeOutStart, .fadeOutEnd: return .fade
        case .bassSwap: return .bass
        case .filterOutStart, .filterOutEnd: return .filter
        }
    }

    var role: DJPlanRole {
        switch self {
        case .fadeOutStart, .fadeOutEnd, .filterOutStart, .filterOutEnd: return .outgoing
        case .loopRelease, .fadeInStart, .fadeInEnd, .bassSwap: return .incoming
        }
    }

    var noun: String {
        switch self {
        case .loopRelease: return "loop release"
        case .fadeInStart, .fadeInEnd, .fadeOutStart, .fadeOutEnd: return "fade"
        case .bassSwap: return "swap"
        case .filterOutStart, .filterOutEnd: return "filter"
        }
    }
}

struct DJPlanTransitionKey: Hashable, Codable, Sendable, Identifiable {
    var outgoingId: String
    var incomingId: String

    var id: String { "\(outgoingId)>\(incomingId)" }
}

struct DJPlanEditPoint: Codable, Equatable, Sendable {
    var id: DJPlanPointID
    var bar: Double
    var seconds: TimeInterval
}

struct DJPlanEdit: Codable, Equatable, Sendable {
    var moveKind: MixMove.Kind?
    var points: [DJPlanEditPoint] = []

    var isEmpty: Bool { moveKind == nil && points.isEmpty }
    var count: Int { points.count + (moveKind == nil ? 0 : 1) }

    func bar(_ id: DJPlanPointID) -> Double? {
        points.first { $0.id == id }?.bar
    }

    mutating func set(_ id: DJPlanPointID, bar: Double, seconds: TimeInterval) {
        let point = DJPlanEditPoint(id: id, bar: bar, seconds: seconds)
        if let index = points.firstIndex(where: { $0.id == id }) {
            points[index] = point
        } else {
            points.append(point)
        }
    }

    mutating func clear(_ id: DJPlanPointID) {
        points.removeAll { $0.id == id }
    }
}

struct DJPlanTrack: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var duration: TimeInterval
    var grid: BeatGrid?
    var key: CamelotKey?
    var sections: [TrackSection] = []
    var vocalRanges: [ClosedRange<TimeInterval>] = []
    var vocalsMeasured = false
    var loudnessDecibels: Double?
    var analysisProgress: Double?

    var isAnalysing: Bool { analysisProgress != nil }
    var bpm: Double? { grid.map(\.bpm).flatMap { $0 > 0 ? $0 : nil } }

    init(
        id: String,
        title: String,
        artist: String = "",
        duration: TimeInterval,
        grid: BeatGrid? = nil,
        key: CamelotKey? = nil,
        sections: [TrackSection] = [],
        vocalRanges: [ClosedRange<TimeInterval>] = [],
        vocalsMeasured: Bool = false,
        loudnessDecibels: Double? = nil,
        analysisProgress: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.grid = grid
        self.key = key
        self.sections = sections
        self.vocalRanges = vocalRanges
        self.vocalsMeasured = vocalsMeasured
        self.loudnessDecibels = loudnessDecibels
        self.analysisProgress = analysisProgress
    }

    init(features: TrackFeatures, loudnessDecibels: Double? = nil) {
        self.init(
            id: features.trackId,
            title: features.title,
            artist: features.artist,
            duration: features.duration,
            grid: features.beatGrid,
            key: features.provenance.contains(.measuredKey) ? features.keyRegions.first?.key : nil,
            sections: features.sections,
            vocalRanges: features.vocalRanges,
            vocalsMeasured: features.provenance.contains(.measuredVocals),
            loudnessDecibels: loudnessDecibels
        )
    }

    func vocals(at seconds: TimeInterval) -> Bool {
        vocalRanges.contains { $0.contains(seconds) }
    }

    func section(at seconds: TimeInterval) -> TrackSection? {
        sections.first { seconds >= $0.start && seconds < $0.end }
    }
}

struct DJPlanPoint: Equatable, Sendable, Identifiable {
    var id: DJPlanPointID
    var bar: Double
    var level: Double
    var autoBar: Double
    var isUser: Bool
}

enum DJPlanDecision: Equatable, Sendable {
    case accepted(bar: Double, note: String?)
    case refused(String)
}

struct DJPlanSnapNote: Equatable, Sendable {
    var pointID: DJPlanPointID
    var trackTitle: String
    var from: Double
    var to: Double

    var text: String {
        "\(trackTitle)’s grid was re-analysed. Your \(pointID.noun) snapped from \(DJPlanFormat.bar(from)) to bar \(DJPlanFormat.bar(to))."
    }
}

struct DJPlanCheck: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case phrases
        case vocals
        case level
        case bass
    }

    var kind: Kind
    var passed: Bool
    var title: String

    var id: String { kind.rawValue }
}

enum DJPlanFormat {
    static func bar(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 1e-9 { return "\(Int(rounded.rounded()))" }
        return String(format: "%.1f", rounded)
    }

    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Timeline

struct DJPlanTimeline: Equatable, Sendable {
    static let beatsPerBar = 4.0

    var outgoing: DJPlanTrack
    var incoming: DJPlanTrack
    var auto: MixPlanRecord
    var edit: DJPlanEdit
    var maxCamelotSteps: Int

    init(outgoing: DJPlanTrack, incoming: DJPlanTrack, auto: MixPlanRecord, edit: DJPlanEdit = DJPlanEdit(), maxCamelotSteps: Int = 1) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.auto = auto
        self.edit = edit
        self.maxCamelotSteps = maxCamelotSteps
    }

    var barSeconds: TimeInterval { auto.barSeconds }
    var moveKind: MixMove.Kind? { auto.move?.kind }
    var isLoopMix: Bool { moveKind == .loopMix }
    var loopBars: Int { max(1, auto.move?.inLoopBars ?? 0) }
    var hasLoop: Bool { isLoopMix && (auto.move?.inLoopBars ?? 0) > 0 }

    var isBlendFamily: Bool {
        switch moveKind {
        case nil, .blend?, .bridge?, .jump?, .breakdownExit?, .tempoRamp?: return true
        default: return false
        }
    }

    var leadBars: Int {
        guard let move = auto.move, move.kind == .tempoRamp else { return 0 }
        return move.landingBar
    }

    var editablePoints: [DJPlanPointID] {
        if isLoopMix {
            return (hasLoop ? [.loopRelease] : []) + [.fadeInStart, .fadeInEnd, .fadeOutStart, .fadeOutEnd, .bassSwap, .filterOutStart, .filterOutEnd]
        }
        if isBlendFamily { return [.fadeInStart, .fadeOutEnd, .bassSwap] }
        return []
    }

    var lanes: [DJPlanLane] {
        isLoopMix && hasLoop ? DJPlanLane.allCases : [.fade, .bass, .filter]
    }

    var autoPoints: [DJPlanPointID: (bar: Double, level: Double)] {
        let length = Double(max(1, auto.lengthBars))
        guard let move = auto.move else {
            let swap = 1 + min(length, max(0, auto.bassSwapAtSeconds / max(0.1, barSeconds)))
            return [
                .fadeInStart: (1, 0), .fadeInEnd: (1 + length, 1),
                .fadeOutStart: (1, 1), .fadeOutEnd: (1 + length, 0),
                .bassSwap: (swap.rounded(), 0.5)
            ]
        }
        switch move.kind {
        case .loopMix:
            let release = 1 + Double(move.leadBars)
            let end = release + Double(move.blendBars)
            var points: [DJPlanPointID: (bar: Double, level: Double)] = [
                .fadeInStart: (1, 0.25), .fadeInEnd: (release, 1),
                .fadeOutStart: (release, 1), .fadeOutEnd: (end, 0.02),
                .bassSwap: (move.bassSwapBar.map { 1 + Double($0) } ?? release, 0.5),
                .filterOutStart: (release, 0.04), .filterOutEnd: (end, 0.85)
            ]
            if move.inLoopBars > 0 { points[.loopRelease] = (release, 0.5) }
            return points
        case .blend, .bridge, .jump, .breakdownExit, .tempoRamp:
            let start = 1 + Double(leadBars)
            let end = start + Double(max(1, move.blendBars))
            let swap = start + Double(min(max(1, move.bassSwapBar ?? move.blendBars / 2), max(1, move.blendBars - 1)))
            return [
                .fadeInStart: (start, 0), .fadeInEnd: (end, 1),
                .fadeOutStart: (start, 1), .fadeOutEnd: (end, 0),
                .bassSwap: (swap, 0.5)
            ]
        default:
            let landing = 1 + Double(move.landingBar)
            return [
                .fadeInStart: (landing, 0), .fadeInEnd: (landing, 1),
                .fadeOutStart: (landing, 1), .fadeOutEnd: (landing, 0),
                .bassSwap: (landing, 0.5)
            ]
        }
    }

    var points: [DJPlanPoint] {
        let autos = autoPoints
        return DJPlanPointID.allCases.compactMap { id in
            guard let auto = autos[id] else { return nil }
            let user = editablePoints.contains(id) ? edit.bar(id) : nil
            return DJPlanPoint(id: id, bar: resolvedBar(id, user: user, auto: auto.bar), level: auto.level, autoBar: auto.bar, isUser: user != nil)
        }
    }

    private func resolvedBar(_ id: DJPlanPointID, user: Double?, auto: Double) -> Double {
        if let user { return user }
        guard isBlendFamily else { return auto }
        switch id {
        case .fadeOutStart: return edit.bar(.fadeInStart) ?? auto
        case .fadeInEnd: return edit.bar(.fadeOutEnd) ?? auto
        default: return auto
        }
    }

    func point(_ id: DJPlanPointID) -> DJPlanPoint? {
        points.first { $0.id == id }
    }

    func bar(_ id: DJPlanPointID) -> Double? {
        point(id)?.bar
    }

    var endBar: Double {
        max(1 + Double(auto.lengthBars), [DJPlanPointID.fadeOutEnd, .filterOutEnd, .fadeInEnd].compactMap { bar($0) }.max() ?? 1)
    }

    var lengthBars: Int { max(1, Int((endBar - 1 - 1e-9).rounded(.up))) }

    var outgoingEndBar: Double {
        1 + (outgoing.duration - auto.mixPointSeconds) / max(0.1, barSeconds)
    }

    var overlap: ClosedRange<Double> {
        let lower = bar(.fadeInStart) ?? 1
        let upper = max(lower, bar(.fadeOutEnd) ?? endBar)
        return lower...upper
    }

    var overlapBars: Double { overlap.upperBound - overlap.lowerBound }

    var repeats: Int {
        guard hasLoop, let release = bar(.loopRelease) else { return 0 }
        return max(1, Int(((release - 1) / Double(loopBars)).rounded()))
    }

    var incomingBarSeconds: TimeInterval {
        if let grid = incoming.grid, grid.barDuration > 0.2 { return grid.barDuration }
        return barSeconds * max(0.01, auto.incomingRateRatio)
    }

    func outgoingSeconds(atBar bar: Double) -> TimeInterval {
        auto.mixPointSeconds + (bar - 1) * barSeconds
    }

    func incomingSeconds(atBar bar: Double) -> TimeInterval {
        let into = bar - 1
        if hasLoop, let release = self.bar(.loopRelease), bar < release {
            let loop = Double(loopBars)
            let wrapped = into.truncatingRemainder(dividingBy: loop)
            return auto.entrySeconds + (wrapped < 0 ? wrapped + loop : wrapped) * incomingBarSeconds
        }
        if hasLoop, let release = self.bar(.loopRelease) {
            return auto.entrySeconds + (Double(loopBars) + bar - release) * incomingBarSeconds
        }
        return auto.entrySeconds + into * incomingBarSeconds
    }

    func anchorSeconds(_ id: DJPlanPointID, bar: Double) -> TimeInterval {
        switch id.role {
        case .outgoing: return auto.mixPointSeconds + (bar - 1) * barSeconds
        case .incoming: return auto.entrySeconds + (bar - 1) * incomingBarSeconds
        }
    }

    func incomingLevel(atBar bar: Double) -> Double {
        let start = self.bar(.fadeInStart) ?? 1
        let end = self.bar(.fadeInEnd) ?? endBar
        let startLevel = point(.fadeInStart)?.level ?? 0
        if bar < start { return 0 }
        if bar >= end || end - start < 1e-9 { return 1 }
        return startLevel + (1 - startLevel) * (bar - start) / (end - start)
    }

    func outgoingLevel(atBar bar: Double) -> Double {
        let start = self.bar(.fadeOutStart) ?? 1
        let end = self.bar(.fadeOutEnd) ?? endBar
        let endLevel = point(.fadeOutEnd)?.level ?? 0
        if bar <= start { return 1 }
        if bar >= end || end - start < 1e-9 { return bar >= end ? 0 : 1 }
        return 1 - (1 - endLevel) * (bar - start) / (end - start)
    }

    var vocalOverlapBeats: Int {
        var beats = 0
        var b = overlap.lowerBound
        while b < overlap.upperBound - 1e-9 {
            let mid = b + 0.125
            if outgoing.vocals(at: outgoingSeconds(atBar: mid)), incoming.vocals(at: incomingSeconds(atBar: mid)) { beats += 1 }
            b += 1 / Self.beatsPerBar
        }
        return beats
    }

    var keySteps: Int? {
        guard let a = outgoing.key, let b = incoming.key else { return nil }
        return DJMixRules.keySteps(a, b)
    }

    var keysClash: Bool {
        overlapBars > DJMixRules.keyClashOverlapBars && (keySteps ?? 0) > maxCamelotSteps
    }

    var vocalsClash: Bool {
        if outgoing.vocalsMeasured && incoming.vocalsMeasured { return vocalOverlapBeats > 1 }
        return overlapBars > DJMixRules.unmeasuredVocalOverlapBars
    }

    var swapIsInsideOverlap: Bool {
        guard let swap = bar(.bassSwap) else { return true }
        return swap >= overlap.lowerBound - 1e-9 && swap <= overlap.upperBound + 1e-9
    }

    // MARK: Edits

    func applying(_ id: DJPlanPointID, bar: Double) -> DJPlanTimeline {
        var next = self
        next.edit.set(id, bar: bar, seconds: anchorSeconds(id, bar: bar))
        return next
    }

    func propose(_ id: DJPlanPointID, to raw: Double, free: Bool = false) -> DJPlanDecision {
        guard editablePoints.contains(id) else { return .refused("Fixed for this move") }
        var target = free ? raw : (raw * Self.beatsPerBar).rounded() / Self.beatsPerBar
        target = max(1, target)
        if id == .loopRelease {
            let passes = max(1, ((target - 1) / Double(loopBars)).rounded())
            target = 1 + passes * Double(loopBars)
            if (passes - 1) * Double(loopBars) > Double(DJMixRules.maximumLoopRepeatBars) {
                return .refused("Loops are capped at \(DJMixRules.maximumLoopRepeatBars) bars")
            }
        }
        if target > outgoingEndBar + 1e-6 {
            return .refused("\(outgoing.title) ends at bar \(DJPlanFormat.bar(outgoingEndBar.rounded(.down)))")
        }
        let unclamped = target
        target = clampOrder(id, target)
        let next = applying(id, bar: target)
        if !next.swapIsInsideOverlap, id == .bassSwap || swapIsInsideOverlap {
            return .refused("Bass swaps while both decks play")
        }
        if next.vocalsClash, !vocalsClash {
            return .refused("Vocals would overlap")
        }
        if next.keysClash, !keysClash {
            return .refused("Keys clash past \(Int(DJMixRules.keyClashOverlapBars)) bars")
        }
        return .accepted(bar: target, note: abs(target - unclamped) > 1e-9 ? "Can’t pass the other end" : nil)
    }

    private func clampOrder(_ id: DJPlanPointID, _ target: Double) -> Double {
        func pair(_ low: DJPlanPointID, _ high: DJPlanPointID) -> Double {
            if id == low, let upper = bar(high) { return min(target, upper) }
            if id == high, let lower = bar(low) { return max(target, lower) }
            return target
        }
        switch id {
        case .fadeInStart where isBlendFamily, .fadeOutEnd where isBlendFamily:
            return pair(.fadeInStart, .fadeOutEnd)
        case .fadeInStart, .fadeInEnd:
            return pair(.fadeInStart, .fadeInEnd)
        case .fadeOutStart, .fadeOutEnd:
            return pair(.fadeOutStart, .fadeOutEnd)
        case .filterOutStart, .filterOutEnd:
            return pair(.filterOutStart, .filterOutEnd)
        case .loopRelease, .bassSwap:
            return target
        }
    }

    // MARK: Forced plan

    var forcedPlan: MixPlanRecord {
        guard !edit.points.isEmpty else { return auto }
        var plan = auto
        func rel(_ id: DJPlanPointID) -> Double? { bar(id).map { $0 - 1 } }
        let swap = rel(.bassSwap)
        if isLoopMix, var move = auto.move {
            let release = rel(.loopRelease) ?? Double(move.leadBars)
            move.leadBars = max(0, Int(release.rounded()))
            let end = [rel(.fadeOutEnd), rel(.filterOutEnd), rel(.fadeInEnd)].compactMap { $0 }.max() ?? Double(move.totalBars)
            move.blendBars = max(1, Int((end - 1e-9).rounded(.up)) - move.leadBars)
            move.shape = MixMoveShape(
                bassSwapBar: swap,
                fadeIn: range(rel(.fadeInStart), rel(.fadeInEnd)),
                fadeOut: range(rel(.fadeOutStart), rel(.fadeOutEnd)),
                outgoingFilter: range(rel(.filterOutStart), rel(.filterOutEnd))
            )
            plan.move = move
            plan.transitionSeconds = Double(move.totalBars) * barSeconds
        } else if var move = auto.move, isBlendFamily {
            let start = rel(.fadeInStart) ?? Double(leadBars)
            let end = rel(.fadeOutEnd) ?? Double(move.totalBars)
            move.blendBars = max(1, Int((end - 1e-9).rounded(.up)) - leadBars)
            move.shape = MixMoveShape(bassSwapBar: swap, fadeIn: range(start, end), fadeOut: range(start, end), outgoingFilter: nil)
            plan.move = move
            plan.transitionSeconds = Double(move.totalBars) * barSeconds
        } else if auto.move == nil {
            plan.transitionSeconds = (rel(.fadeOutEnd) ?? Double(auto.lengthBars)) * barSeconds
        }
        if let swap { plan.bassSwapAtSeconds = swap * barSeconds }
        return plan
    }

    private func range(_ a: Double?, _ b: Double?) -> ClosedRange<Double>? {
        guard let a, let b else { return nil }
        return min(a, b)...max(a, b)
    }

    // MARK: Checks

    var checks: [DJPlanCheck] {
        [phraseCheck, vocalCheck, levelCheck, bassCheck]
    }

    private var phraseCheck: DJPlanCheck {
        guard let out = outgoing.grid, let inc = incoming.grid else {
            return DJPlanCheck(kind: .phrases, passed: false, title: "No beat grid")
        }
        let aligned = DJMixRules.phrasesLineUp(
            exitBeats: out.beatsFromPhraseBoundary(at: auto.mixPointSeconds),
            entryBeats: inc.beatsFromPhraseBoundary(at: auto.entrySeconds)
        )
        let offBar = [DJPlanPointID.loopRelease, .bassSwap, .fadeOutStart].compactMap { bar($0) }.first { value in
            let beats = (value - 1) * Self.beatsPerBar
            let r = beats.truncatingRemainder(dividingBy: Self.beatsPerBar)
            return min(abs(r), Self.beatsPerBar - abs(r)) >= DJMixRules.phraseBeatTolerance
        }
        if let offBar { return DJPlanCheck(kind: .phrases, passed: false, title: "Off the bar at \(DJPlanFormat.bar(offBar))") }
        return DJPlanCheck(kind: .phrases, passed: aligned, title: aligned ? "Phrases line up" : "Phrases don’t line up")
    }

    private var vocalCheck: DJPlanCheck {
        guard outgoing.vocalsMeasured && incoming.vocalsMeasured else {
            let ok = overlapBars <= DJMixRules.unmeasuredVocalOverlapBars
            return DJPlanCheck(kind: .vocals, passed: ok, title: ok ? "Vocals not measured" : "Overlap over 8 bars")
        }
        let beats = vocalOverlapBeats
        if beats <= 1 { return DJPlanCheck(kind: .vocals, passed: true, title: "No vocal overlap") }
        return DJPlanCheck(kind: .vocals, passed: false, title: "Vocals overlap \(DJPlanFormat.bar(Double(beats) / Self.beatsPerBar)) bars")
    }

    private var levelCheck: DJPlanCheck {
        if let a = outgoing.loudnessDecibels, let b = incoming.loudnessDecibels, abs(a - b) > DJMixRules.maxLevelStepDecibels {
            return DJPlanCheck(kind: .level, passed: false, title: "Levels \(Int(abs(a - b).rounded())) dB apart")
        }
        var b = 1.0
        while b <= endBar {
            if max(incomingLevel(atBar: b), outgoingLevel(atBar: b)) < 0.5 - 1e-9 {
                return DJPlanCheck(kind: .level, passed: false, title: "Level dips at bar \(DJPlanFormat.bar(b))")
            }
            b += 1 / Self.beatsPerBar
        }
        return DJPlanCheck(kind: .level, passed: true, title: "Level stays even")
    }

    private var bassCheck: DJPlanCheck {
        swapIsInsideOverlap
            ? DJPlanCheck(kind: .bass, passed: true, title: "Bass never doubles")
            : DJPlanCheck(kind: .bass, passed: false, title: "Bass doubles")
    }

    // MARK: Re-analysis

    func reconciling(_ stored: DJPlanEdit) -> (edit: DJPlanEdit, notes: [DJPlanSnapNote]) {
        var edit = stored
        var notes: [DJPlanSnapNote] = []
        for point in stored.points {
            let base = point.id.role == .outgoing ? auto.mixPointSeconds : auto.entrySeconds
            let length = point.id.role == .outgoing ? barSeconds : incomingBarSeconds
            let raw = 1 + (point.seconds - base) / max(0.1, length)
            guard abs(raw - point.bar) > 0.01 else { continue }
            let snapped = max(1, (raw * Self.beatsPerBar).rounded() / Self.beatsPerBar)
            edit.set(point.id, bar: snapped, seconds: base + (snapped - 1) * length)
            let title = point.id.role == .outgoing ? outgoing.title : incoming.title
            notes.append(DJPlanSnapNote(pointID: point.id, trackTitle: title, from: raw, to: snapped))
        }
        return (edit, notes)
    }
}

// MARK: - Crate

struct DJPlanCrate: Equatable, Sendable {
    var name: String
    var tracks: [DJPlanTrack]
    var lockedCount: Int

    init(name: String, tracks: [DJPlanTrack], lockedCount: Int = 0) {
        self.name = name
        self.tracks = tracks
        self.lockedCount = lockedCount
    }

    var joins: [DJPlanTransitionKey] {
        guard tracks.count > 1 else { return [] }
        return zip(tracks, tracks.dropFirst()).map { DJPlanTransitionKey(outgoingId: $0.id, incomingId: $1.id) }
    }

    func canMove(from index: Int) -> Bool {
        index >= lockedCount && index < tracks.count
    }

    mutating func move(from source: Int, to destination: Int) -> Result<Set<DJPlanTransitionKey>, DJPlanMoveRefusal> {
        guard canMove(from: source) else { return .failure(.playing) }
        let insertion = min(max(destination, 0), tracks.count)
        guard insertion >= lockedCount else { return .failure(.beforeLive) }
        let before = Set(joins)
        let track = tracks.remove(at: source)
        tracks.insert(track, at: insertion > source ? insertion - 1 : insertion)
        return .success(Set(joins).subtracting(before))
    }
}

enum DJPlanMoveRefusal: Error, Equatable, Sendable {
    case playing
    case beforeLive

    var message: String {
        switch self {
        case .playing: return "That track is already playing"
        case .beforeLive: return "Can’t move before the live mix"
        }
    }
}

// MARK: - History

struct DJPlanEditRecord: Codable, Equatable, Sendable {
    static let historyLimit = 30

    var edit = DJPlanEdit()
    var undo: [DJPlanEdit] = []
    var redo: [DJPlanEdit] = []
    var updatedAt: Date = .distantPast

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }

    mutating func apply(_ next: DJPlanEdit, at date: Date = Date()) {
        guard next != edit else { return }
        undo.append(edit)
        if undo.count > Self.historyLimit { undo.removeFirst(undo.count - Self.historyLimit) }
        redo = []
        edit = next
        updatedAt = date
    }

    mutating func revert(at date: Date = Date()) {
        apply(DJPlanEdit(), at: date)
    }

    @discardableResult
    mutating func undoLast(at date: Date = Date()) -> Bool {
        guard let previous = undo.popLast() else { return false }
        redo.append(edit)
        edit = previous
        updatedAt = date
        return true
    }

    @discardableResult
    mutating func redoLast(at date: Date = Date()) -> Bool {
        guard let next = redo.popLast() else { return false }
        undo.append(edit)
        edit = next
        updatedAt = date
        return true
    }
}

struct DJPlanEditLibrary: Codable, Equatable, Sendable {
    static let limit = 200

    var records: [String: DJPlanEditRecord] = [:]

    init(records: [String: DJPlanEditRecord] = [:]) {
        self.records = records
    }

    init(data: Data) {
        self = (try? JSONDecoder().decode(DJPlanEditLibrary.self, from: data)) ?? DJPlanEditLibrary()
    }

    var encoded: Data {
        guard !records.isEmpty else { return Data() }
        return (try? JSONEncoder().encode(self)) ?? Data()
    }

    subscript(key: DJPlanTransitionKey) -> DJPlanEditRecord {
        get { records[key.id] ?? DJPlanEditRecord() }
        set {
            records[key.id] = newValue.edit.isEmpty && newValue.undo.isEmpty && newValue.redo.isEmpty ? nil : newValue
            trim()
        }
    }

    private mutating func trim() {
        guard records.count > Self.limit else { return }
        let stale = records.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(records.count - Self.limit)
        for (key, _) in stale { records[key] = nil }
    }
}

// MARK: - Moves

enum DJPlanMoves {
    static let choices: [MixMove.Kind] = [.loopMix, .blend, .echoOut, .cut]

    static func move(for kind: MixMove.Kind) -> MixMove? {
        switch kind {
        case .loopMix: return .loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 8)
        case .blend: return .blend(bars: 16, swapAt: 8)
        case .echoOut: return .echoOut
        case .cut: return .cut
        default: return nil
        }
    }

    static func reshape(_ record: MixPlanRecord, to kind: MixMove.Kind) -> MixPlanRecord? {
        if record.move?.kind == kind { return record }
        guard let move = move(for: kind) else { return nil }
        var plan = record
        plan.move = move
        plan.templateId = nil
        plan.stages = []
        plan.accent = nil
        plan.transitionSeconds = Double(move.totalBars) * record.barSeconds
        plan.bassSwapAtSeconds = Double(move.bassSwapBar ?? move.leadBars) * record.barSeconds
        return plan
    }

    static func name(_ kind: MixMove.Kind) -> String {
        MixMove(kind: kind).displayName
    }
}
