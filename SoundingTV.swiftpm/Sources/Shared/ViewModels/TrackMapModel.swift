import Combine
import SwiftUI

enum TrackMapCopy {
    static let title = "Cue Points"
    static let mixPoints = "Mix Points"
    static let hotCues = "Hot Cues"
    static let cuePoints = "Cue Points"
    static let analysis = "Music Analysis"
    static let timeline = "Timeline"
    static let nothingPlaying = "Nothing Playing"
    static let emptyTitle = "No Cue Points"
    static let emptyDescription = "Move along the timeline to a moment, then save it."
    static let suggested = "Suggested"
    static let allCuePoints = "All Cue Points"
    static let panelHint = "Hot cues, loops and mix points"
    static let clickAgain = "Click Again"
    static let options = "Options"
    static let edit = "Edit…"
    static let editTitle = "Edit Cue Point"
    static let name = "Name"
    static let position = "Position"
    static let colour = "Colour"
    static let type = "Type"
    static let delete = "Delete Cue Point"
    static let clear = "Clear"
    static let keepSuggestion = "Keep Suggestion"
    static let accept = "Accept"
    static let dismiss = "Dismiss"
    static let set = "Set"
    static let saveCuePoint = "Save Cue Point"
    static let addLoop = "Add Loop"
    static let playFromHere = "Play from Here"
    static let playsFromHere = "Plays from here"
    static let timelineHint = "Adjust to pick a moment"
    static let remoteHint = "Swipe to move, click to play from here"
    static let done = "Done"
    static let undo = "Undo"
    static let redo = "Redo"
    static let cueKind = "Cue Point"
    static let loopKind = "Loop"
    static let colourNames = ["Green", "Orange", "Yellow", "Blue", "Cyan", "Pink", "Purple", "White"]

    static func save(at time: String) -> String { "Save Cue Point at \(time)" }
    static func moveTo(_ time: String) -> String { "Move to \(time)" }
    static func setTo(_ time: String) -> String { "Set to \(time)" }
    static func setMix(_ role: String, at time: String) -> String { "Set \(role) at \(time)" }
    static func hotCue(_ slot: Int) -> String { "Hot Cue \(CuePoint.slotLetter(slot))" }
    static func hotLoop(_ slot: Int) -> String { "Hot Loop \(CuePoint.slotLetter(slot))" }
    static func acceptAsHotCue(_ slot: Int) -> String { "Accept as \(hotCue(slot))" }
    static func setHotCue(_ slot: Int, at time: String) -> String { "Set \(hotCue(slot)) at \(time)" }
    static func runsTo(_ time: String) -> String { "to \(time)" }
    static func bar(_ number: Int) -> String { "Bar \(number)" }
    static func suggested(_ reasoning: String) -> String { reasoning.isEmpty ? suggested : "\(suggested) · \(reasoning)" }
    static func suggestionCaption(kind: CueKind, label: String) -> String {
        switch kind {
        case .mixIn: return suggested("Auto Mix would come in here")
        case .mixOut: return suggested("Auto Mix would leave here")
        case .loop: return suggested("A loop that fits here")
        case .hotCue, .memory:
            switch label.lowercased() {
            case "drop": return suggested("Sounds like a drop")
            case "breakdown": return suggested("Sounds like a breakdown")
            case "often replayed": return suggested("You often come back here")
            default: return suggested
            }
        }
    }
    static func timelineValue(_ mark: String, of total: String) -> String { "\(mark) of \(total)" }
    static func count(_ count: Int) -> String { count == 1 ? "1 cue point" : "\(count) cue points" }
    static let fromRekordbox = "From rekordbox"
    static let fromSuggestion = "From a suggestion"
    static let missingValue = "–"
}

@MainActor
final class TrackMapModel: ObservableObject {
    enum MixRole: CaseIterable {
        case mixIn
        case mixOut

        var title: String { self == .mixIn ? "Mix In" : "Mix Out" }
        var kind: CueKind { self == .mixIn ? .mixIn : .mixOut }
        var storeLabel: String { self == .mixIn ? "Mix in" : "Mix out" }
        var setCaption: String { self == .mixIn ? "Auto Mix starts this track here" : "Auto Mix leaves this track here" }
        var unsetCaption: String { self == .mixIn ? "Not set · Auto Mix will pick where to come in" : "Not set · Auto Mix will pick where to leave" }
        var rowId: String { self == .mixIn ? "trackmap.mixin" : "trackmap.mixout" }
    }

    struct Glyph: Equatable {
        enum Shape { case diamond, circle, square }
        enum Fill { case solid, hollow, dashed }

        let shape: Shape
        let fill: Fill
        let color: CueColor
    }

    struct Action: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        var isDestructive = false
        let perform: () -> Void
    }

    struct Row: Identifiable {
        let id: String
        let glyph: Glyph
        let title: String
        let caption: String?
        let time: String?
        let isMuted: Bool
        let seekSeconds: TimeInterval?
        let cueId: String?
        let primary: Action?
        let actions: [Action]

        var accessibilityLabel: String {
            [title, time, caption].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct Pad: Identifiable {
        let slot: Int
        let letter: String
        let title: String?
        let time: String?
        let color: CueColor?
        let cueId: String?
        let accessibilityLabel: String
        let perform: () -> Void

        var id: Int { slot }
        var isSet: Bool { cueId != nil }
    }

    struct Fact: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    struct Marker: Identifiable {
        let id: String
        let fraction: Double
        let endFraction: Double?
        let color: CueColor
        let isSuggestion: Bool
    }

    struct PhraseSpan: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let kind: SectionKind
    }

    @Published private(set) var trackId: String?
    @Published private(set) var trackTitle = ""
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var envelope: [Float] = []
    @Published private(set) var prep: TrackPrep?
    @Published var scrubPreview: TimeInterval?
    @Published var selectedCueId: String?
    @Published var editingCueId: String?
    @Published private(set) var jumpCount = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var livePosition: @MainActor () -> TimeInterval = { 0 }
    var onSeek: @MainActor (TimeInterval) -> Void = { _ in }
    var onEdit: (@MainActor () async -> Void)?
    var onStoreChange: (@MainActor () async -> Void)?
    var isEditable = true
    weak var undoManager: UndoManager? {
        didSet { observeUndo() }
    }

    let board: CueBoard
    private var store: CueStore { board.store }
    private var boardChanges: AnyCancellable?
    private var undoChanges: AnyCancellable?
    private var prepTask: Task<Void, Never>?
    private var pendingWrites = 0
    private var ownUndoManager: UndoManager?

    private var undo: UndoManager {
        if let undoManager { return undoManager }
        if let ownUndoManager { return ownUndoManager }
        let made = UndoManager()
        made.groupsByEvent = false
        ownUndoManager = made
        observeUndo()
        return made
    }

    init(board: CueBoard = CueBoard()) {
        self.board = board
        boardChanges = board.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        board.onStoreChange = { [weak self] sheetChanged in await self?.storeChanged(sheetChanged: sheetChanged) }
    }

    private func observeUndo() {
        let manager = undo
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
        undoChanges = Publishers.MergeMany(names.map { center.publisher(for: $0, object: manager) })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshUndoState() } }
        refreshUndoState()
    }

    private func registerUndo(_ action: String, _ handler: @escaping @Sendable (TrackMapModel) -> Void) {
        let manager = undo
        let groups = !manager.groupsByEvent && manager.groupingLevel == 0
        if groups { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self, handler: handler)
        manager.setActionName(action)
        if groups { manager.endUndoGrouping() }
        refreshUndoState()
    }

    private func refreshUndoState() {
        let manager = undo
        if canUndo != manager.canUndo { canUndo = manager.canUndo }
        if canRedo != manager.canRedo { canRedo = manager.canRedo }
    }

    func undoLast() {
        guard undo.canUndo else { return }
        undo.undo()
        refreshUndoState()
    }

    func redoLast() {
        guard undo.canRedo else { return }
        undo.redo()
        refreshUndoState()
    }

    var undoTitle: String {
        let name = undo.undoActionName
        return name.isEmpty ? TrackMapCopy.undo : "\(TrackMapCopy.undo) \(name)"
    }

    private func storeChanged(sheetChanged: Bool) async {
        guard let trackId else { return }
        let loaded = await store.prep(forTrack: trackId)
        guard self.trackId == trackId else { return }
        let prepChanged = loaded != prep
        if prepChanged { prep = loaded }
        if pendingWrites == 0, editingCueId != nil, editingCue == nil { editingCueId = nil }
        if prepChanged || sheetChanged { await onStoreChange?() }
    }

    func load(trackId: String?, title: String, duration: TimeInterval, envelope: [Float], beatGrid: BeatGrid? = nil) {
        let changed = trackId != self.trackId
        if changed {
            scrubPreview = nil
            selectedCueId = nil
            editingCueId = nil
        }
        if self.trackId != trackId { self.trackId = trackId }
        if trackTitle != title { trackTitle = title }
        if self.duration != duration { self.duration = duration }
        if self.envelope.count != envelope.count || changed { self.envelope = envelope }
        board.ensureLoaded(trackId: trackId, duration: duration, waveform: envelope.isEmpty ? nil : Waveform(samples: envelope), beatGrid: beatGrid)
        reloadPrep()
    }

    func reloadPrep() {
        prepTask?.cancel()
        guard let trackId else {
            prep = nil
            return
        }
        let store = store
        prepTask = Task { [weak self] in
            let loaded = await store.prep(forTrack: trackId)
            guard let self, !Task.isCancelled, self.trackId == trackId else { return }
            if self.prep != loaded { self.prep = loaded }
        }
    }

    var grid: BeatGrid? {
        prep?.grid?.value.beatGrid(durationSeconds: duration, confidence: 0.9)
    }

    var markTime: TimeInterval {
        let raw = scrubPreview ?? livePosition()
        return duration > 0 ? min(duration, max(0, raw)) : max(0, raw)
    }

    var markText: String { DJFormat.time(markTime) }
    var durationText: String { DJFormat.time(duration) }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, markTime / duration))
    }

    func snapped(_ seconds: TimeInterval) -> TimeInterval {
        guard let grid else { return seconds }
        return min(max(0, grid.nearestBeat(to: seconds)), duration > 0 ? duration : .infinity)
    }

    func preview(_ seconds: TimeInterval) {
        guard duration > 0 else { return }
        scrubPreview = min(duration, max(0, seconds))
    }

    func previewFraction(_ fraction: Double) {
        preview(min(1, max(0, fraction)) * duration)
    }

    func nudgePreview(by delta: TimeInterval) {
        preview(markTime + delta)
    }

    var beatStep: TimeInterval {
        guard let grid, grid.beatPeriod > 0 else { return 1 }
        return grid.beatPeriod
    }

    func playFromMark() {
        let target = markTime
        scrubPreview = nil
        onSeek(target)
    }

    func jump(to seconds: TimeInterval, cueId: String? = nil) {
        selectedCueId = cueId
        scrubPreview = nil
        onSeek(seconds)
        jumpCount += 1
    }

    func jump(_ row: Row) {
        guard let seconds = row.seekSeconds else { return }
        jump(to: seconds, cueId: row.cueId)
    }

    func bar(at seconds: TimeInterval) -> Int? {
        guard let grid = prep?.grid?.value else { return nil }
        let downbeats = grid.downbeatMillis(throughMillis: CueTime.millis(fromSeconds: seconds) + 1)
        return downbeats.isEmpty ? nil : downbeats.count
    }

    func preciseTime(_ seconds: TimeInterval) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let text = String(format: "%d:%02d.%03d", millis / 60_000, (millis / 1000) % 60, millis % 1000)
        guard let bar = bar(at: seconds) else { return text }
        return "\(text) · \(TrackMapCopy.bar(bar).lowercased())"
    }

    var userCues: [CuePoint] { board.sheet.userCues }

    func cue(_ id: String?) -> CuePoint? {
        guard let id else { return nil }
        return userCues.first { $0.id == id }
    }

    var selectedCue: CuePoint? { cue(selectedCueId) }
    var editingCue: CuePoint? { cue(editingCueId) }

    var cueCount: Int { board.sheet.entries.count }

    var markers: [Marker] {
        guard duration > 0 else { return [] }
        return board.sheet.entries.map { entry in
            Marker(
                id: entry.id,
                fraction: min(1, max(0, entry.positionSeconds / duration)),
                endFraction: entry.kind == .loop ? entry.endMillis.map { min(1, max(0, CueTime.seconds(fromMillis: $0) / duration)) } : nil,
                color: entry.color,
                isSuggestion: entry.isSuggestion
            )
        }
    }

    var phrases: [PhraseSpan] {
        guard duration > 0, let phrases = prep?.phrases?.value, !phrases.isEmpty else { return [] }
        let sorted = phrases.sorted { $0.startMillis < $1.startMillis }
        return sorted.enumerated().map { index, phrase in
            let start = CueTime.seconds(fromMillis: phrase.startMillis) / duration
            let end = index + 1 < sorted.count ? CueTime.seconds(fromMillis: sorted[index + 1].startMillis) / duration : 1
            return PhraseSpan(id: index, start: min(1, max(0, start)), end: min(1, max(0, end)), kind: phrase.kind)
        }
    }

    var mixRows: [Row] { MixRole.allCases.map(mixRow) }

    var cueRows: [Row] {
        board.sheet.entries.compactMap { entry in
            guard entry.kind != .mixIn, entry.kind != .mixOut else { return nil }
            if let cue = entry.userCue { return cueRow(cue) }
            if let suggestion = entry.suggestion { return suggestionRow(suggestion) }
            return nil
        }
    }

    var allRows: [Row] {
        board.sheet.entries.compactMap { entry in
            if entry.kind == .mixIn { return mixRow(.mixIn) }
            if entry.kind == .mixOut { return mixRow(.mixOut) }
            if let cue = entry.userCue { return cueRow(cue) }
            if let suggestion = entry.suggestion { return suggestionRow(suggestion) }
            return nil
        }
    }

    var pads: [Pad] {
        (0..<CuePoint.hotCueSlotCount).map { slot in
            let letter = CuePoint.slotLetter(slot)
            if let cue = userCues.first(where: { $0.hotCueIndex == slot }) {
                let name = cue.label.isEmpty ? nil : cue.label
                let time = DJFormat.time(cue.positionSeconds)
                return Pad(
                    slot: slot,
                    letter: letter,
                    title: name,
                    time: time,
                    color: cue.color,
                    cueId: cue.id,
                    accessibilityLabel: [cue.kind == .loop ? TrackMapCopy.hotLoop(slot) : TrackMapCopy.hotCue(slot), name, time].compactMap { $0 }.joined(separator: ", "),
                    perform: { [weak self] in self?.jump(to: cue.positionSeconds, cueId: cue.id) }
                )
            }
            return Pad(
                slot: slot,
                letter: letter,
                title: nil,
                time: nil,
                color: nil,
                cueId: nil,
                accessibilityLabel: TrackMapCopy.setHotCue(slot, at: markText),
                perform: { [weak self] in self?.setHotCue(slot: slot) }
            )
        }
    }

    var facts: [Fact] {
        guard let prep else { return [] }
        let key = prep.key?.value
        let keyText = key.map { $0.original.isEmpty || $0.original == $0.camelot ? $0.camelot : "\($0.camelot) · \($0.original)" }
        let energyText = prep.energy.map { "\($0.value) of 10" }
        let phrasesText = prep.phrases.flatMap { $0.value.isEmpty ? nil : "\($0.value.count)" }
        let vocals = vocalsText(prep)
        guard keyText != nil || energyText != nil || phrasesText != nil || vocals != nil else { return [] }
        return [
            Fact(title: "Key", value: keyText ?? TrackMapCopy.missingValue),
            Fact(title: "Energy", value: energyText ?? TrackMapCopy.missingValue),
            Fact(title: "Vocals", value: vocals ?? TrackMapCopy.missingValue),
            Fact(title: "Phrases", value: phrasesText ?? TrackMapCopy.missingValue),
        ]
    }

    private func vocalsText(_ prep: TrackPrep) -> String? {
        guard let phrases = prep.phrases?.value, let grid = prep.grid?.value, !phrases.isEmpty else { return nil }
        let vocal = phrases.enumerated().filter { $0.element.mood?.lowercased().contains("vocal") == true }
        guard let first = vocal.first else { return "None found" }
        let total = CueTime.millis(fromSeconds: duration)
        let downbeats = grid.downbeatMillis(throughMillis: total)
        func bar(_ millis: Int64) -> Int { max(1, downbeats.filter { $0 <= millis }.count) }
        let lastIndex = vocal.last?.offset ?? first.offset
        let end = lastIndex + 1 < phrases.count ? phrases[lastIndex + 1].startMillis : total
        return "Bars \(bar(first.element.startMillis))–\(bar(end))"
    }

    static func title(for cue: CuePoint) -> String {
        if !cue.label.isEmpty, cue.kind != .mixIn, cue.kind != .mixOut { return cue.label }
        return kindTitle(cue)
    }

    static func kindTitle(_ cue: CuePoint) -> String {
        switch cue.kind {
        case .mixIn: return MixRole.mixIn.title
        case .mixOut: return MixRole.mixOut.title
        case .hotCue: return TrackMapCopy.hotCue(cue.hotCueIndex ?? 0)
        case .loop: return cue.hotCueIndex.map(TrackMapCopy.hotLoop) ?? TrackMapCopy.loopKind
        case .memory: return TrackMapCopy.cueKind
        }
    }

    static func title(for suggestion: CueSuggestion) -> String {
        suggestion.label.isEmpty ? suggestion.kind.displayName.capitalized : suggestion.label
    }

    func caption(for cue: CuePoint) -> String? {
        var parts: [String] = []
        if !cue.label.isEmpty, cue.kind == .hotCue || cue.kind == .loop { parts.append(Self.kindTitle(cue)) }
        if let end = cue.endSeconds { parts.append(TrackMapCopy.runsTo(DJFormat.time(end))) }
        if let bar = bar(at: cue.positionSeconds) { parts.append(TrackMapCopy.bar(bar)) }
        if cue.origin == .imported {
            parts.append(TrackMapCopy.fromRekordbox)
        } else if cue.promotedFrom != nil {
            parts.append(TrackMapCopy.fromSuggestion)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func mixRow(_ role: MixRole) -> Row {
        let resolved = role == .mixIn ? board.sheet.mixIn : board.sheet.mixOut
        let mark = markText
        if let cue = resolved?.userCue {
            return Row(
                id: role.rowId,
                glyph: Glyph(shape: .diamond, fill: .solid, color: CueColor.default(for: role.kind)),
                title: role.title,
                caption: role.setCaption,
                time: DJFormat.time(cue.positionSeconds),
                isMuted: false,
                seekSeconds: cue.positionSeconds,
                cueId: cue.id,
                primary: nil,
                actions: [
                    Action(id: "move", title: TrackMapCopy.moveTo(mark), systemImage: "arrow.right.to.line") { [weak self] in self?.setMix(role) },
                    Action(id: "clear", title: TrackMapCopy.clear, systemImage: "xmark", isDestructive: true) { [weak self] in self?.delete(cue) },
                ]
            )
        }
        if let suggestion = resolved?.suggestion {
            return Row(
                id: role.rowId,
                glyph: Glyph(shape: .diamond, fill: .hollow, color: CueColor.default(for: role.kind)),
                title: role.title,
                caption: TrackMapCopy.suggestionCaption(kind: suggestion.kind, label: suggestion.label),
                time: DJFormat.time(suggestion.positionSeconds),
                isMuted: true,
                seekSeconds: suggestion.positionSeconds,
                cueId: nil,
                primary: nil,
                actions: [
                    Action(id: "keep", title: TrackMapCopy.keepSuggestion, systemImage: "checkmark") { [weak self] in self?.accept(suggestion) },
                    Action(id: "set", title: TrackMapCopy.setTo(mark), systemImage: "arrow.right.to.line") { [weak self] in self?.setMix(role) },
                ]
            )
        }
        return Row(
            id: role.rowId,
            glyph: Glyph(shape: .diamond, fill: .dashed, color: CueColor.default(for: role.kind)),
            title: role.title,
            caption: role.unsetCaption,
            time: nil,
            isMuted: true,
            seekSeconds: nil,
            cueId: nil,
            primary: Action(id: "set", title: TrackMapCopy.set, systemImage: "arrow.right.to.line") { [weak self] in self?.setMix(role) },
            actions: [
                Action(id: "setTo", title: TrackMapCopy.setTo(mark), systemImage: "arrow.right.to.line") { [weak self] in self?.setMix(role) },
            ]
        )
    }

    private func cueRow(_ cue: CuePoint) -> Row {
        Row(
            id: cue.id,
            glyph: Glyph(shape: cue.kind == .loop ? .square : .circle, fill: .solid, color: cue.color),
            title: Self.title(for: cue),
            caption: caption(for: cue),
            time: DJFormat.time(cue.positionSeconds),
            isMuted: false,
            seekSeconds: cue.positionSeconds,
            cueId: cue.id,
            primary: nil,
            actions: [
                Action(id: "edit", title: TrackMapCopy.edit, systemImage: "pencil") { [weak self] in self?.editingCueId = cue.id },
                Action(id: "move", title: TrackMapCopy.moveTo(markText), systemImage: "arrow.right.to.line") { [weak self] in self?.move(cue) },
                Action(id: "delete", title: TrackMapCopy.delete, systemImage: "trash", isDestructive: true) { [weak self] in self?.delete(cue) },
            ]
        )
    }

    private func suggestionRow(_ suggestion: CueSuggestion) -> Row {
        var actions = [
            Action(id: "accept", title: TrackMapCopy.accept, systemImage: "checkmark") { [weak self] in self?.accept(suggestion) },
        ]
        if let slot = board.freeHotSlot() {
            actions.append(Action(id: "acceptHot", title: TrackMapCopy.acceptAsHotCue(slot), systemImage: "square.grid.2x2") { [weak self] in
                self?.accept(suggestion, asHotCue: true)
            })
        }
        actions.append(Action(id: "dismiss", title: TrackMapCopy.dismiss, systemImage: "xmark", isDestructive: true) { [weak self] in self?.dismiss(suggestion) })
        return Row(
            id: suggestion.id,
            glyph: Glyph(shape: suggestion.kind == .loop ? .square : .circle, fill: .hollow, color: suggestion.color),
            title: Self.title(for: suggestion),
            caption: TrackMapCopy.suggestionCaption(kind: suggestion.kind, label: suggestion.label),
            time: DJFormat.time(suggestion.positionSeconds),
            isMuted: true,
            seekSeconds: suggestion.positionSeconds,
            cueId: nil,
            primary: Action(id: "accept", title: TrackMapCopy.accept, systemImage: "checkmark") { [weak self] in self?.accept(suggestion) },
            actions: actions
        )
    }

    var takenSlots: Set<Int> { Set(userCues.compactMap(\.hotCueIndex)) }

    func saveCue() {
        guard let trackId else { return }
        let cue = CuePoint(trackId: trackId, kind: .memory, positionMillis: CueTime.millis(fromSeconds: snapped(markTime)))
        replace([(cue.id, cue)], action: TrackMapCopy.saveCuePoint)
        selectedCueId = cue.id
    }

    func setHotCue(slot: Int) {
        guard let trackId else { return }
        let id = CuePoint.slotId(trackId: trackId, kind: .hotCue, hotCueIndex: slot)
        let existing = self.cue(id)
        let cue = CuePoint(
            trackId: trackId,
            kind: .hotCue,
            positionMillis: CueTime.millis(fromSeconds: snapped(markTime)),
            hotCueIndex: slot,
            createdAtMillis: existing?.createdAtMillis ?? CueTime.nowMillis()
        )
        replace([(cue.id, cue)], action: TrackMapCopy.hotCue(slot))
        selectedCueId = cue.id
    }

    func addLoop(bars: Double = 4) {
        guard let trackId else { return }
        let start = snapped(markTime)
        let barSeconds = grid.map { $0.beatPeriod * 4 } ?? 2
        let cue = CuePoint(
            trackId: trackId,
            kind: .loop,
            positionMillis: CueTime.millis(fromSeconds: start),
            endMillis: CueTime.millis(fromSeconds: start + barSeconds * bars)
        )
        replace([(cue.id, cue)], action: TrackMapCopy.addLoop)
        selectedCueId = cue.id
    }

    func setMix(_ role: MixRole) {
        guard let trackId else { return }
        let id = CuePoint.slotId(trackId: trackId, kind: role.kind, hotCueIndex: nil)
        let cue = CuePoint(
            trackId: trackId,
            kind: role.kind,
            positionMillis: CueTime.millis(fromSeconds: snapped(markTime)),
            label: role.storeLabel,
            createdAtMillis: self.cue(id)?.createdAtMillis ?? CueTime.nowMillis()
        )
        replace([(cue.id, cue)], action: role.title)
    }

    func move(_ cue: CuePoint) {
        var moved = cue
        let start = CueTime.millis(fromSeconds: snapped(markTime))
        if let end = cue.endMillis { moved.endMillis = start + (end - cue.positionMillis) }
        moved.positionMillis = start
        moved.origin = .user
        replace([(cue.id, moved)], action: TrackMapCopy.moveTo(markText))
    }

    func rename(_ cue: CuePoint, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = self.cue(cue.id), trimmed != current.label else { return }
        var renamed = current
        renamed.label = trimmed
        renamed.origin = .user
        replace([(cue.id, renamed)], action: TrackMapCopy.name)
    }

    func recolour(_ cue: CuePoint, to color: CueColor) {
        guard let current = self.cue(cue.id), color != current.color else { return }
        var updated = current
        updated.color = color
        updated.origin = .user
        replace([(cue.id, updated)], action: TrackMapCopy.colour)
    }

    func assign(_ cue: CuePoint, toSlot slot: Int?) {
        guard slot != cue.hotCueIndex else { return }
        let kind: CueKind = cue.kind == .loop ? .loop : (slot == nil ? .memory : .hotCue)
        let moved = CuePoint(
            trackId: cue.trackId,
            kind: kind,
            positionMillis: cue.positionMillis,
            endMillis: cue.endMillis,
            hotCueIndex: slot,
            label: cue.label,
            color: kind == .memory ? .memory : (kind == .loop ? cue.color : (cue.hotCueIndex != nil ? cue.color : nil)),
            createdAtMillis: cue.createdAtMillis,
            promotedFrom: cue.promotedFrom
        )
        var changes: [(String, CuePoint?)] = []
        if moved.id != cue.id { changes.append((cue.id, nil)) }
        changes.append((moved.id, moved))
        replace(changes, action: TrackMapCopy.type)
        if selectedCueId == cue.id { selectedCueId = moved.id }
        if editingCueId == cue.id { editingCueId = moved.id }
    }

    func delete(_ cue: CuePoint) {
        replace([(cue.id, nil)], action: cue.kind == .mixIn || cue.kind == .mixOut ? TrackMapCopy.clear : TrackMapCopy.delete)
        if selectedCueId == cue.id { selectedCueId = nil }
        if editingCueId == cue.id { editingCueId = nil }
    }

    func deleteSelected() {
        guard let cue = selectedCue else { return }
        delete(cue)
    }

    func accept(_ suggestion: CueSuggestion, asHotCue: Bool = false) {
        let slot = asHotCue ? board.freeHotSlot() : nil
        if asHotCue, slot == nil { return }
        let cue = suggestion.promoted(asKind: slot == nil ? nil : .hotCue, hotCueIndex: slot, writerId: "")
        replace([(cue.id, cue)], action: TrackMapCopy.accept)
    }

    func dismiss(_ suggestion: CueSuggestion) {
        guard isEditable else { return }
        let store = store
        pendingWrites += 1
        Task {
            await store.dismiss(suggestion)
            await self.afterEdit()
        }
        registerUndo(TrackMapCopy.dismiss) { model in
            MainActor.assumeIsolated { model.undismiss(suggestion) }
        }
    }

    private func undismiss(_ suggestion: CueSuggestion) {
        let store = store
        pendingWrites += 1
        Task {
            await store.undismiss(suggestionId: suggestion.id)
            await self.afterEdit()
        }
        registerUndo(TrackMapCopy.dismiss) { model in
            MainActor.assumeIsolated { model.dismiss(suggestion) }
        }
    }

    private func replace(_ changes: [(String, CuePoint?)], action: String) {
        guard isEditable, !changes.isEmpty else { return }
        let previous: [(String, CuePoint?)] = changes.reversed().map { id, _ in (id, cue(id)) }
        let store = store
        pendingWrites += 1
        Task {
            for (id, cue) in changes {
                if let cue { await store.upsert(cue) } else { await store.delete(cueId: id) }
            }
            await self.afterEdit()
        }
        registerUndo(action) { model in
            MainActor.assumeIsolated { model.replace(previous, action: action) }
        }
    }

    private func afterEdit() async {
        await board.refresh()
        pendingWrites = max(0, pendingWrites - 1)
        await onEdit?()
    }
}
