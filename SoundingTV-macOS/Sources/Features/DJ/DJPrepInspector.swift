import SwiftUI

struct DJPrepInspector: View {
    @ObservedObject var model: MacPrepModel
    @State private var bpmText = ""
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var laneFocused: Bool

    var body: some View {
        if let detail = model.detail, let row = model.selectedRow {
            let trackMap = model.trackMap
            Form {
                Section {
                    MacPrepLane(model: model, laneFocused: $laneFocused)
                }
                Group {
                    gridSection(detail, row: row)
                    if let cue = trackMap.selectedCue {
                        TrackMapCueEditor(model: trackMap, cue: cue)
                    }
                    startEndSection(detail)
                    TrackMapSections(model: trackMap) { row in
                        TrackMapStandardRow(model: trackMap, row: row)
                    } pads: {
                        TrackMapPadGrid(model: trackMap)
                    }
                }
                .disabled(!row.access.canEdit)
            }
            .formStyle(.grouped)
            .onAppear {
                syncFields()
                laneFocused = true
            }
            .onChange(of: model.detail?.grid) { _, _ in syncFields() }
            .onChange(of: trackMap.editingCueId) { _, id in
                guard let id else { return }
                model.selectedCueId = id
                trackMap.editingCueId = nil
            }
            .onChange(of: model.trim) { _, _ in syncFields() }
            .onChange(of: model.detail?.trackId) { _, _ in
                syncFields()
                laneFocused = true
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func syncFields() {
        bpmText = model.editableGrid.map { String(format: "%.2f", $0.bpm) } ?? ""
        if let detail = model.detail {
            let range = TrackTrimStore.range(model.trim, duration: detail.durationSeconds)
            startText = DJPrepInspector.precise(range.lowerBound)
            endText = DJPrepInspector.precise(range.upperBound)
        }
    }

    static func precise(_ seconds: TimeInterval) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%d:%02d.%03d", millis / 60_000, (millis / 1000) % 60, millis % 1000)
    }

    private func gridSection(_ detail: MacPrepModel.Detail, row: MacPrepModel.Row) -> some View {
        Section {
            LabeledContent("Tempo") {
                HStack(spacing: 4) {
                    TextField("BPM", text: $bpmText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 70)
                        .onSubmit {
                            if let value = Double(bpmText.replacingOccurrences(of: ",", with: ".")) { model.setBPM(value) }
                            laneFocused = true
                        }
                    Text("BPM").foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { detail.grid?.locked ?? false }, set: { _ in model.toggleLock() })) {
                Text("Lock Grid")
            }
            .disabled(model.editableGrid == nil)
            HStack(spacing: 6) {
                Button("Set Downbeat") { model.setDownbeat() }
                    .help("Set the downbeat at the cursor (D)")
                Spacer()
                Button("Tap") { model.tap() }
                    .help("Tap the beat four times to set the tempo (T)")
            }
            HStack(spacing: 6) {
                ControlGroup {
                    Button { model.nudge(byMillis: -PrepGridEditor.nudgeStepMillis) } label: { Label("Nudge Earlier", systemImage: "chevron.left") }
                        .help("Nudge the grid earlier (⌥←)")
                    Button { model.nudge(byMillis: PrepGridEditor.nudgeStepMillis) } label: { Label("Nudge Later", systemImage: "chevron.right") }
                        .help("Nudge the grid later (⌥→)")
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                Spacer()
                ControlGroup {
                    Button("½×") { model.halveTempo() }
                        .accessibilityLabel("Halve tempo")
                    Button("2×") { model.doubleTempo() }
                        .accessibilityLabel("Double tempo")
                }
                .fixedSize()
            }
            .disabled(model.editableGrid == nil)
        } header: {
            HStack {
                Text("Beat Grid")
                Spacer()
                Text(gridStatus(detail, row: row))
                    .foregroundStyle(row.analysis == .done ? Color.green : Color.secondary)
                    .font(.callout)
            }
        } footer: {
            Text(gridFooter(detail))
        }
    }

    private func gridStatus(_ detail: MacPrepModel.Detail, row: MacPrepModel.Row) -> String {
        switch row.analysis {
        case .analysing: return "Analysing…"
        case .missing: return "Not analysed"
        case .done:
            switch detail.gridSource {
            case .user?: return "Set by you"
            case .rekordbox?: return "From rekordbox"
            default: return "Analysed"
            }
        }
    }

    private func gridFooter(_ detail: MacPrepModel.Detail) -> String {
        guard let grid = detail.grid else { return "Play the track and press D on a downbeat to start a grid." }
        var parts: [String] = [grid.isVariable ? "Tempo changes in this track" : "Measured on every bar"]
        if let confidence = detail.confidence { parts.append("\(Int((confidence * 100).rounded()))% sure") }
        if !grid.isVariable { parts.append("no drift") }
        return parts.joined(separator: " · ")
    }

    private func startEndSection(_ detail: MacPrepModel.Detail) -> some View {
        Section {
            LabeledContent("Start") {
                TextField("Start", text: $startText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .onSubmit {
                        if let value = TrackTrimFormat.seconds(from: startText) { model.setTrim(start: value) }
                        laneFocused = true
                    }
            }
            LabeledContent("End") {
                TextField("End", text: $endText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .onSubmit {
                        if let value = TrackTrimFormat.seconds(from: endText) { model.setTrim(end: value) }
                        laneFocused = true
                    }
            }
            HStack {
                Button("Start at Cursor") { model.setTrim(start: model.markSeconds) }
                Button("End at Cursor") { model.setTrim(end: model.markSeconds) }
            }
            .controlSize(.small)
        } header: {
            Text("Start & End")
        } footer: {
            Text("Every device and Auto Mix play only this part.")
        }
    }
}

private struct MacPrepLane: View {
    @ObservedObject var model: MacPrepModel
    var laneFocused: FocusState<Bool>.Binding
    @ObservedObject private var player = PlayerService.shared

    private var trackMap: TrackMapModel { model.trackMap }

    private var isPlayingHere: Bool {
        player.isPlaying && player.currentTrack?.id == model.detail?.trackId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                TrackMapLane(model: trackMap, height: 64, style: .phone, highlightedId: trackMap.selectedCueId)
                    .padding(6)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard geo.size.width > 12 else { return }
                                trackMap.previewFraction((value.location.x - 6) / (geo.size.width - 12))
                                laneFocused.wrappedValue = true
                            }
                    )
            }
            .frame(height: 76 + (trackMap.phrases.isEmpty ? 0 : 8))
            .focusable()
            .focusEffectDisabled()
            .focused(laneFocused)
            .focusedValue(\.macPrepLane, model)
            .onKeyPress(phases: [.down, .repeat]) { press in
                MacPrepKeys.handle(press, model: model)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TrackMapCopy.timeline)
            .accessibilityValue(TrackMapCopy.timelineValue(trackMap.markText, of: trackMap.durationText))
            .accessibilityHint(TrackMapCopy.timelineHint)
            .accessibilityAdjustableAction { direction in
                trackMap.nudgePreview(by: direction == .increment ? trackMap.beatStep : -trackMap.beatStep)
            }

            TrackMapReadout(model: trackMap, showsPlayButton: false)
                .font(.callout)

            HStack(spacing: 8) {
                Button(isPlayingHere ? "Pause" : "Play", systemImage: isPlayingHere ? "pause.fill" : "play.fill") { model.togglePlay() }
                    .help(isPlayingHere ? "Pause (Space)" : "Play from the cursor (Space)")
                Spacer()
                Group {
                    Button(TrackMapCopy.addLoop, systemImage: "repeat") { trackMap.addLoop() }
                        .help("\(TrackMapCopy.addLoop) (L)")
                    Button(TrackMapCopy.saveCuePoint, systemImage: "plus") { trackMap.saveCue() }
                        .help("\(TrackMapCopy.save(at: trackMap.markText)) (M)")
                }
                .disabled(!(model.selectedRow?.access.canEdit ?? false))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .task(id: isPlayingHere) {
            while isPlayingHere, !Task.isCancelled {
                trackMap.objectWillChange.send()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

@MainActor
enum MacPrepKeys {
    static func handle(_ press: KeyPress, model: MacPrepModel) -> KeyPress.Result {
        if press.key == .leftArrow || press.key == .rightArrow, press.modifiers.contains(.option) {
            model.nudge(byMillis: press.key == .leftArrow ? -PrepGridEditor.nudgeStepMillis : PrepGridEditor.nudgeStepMillis)
            return .handled
        }
        if press.phase == .repeat {
            guard press.key == .leftArrow || press.key == .rightArrow, press.modifiers.isEmpty else { return .ignored }
            return MacTrackMapKeys.handle(press, model: model.trackMap)
        }
        if press.key == .space, press.modifiers.isEmpty {
            model.togglePlay()
            return .handled
        }
        if press.modifiers.isEmpty {
            switch press.characters.lowercased() {
            case "d":
                model.setDownbeat()
                return .handled
            case "t":
                model.tap()
                return .handled
            default:
                break
            }
        }
        return MacTrackMapKeys.handle(press, model: model.trackMap)
    }
}
