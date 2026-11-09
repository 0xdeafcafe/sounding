import SwiftUI

struct DJPrepEditor: View {
    @ObservedObject var model: MacPrepModel
    let context: DJDeckContext
    @FocusState private var focused: Bool
    @State private var zoomBase: TimeInterval?

    var body: some View {
        if let detail = model.detail, let row = model.selectedRow {
            VStack(alignment: .leading, spacing: 10) {
                header(detail, row: row)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.playheadSeconds == nil)) { _ in
                    VStack(spacing: 8) {
                        DJPrepOverview(detail: detail, window: detailRange(detail), cursor: model.cursorSeconds, playhead: model.playheadSeconds, trim: model.trim) { seconds in
                            model.cursorSeconds = seconds
                            focused = true
                        }
                        .frame(height: 74)
                        DJPrepZoom(detail: detail, range: detailRange(detail), cursor: model.cursorSeconds, playhead: model.playheadSeconds, selectedCueId: model.selectedCueId) { seconds in
                            model.cursorSeconds = seconds
                            focused = true
                        } onSelectCue: { id in
                            model.selectedCueId = id
                            focused = true
                        }
                        .frame(height: 196)
                        .gesture(MagnifyGesture()
                            .onChanged { value in
                                let base = zoomBase ?? model.zoomWindow
                                zoomBase = base
                                model.zoomWindow = min(64, max(2, base / value.magnification))
                            }
                            .onEnded { _ in zoomBase = nil })
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(phases: .down, action: handle)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Waveform")
                .accessibilityValue("Cursor at \(DJFormat.time(model.cursorSeconds))")
                .accessibilityAdjustableAction { direction in
                    step(direction == .increment ? 1 : -1)
                }
                DJHotCuePads(detail: detail, selectedCueId: model.selectedCueId, enabled: row.access.canEdit) { slot, cue in
                    if let cue {
                        model.selectedCueId = cue.id
                        model.cursorSeconds = cue.positionSeconds
                    } else {
                        model.setHotCue(slot: slot)
                    }
                    focused = true
                }
                DJShortcutHints()
                footer(detail, row: row)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .disabled(false)
        } else {
            ContentUnavailableView("No Track Selected", systemImage: "waveform", description: Text("Choose a track to set its grid and cues."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func detailRange(_ detail: MacPrepModel.Detail) -> ClosedRange<TimeInterval> {
        DJPrepWindow.range(center: model.playheadSeconds ?? model.cursorSeconds, window: model.zoomWindow, duration: detail.durationSeconds)
    }

    private func header(_ detail: MacPrepModel.Detail, row: MacPrepModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(detail.title)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Text([row.artist, row.access == .local ? row.fileFormat : (row.access == .streams ? "Streams from SoundCloud" : nil)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
            Spacer()
            if !row.access.canEdit {
                Label("Auto Mix only · Go+ unlocks decks", systemImage: "cloud")
                    .foregroundStyle(.secondary)
            }
            Button {
                model.togglePlay()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play from the cursor (Space)")
            .disabled(!row.access.canLoad)
        }
    }

    private var isPlaying: Bool { model.playheadSeconds != nil && PlayerService.shared.isPlaying }

    private func footer(_ detail: MacPrepModel.Detail, row: MacPrepModel.Row) -> some View {
        let stick = model.volumes.first?.name ?? "your stick"
        let text: String
        switch row.access {
        case .local: text = "Cues and grid saved to \(detail.title) on every device, and written to \(stick) on the next export."
        case .streams: text = "Cues and grid saved to \(detail.title) on every device. Streamed tracks aren’t exported."
        case .autoMixOnly: text = "Auto Mix uses these cues. Go+ unlocks editing for SoundCloud tracks."
        }
        return Label(text, systemImage: "checkmark")
            .font(.callout)
            .foregroundStyle(MacSecondaryStyle())
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .space {
            model.togglePlay()
            return .handled
        }
        if press.key == .leftArrow || press.key == .rightArrow {
            let direction: Double = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.option) {
                model.nudge(byMillis: Int64(direction) * PrepGridEditor.nudgeStepMillis)
            } else {
                step(direction)
            }
            return .handled
        }
        if press.key == .delete || press.key == .deleteForward {
            model.deleteSelectedCue()
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }
        let character = press.characters.lowercased()
        if let digit = Int(character), (1...CuePoint.hotCueSlotCount).contains(digit) {
            model.setHotCue(slot: digit - 1)
            return .handled
        }
        switch character {
        case "m": model.addMemoryCue()
        case "l": model.addLoop()
        case "d": model.setDownbeat()
        case "t": model.tap()
        case "=", "+": model.zoomWindow = max(2, model.zoomWindow / 1.5)
        case "-": model.zoomWindow = min(64, model.zoomWindow * 1.5)
        default: return .ignored
        }
        return .handled
    }

    private func step(_ direction: Double) {
        guard let detail = model.detail else { return }
        let beat = (detail.grid?.bpm).map { 60 / max(1, $0) } ?? 0.5
        model.cursorSeconds = min(detail.durationSeconds, max(0, model.snapped(model.cursorSeconds) + direction * beat))
    }
}

// MARK: Waveforms

enum DJPrepWindow {
    static func range(center: TimeInterval, window: TimeInterval, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        let window = min(window, max(1, duration))
        let lower = min(max(0, center - window / 2), max(0, duration - window))
        return lower...(lower + window)
    }
}

enum DJPrepWaveform {
    static func color(_ cue: CueColor, opacity: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(cue.red) / 255, Float(cue.green) / 255, Float(cue.blue) / 255, opacity)
    }

    static func overlays(_ detail: MacPrepModel.Detail) -> [MetalWaveformOverlay] {
        detail.cues.map { cue in
            if cue.kind == .loop, let end = cue.endSeconds, end > cue.positionSeconds {
                return MetalWaveformOverlay(id: cue.id, kind: .loop(cue.positionSeconds...end), color: color(cue.color))
            }
            return MetalWaveformOverlay(id: cue.id, kind: .cue(cue.positionSeconds), color: color(cue.color))
        }
    }

    static func source(_ detail: MacPrepModel.Detail) -> MetalWaveformSource? {
        MetalWaveformSourceCache.shared.envelope(id: detail.trackId, samples: detail.envelope, duration: detail.durationSeconds)
    }

    static func grid(_ detail: MacPrepModel.Detail) -> MetalWaveformBeatGrid? {
        guard let grid = detail.grid, grid.bpm > 0 else { return nil }
        let first = grid.downbeatMillis(throughMillis: CueTime.millis(fromSeconds: min(detail.durationSeconds, 60))).first
            ?? grid.segments.first?.startMillis ?? 0
        return MetalWaveformBeatGrid(bpm: grid.bpm, firstBeatSeconds: CueTime.seconds(fromMillis: first))
    }

    static func hotCues(_ detail: MacPrepModel.Detail) -> [CuePoint] {
        detail.cues.filter { $0.hotCueIndex != nil }.sorted { $0.positionMillis < $1.positionMillis }
    }
}

struct DJPrepOverview: View {
    let detail: MacPrepModel.Detail
    let window: ClosedRange<TimeInterval>
    let cursor: TimeInterval
    let playhead: TimeInterval?
    let trim: TrackTrim?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(1, detail.durationSeconds)
            let x = { (t: TimeInterval) in CGFloat(t / duration) * width }
            let cues = DJPrepWaveform.hotCues(detail)
            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    ForEach(cues) { cue in
                        DJCueFlag(cue: cue, showsLabel: false)
                            .fixedSize()
                            .offset(x: min(max(0, x(cue.positionSeconds) - 1), width - 16))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .topLeading)
                ZStack(alignment: .topLeading) {
                    if let source = DJPrepWaveform.source(detail) {
                        MetalWaveformView(
                            source: source,
                            timeline: .range(0...duration, playhead: playhead ?? cursor),
                            grid: nil,
                            overlays: DJPrepWaveform.overlays(detail),
                            style: .blue
                        )
                    } else {
                        Rectangle().fill(.quaternary).frame(height: 1).frame(maxHeight: .infinity)
                    }
                    if let trim {
                        let range = trim.playableRange(duration: duration)
                        Rectangle().fill(.black.opacity(0.55)).frame(width: x(range.lowerBound))
                        Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, width - x(range.upperBound))).offset(x: x(range.upperBound))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.primary.opacity(0.7), lineWidth: 1)
                        .frame(width: max(4, x(window.upperBound) - x(window.lowerBound)))
                        .offset(x: x(window.lowerBound))
                }
                .frame(maxHeight: .infinity)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        let end = index + 1 < cues.count ? cues[index + 1].positionSeconds : duration
                        Rectangle()
                            .fill(cue.color.color)
                            .frame(width: max(1, x(end) - x(cue.positionSeconds) - 2))
                            .offset(x: x(cue.positionSeconds))
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0 else { return }
                onSeek(duration * min(1, max(0, value.location.x / width)))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Track overview")
    }
}

struct DJPrepZoom: View {
    let detail: MacPrepModel.Detail
    let range: ClosedRange<TimeInterval>
    let cursor: TimeInterval
    let playhead: TimeInterval?
    let selectedCueId: String?
    let onSeek: (TimeInterval) -> Void
    let onSelectCue: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = max(0.001, range.upperBound - range.lowerBound)
            let x = { (t: TimeInterval) in CGFloat((t - range.lowerBound) / span) * width }
            ZStack(alignment: .topLeading) {
                if let source = DJPrepWaveform.source(detail) {
                    MetalWaveformView(
                        source: source,
                        timeline: .range(range, playhead: playhead),
                        grid: DJPrepWaveform.grid(detail),
                        overlays: DJPrepWaveform.overlays(detail),
                        style: .blue
                    )
                    .padding(.top, 22)
                } else {
                    ContentUnavailableView("Waveform Loading", systemImage: "waveform")
                }
                ForEach(bars, id: \.number) { bar in
                    Text("\(bar.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MacSecondaryStyle())
                        .offset(x: x(bar.seconds) + 3, y: 3)
                }
                ForEach(detail.cues.filter { range.contains($0.positionSeconds) }) { cue in
                    DJCueFlag(cue: cue, showsLabel: true, selected: cue.id == selectedCueId)
                        .offset(x: x(cue.positionSeconds), y: 24)
                        .onTapGesture { onSelectCue(cue.id) }
                }
                Rectangle()
                    .fill(Color.scAccent)
                    .frame(width: 2)
                    .offset(x: x(cursor) - 1)
                    .opacity(range.contains(cursor) ? 1 : 0)
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        Spacer()
                        gridBadge
                    }
                    .padding(.top, 30)
                    Spacer()
                    HStack {
                        Text("Pinch or press + and − to zoom · drag to scrub")
                            .font(.callout)
                            .foregroundStyle(MacSecondaryStyle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
            }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0 else { return }
                onSeek(range.lowerBound + span * min(1, max(0, value.location.x / width)))
            })
        }
    }

    @ViewBuilder
    private var gridBadge: some View {
        if let grid = detail.grid {
            HStack(spacing: 4) {
                if grid.locked { Image(systemName: "lock.fill").imageScale(.small) }
                Text(["Grid \(String(format: "%.2f", grid.bpm))", detail.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        } else {
            Text("No grid yet · press D on a downbeat")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }

    private var bars: [(number: Int, seconds: TimeInterval)] {
        guard let grid = detail.grid else { return [] }
        let downbeats = grid.downbeatMillis(throughMillis: CueTime.millis(fromSeconds: range.upperBound))
        let span = range.upperBound - range.lowerBound
        let stride = span > 40 ? 4 : 1
        return downbeats.enumerated().compactMap { index, millis in
            let seconds = CueTime.seconds(fromMillis: millis)
            guard range.contains(seconds), index % stride == 0 else { return nil }
            return (index + 1, seconds)
        }
    }
}

struct DJCueFlag: View {
    let cue: CuePoint
    var showsLabel: Bool
    var selected = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(cue.color.color, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1.5) }
            }
            .fixedSize()
            .accessibilityLabel("\(cue.kind.displayName) \(text), \(DJFormat.time(cue.positionSeconds))")
            .accessibilityAddTraits(.isButton)
    }

    private var text: String {
        let letter: String
        if let slot = cue.hotCueIndex {
            letter = CuePoint.slotLetter(slot)
        } else {
            switch cue.kind {
            case .mixIn: letter = "IN"
            case .mixOut: letter = "OUT"
            case .loop: letter = "LP"
            default: letter = "M"
            }
        }
        return showsLabel && !cue.label.isEmpty ? "\(letter) \(cue.label)" : letter
    }
}

// MARK: Pads and hints

struct DJHotCuePads: View {
    let detail: MacPrepModel.Detail
    let selectedCueId: String?
    let enabled: Bool
    let onTap: (Int, CuePoint?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { slot in
                let cue = detail.cues.first { $0.hotCueIndex == slot }
                Button {
                    onTap(slot, cue)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(CuePoint.slotLetter(slot)).fontWeight(.bold)
                            Spacer()
                            if let cue { Text(DJFormat.time(cue.positionSeconds)).monospacedDigit() }
                        }
                        .font(.caption)
                        .foregroundStyle(cue.map { AnyShapeStyle($0.color.color) } ?? AnyShapeStyle(.secondary))
                        Text(cue.map { $0.label.isEmpty ? "Cue" : $0.label } ?? "+")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(cue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((cue?.color.color ?? .clear).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(cue.map { $0.color.color.opacity(cue?.id == selectedCueId ? 1 : 0.55) } ?? Color.secondary.opacity(0.3), lineWidth: cue?.id == selectedCueId ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!enabled && cue == nil)
                .help(cue == nil ? "Set Hot Cue \(CuePoint.slotLetter(slot)) at the cursor (\(slot + 1))" : "Go to Hot Cue \(CuePoint.slotLetter(slot))")
                .accessibilityLabel(cue == nil ? "Set hot cue \(CuePoint.slotLetter(slot))" : "Hot cue \(CuePoint.slotLetter(slot)), \(cue?.label ?? ""), \(DJFormat.time(cue?.positionSeconds ?? 0))")
            }
        }
    }
}

struct DJShortcutHints: View {
    private let hints: [(keys: String, label: String)] = [
        ("← →", "Beat"), ("⌥← →", "Nudge grid"), ("D", "Set downbeat"), ("T", "Tap"),
        ("1–8", "Hot cue"), ("M", "Memory cue"), ("L", "Loop"), ("⌘Z", "Undo"), ("⌘3", "Plan"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(hints)
            row(Array(hints.prefix(6)))
            row(Array(hints.prefix(4)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcuts: arrows move a beat, option arrows nudge the grid, D sets the downbeat, T taps the tempo, 1 to 8 set hot cues, M adds a memory cue, L adds a loop")
    }

    private func row(_ items: [(keys: String, label: String)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.keys) { hint in
                HStack(spacing: 5) {
                    Text(hint.keys)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
                    Text(hint.label)
                }
                .font(.callout)
                .foregroundStyle(MacSecondaryStyle())
                .fixedSize()
            }
        }
    }
}
