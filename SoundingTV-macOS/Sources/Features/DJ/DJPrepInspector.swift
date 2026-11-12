import SwiftUI

struct DJPrepInspector: View {
    @ObservedObject var model: MacPrepModel
    @State private var bpmText = ""
    @State private var startText = ""
    @State private var endText = ""

    var body: some View {
        if let detail = model.detail, let row = model.selectedRow {
            let trackMap = model.trackMap
            VStack(spacing: 0) {
                Form {
                    gridSection(detail, row: row)
                    if let cue = trackMap.selectedCue {
                        TrackMapCueEditor(model: trackMap, cue: cue)
                    }
                    startEndSection(detail)
                    TrackMapSections(model: trackMap, showsPads: false) { row in
                        TrackMapStandardRow(model: trackMap, row: row)
                    } pads: {
                        EmptyView()
                    }
                }
                .formStyle(.grouped)
                .disabled(!row.access.canEdit)
                Divider()
                DJUSBPanel(model: model)
                    .padding(16)
            }
            .onAppear { syncFields() }
            .onChange(of: model.detail?.grid) { _, _ in syncFields() }
            .onChange(of: trackMap.editingCueId) { _, id in
                guard let id else { return }
                model.selectedCueId = id
                trackMap.editingCueId = nil
            }
            .onChange(of: model.trim) { _, _ in syncFields() }
            .onChange(of: model.detail?.trackId) { _, _ in syncFields() }
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
