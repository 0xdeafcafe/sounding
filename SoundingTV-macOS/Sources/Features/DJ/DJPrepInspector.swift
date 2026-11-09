import SwiftUI

struct DJPrepInspector: View {
    @ObservedObject var model: MacPrepModel
    @State private var bpmText = ""
    @State private var labelText = ""
    @State private var startText = ""
    @State private var endText = ""

    var body: some View {
        if let detail = model.detail, let row = model.selectedRow {
            VStack(spacing: 0) {
                Form {
                    gridSection(detail, row: row)
                    if let cue = model.selectedCue { cueSection(cue, detail: detail) }
                    startEndSection(detail)
                    analysisSection(detail, row: row)
                    memorySection(detail)
                }
                .formStyle(.grouped)
                .disabled(!row.access.canEdit)
                Divider()
                DJUSBPanel(model: model)
                    .padding(16)
            }
            .onAppear { syncFields() }
            .onChange(of: model.detail?.grid) { _, _ in syncFields() }
            .onChange(of: model.selectedCueId) { _, _ in syncFields() }
            .onChange(of: model.trim) { _, _ in syncFields() }
            .onChange(of: model.detail?.trackId) { _, _ in syncFields() }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func syncFields() {
        bpmText = model.editableGrid.map { String(format: "%.2f", $0.bpm) } ?? ""
        labelText = model.selectedCue?.label ?? ""
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

    // MARK: Beat grid

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
                    Button { model.nudge(byMillis: PrepGridEditor.nudgeStepMillis) } label: { Label("Nudge Later", systemImage: "chevron.right") }
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

    // MARK: Cue

    private func cueSection(_ cue: CuePoint, detail: MacPrepModel.Detail) -> some View {
        Section(cueTitle(cue)) {
            TextField("Name", text: $labelText)
                .onSubmit { model.updateSelectedCue(label: labelText) }
            LabeledContent("Position", value: position(cue.positionSeconds, detail: detail))
                .monospacedDigit()
            if cue.hotCueIndex != nil {
                LabeledContent("Colour") {
                    HStack(spacing: 6) {
                        ForEach(Array(CueColor.hotCuePalette.enumerated()), id: \.offset) { index, color in
                            Button {
                                model.updateSelectedCue(color: color)
                            } label: {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 14, height: 14)
                                    .padding(2)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: cue.color == color ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.colourNames[index])
                            .accessibilityAddTraits(cue.color == color ? .isSelected : [])
                        }
                    }
                }
            }
            if cue.kind == .hotCue || cue.kind == .memory || cue.kind == .loop {
                Picker("Type", selection: Binding(
                    get: { cue.hotCueIndex ?? -1 },
                    set: { model.assignSelectedCue(toSlot: $0 < 0 ? nil : $0) }
                )) {
                    Text(cue.kind == .loop ? "Loop" : "Memory Cue").tag(-1)
                    ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { slot in
                        Text("Hot Cue \(CuePoint.slotLetter(slot))").tag(slot)
                    }
                }
            }
            HStack {
                Button("Move to Cursor") { model.updateSelectedCue(moveToCursor: true) }
                Spacer()
                Button("Delete", role: .destructive) { model.deleteSelectedCue() }
            }
        }
    }

    static let colourNames = ["Green", "Orange", "Yellow", "Blue", "Cyan", "Pink", "Purple", "White"]

    private func position(_ seconds: TimeInterval, detail: MacPrepModel.Detail) -> String {
        var text = Self.precise(seconds)
        if let grid = detail.grid {
            let downbeats = grid.downbeatMillis(throughMillis: CueTime.millis(fromSeconds: seconds) + 1)
            if !downbeats.isEmpty { text += " · bar \(downbeats.count)" }
        }
        return text
    }

    private func cueTitle(_ cue: CuePoint) -> String {
        switch cue.kind {
        case .hotCue: return "Selected Cue · \(CuePoint.slotLetter(cue.hotCueIndex ?? 0))"
        case .loop: return cue.hotCueIndex.map { "Selected Loop · \(CuePoint.slotLetter($0))" } ?? "Selected Loop"
        case .memory: return "Selected Memory Cue"
        case .mixIn: return "Mix In"
        case .mixOut: return "Mix Out"
        }
    }

    // MARK: Start and end

    private func startEndSection(_ detail: MacPrepModel.Detail) -> some View {
        Section {
            LabeledContent("Start") {
                TextField("Start", text: $startText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .onSubmit { if let value = TrackTrimFormat.seconds(from: startText) { model.setTrim(start: value) } }
            }
            LabeledContent("End") {
                TextField("End", text: $endText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .onSubmit { if let value = TrackTrimFormat.seconds(from: endText) { model.setTrim(end: value) } }
            }
            HStack {
                Button("Start at Cursor") { model.setTrim(start: model.cursorSeconds) }
                Button("End at Cursor") { model.setTrim(end: model.cursorSeconds) }
            }
            .controlSize(.small)
        } header: {
            Text("Start & End")
        } footer: {
            Text("Every device and Auto Mix play only this part.")
        }
    }

    // MARK: Analysis

    private func analysisSection(_ detail: MacPrepModel.Detail, row: MacPrepModel.Row) -> some View {
        Section("Music Analysis") {
            LabeledContent("Key", value: keyText(detail))
            LabeledContent("Energy", value: (detail.prep?.energy?.value ?? row.energy).map { "\($0) of 10" } ?? "–")
            LabeledContent("Vocals", value: vocalsText(detail))
            LabeledContent("Phrases", value: phrasesText(detail))
        }
    }

    private func keyText(_ detail: MacPrepModel.Detail) -> String {
        guard let key = detail.prep?.key?.value else { return "–" }
        return key.original.isEmpty || key.original == key.camelot ? key.camelot : "\(key.camelot) · \(key.original)"
    }

    private func vocalsText(_ detail: MacPrepModel.Detail) -> String {
        guard let phrases = detail.prep?.phrases?.value, let grid = detail.grid, !phrases.isEmpty else { return "–" }
        let vocal = phrases.enumerated().filter { $0.element.mood?.lowercased().contains("vocal") == true }
        guard let first = vocal.first else { return "None found" }
        let downbeats = grid.downbeatMillis(throughMillis: CueTime.millis(fromSeconds: detail.durationSeconds))
        func bar(_ millis: Int64) -> Int { max(1, downbeats.filter { $0 <= millis }.count) }
        let lastIndex = vocal.last?.offset ?? first.offset
        let end = lastIndex + 1 < phrases.count ? phrases[lastIndex + 1].startMillis : CueTime.millis(fromSeconds: detail.durationSeconds)
        return "Bars \(bar(first.element.startMillis))–\(bar(end))"
    }

    private func phrasesText(_ detail: MacPrepModel.Detail) -> String {
        guard let phrases = detail.prep?.phrases?.value, !phrases.isEmpty else { return "–" }
        return "\(phrases.count)"
    }

    // MARK: Memory cues

    private func memorySection(_ detail: MacPrepModel.Detail) -> some View {
        let memory = detail.cues.filter { $0.hotCueIndex == nil }.sorted { $0.positionMillis < $1.positionMillis }
        return Section("Memory Cues") {
            if memory.isEmpty && detail.suggestions.isEmpty {
                Text("Press M to drop a memory cue at the cursor.")
                    .foregroundStyle(.secondary)
            }
            ForEach(memory) { cue in
                Button {
                    model.selectedCueId = cue.id
                    model.cursorSeconds = cue.positionSeconds
                } label: {
                    LabeledContent {
                        Text(TrackTrimFormat.string(cue.positionSeconds)).monospacedDigit()
                    } label: {
                        Label {
                            Text(memoryName(cue))
                        } icon: {
                            Image(systemName: "arrowtriangle.down.fill").foregroundStyle(cue.color.color)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(detail.suggestions) { suggestion in
                LabeledContent {
                    HStack(spacing: 6) {
                        Button("Accept") { model.accept(suggestion) }
                        Button("Dismiss") { model.dismiss(suggestion) }
                            .buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                } label: {
                    Label {
                        Text(suggestion.label)
                    } icon: {
                        Image(systemName: "arrowtriangle.down").foregroundStyle(.secondary)
                    }
                }
                .help("Listeners keep jumping back to \(TrackTrimFormat.string(suggestion.positionSeconds))")
            }
        }
    }

    private func memoryName(_ cue: CuePoint) -> String {
        if !cue.label.isEmpty { return cue.label }
        switch cue.kind {
        case .mixIn: return "Mix In"
        case .mixOut: return "Mix Out"
        case .loop: return "Loop"
        default: return "Memory Cue"
        }
    }
}

struct DJUSBPanel: View {
    @ObservedObject var model: MacPrepModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume?.name ?? "USB Stick", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                if let volume {
                    Text("\(volume.formatName) · \(MacUSBExportModel.byteString(volume.availableBytes)) free")
                        .font(.callout)
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
            Text(status)
                .font(.callout)
                .foregroundStyle(MacSecondaryStyle())
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Export to USB…") { model.showsUSBExport = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.exportableCount == 0)
                Text("⇧⌘E")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var volume: MacUSBVolume? { model.volumes.first }

    private var status: String {
        var parts = ["\(model.exportableCount) \(model.exportableCount == 1 ? "track" : "tracks") ready"]
        if model.ledger.lastExportMillis == 0 {
            parts.append("not exported yet")
        } else if model.changedSinceExport > 0 {
            parts.append("\(model.changedSinceExport) changed since last export")
        } else {
            parts.append("up to date")
        }
        if model.streamingCount > 0 { parts.append("streamed tracks aren’t exported") }
        return parts.joined(separator: " · ")
    }
}
