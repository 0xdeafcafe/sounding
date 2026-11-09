import SwiftUI

struct MacPrepStickView: View {
    @ObservedObject var stick: MacPrepStickModel
    let searchText: String

    var body: some View {
        if stick.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stick.rows.isEmpty {
            ContentUnavailableView("No Tracks", systemImage: "externaldrive", description: Text("This part of the stick has no tracks."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                table
                    .frame(minHeight: 160, maxHeight: .infinity)
                footer
                Divider()
                editor
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var table: some View {
        let rows = stick.visibleRows(matching: searchText)
        return Table(rows, selection: $stick.selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Time") { row in
                Text(row.timeText).monospacedDigit().foregroundStyle(MacSecondaryStyle())
            }
            .width(52)
            TableColumn("BPM") { row in
                Text(row.bpmText).monospacedDigit()
            }
            .width(78)
            TableColumn("Key") { row in
                Text(row.key ?? "–")
            }
            .width(44)
            TableColumn("Cues") { row in
                Text(row.cueCount.map { $0 == 0 ? "–" : "\($0)" } ?? "").monospacedDigit()
            }
            .width(44)
            TableColumn("Sounding") { row in
                Image(systemName: Self.symbol(for: row.outcome))
                    .foregroundStyle(row.matchedTrackId == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(Self.label(for: row.outcome))
            }
            .width(64)
        }
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rows.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
    }

    private var footer: some View {
        let rows = stick.visibleRows(matching: searchText)
        let minutes = Int((Double(rows.reduce(0) { $0 + $1.durationSeconds }) / 60).rounded())
        return Text("\(rows.count) \(rows.count == 1 ? "track" : "tracks"), \(minutes) \(minutes == 1 ? "minute" : "minutes")")
            .font(.footnote)
            .foregroundStyle(MacSecondaryStyle())
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    static func symbol(for outcome: MatchOutcome) -> String {
        switch outcome {
        case .matched:   return "checkmark.circle.fill"
        case .ambiguous: return "questionmark.circle"
        case .missing:   return "circle.dashed"
        }
    }

    static func label(for outcome: MatchOutcome) -> String {
        switch outcome {
        case .matched:   return "In Sounding"
        case .ambiguous: return "Several matches in Sounding"
        case .missing:   return "Not in Sounding"
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let detail = stick.detail {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(DJFormat.time(stick.cursorSeconds))
                        .font(.title3.monospacedDigit())
                    Text("of \(DJFormat.time(detail.durationSeconds))")
                        .foregroundStyle(MacSecondaryStyle())
                        .monospacedDigit()
                    Spacer()
                    Label(stick.volumeName, systemImage: "externaldrive")
                        .foregroundStyle(MacSecondaryStyle())
                }
                let window = DJPrepWindow.range(center: stick.cursorSeconds, window: 16, duration: detail.durationSeconds)
                DJPrepOverview(detail: detail, window: window, cursor: stick.cursorSeconds, playhead: nil, trim: nil) { seconds in
                    stick.cursorSeconds = seconds
                }
                .frame(height: 60)
                DJPrepZoom(detail: detail, range: window, cursor: stick.cursorSeconds, playhead: nil, selectedCueId: stick.selectedCueId) { seconds in
                    stick.cursorSeconds = seconds
                } onSelectCue: { id in
                    stick.selectedCueId = id
                    if let cue = detail.cues.first(where: { $0.id == id }) { stick.cursorSeconds = cue.positionSeconds }
                }
                .frame(height: 150)
                hotCues(detail)
            }
            .padding(14)
        } else {
            ContentUnavailableView("No Track Selected", systemImage: "waveform", description: Text("Choose a track to look at."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hotCues(_ detail: MacPrepModel.Detail) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { slot in
                let cue = detail.cues.first { $0.hotCueIndex == slot }
                HStack(spacing: 5) {
                    Circle()
                        .fill(cue.map { AnyShapeStyle($0.color.color) } ?? AnyShapeStyle(.quaternary))
                        .frame(width: 8, height: 8)
                    Text(CuePoint.slotLetter(slot))
                        .font(.callout.weight(.semibold))
                    if let cue {
                        Text(cue.label.isEmpty ? DJFormat.time(cue.positionSeconds) : cue.label)
                            .lineLimit(1)
                            .foregroundStyle(MacSecondaryStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(cue == nil ? "Hot cue \(CuePoint.slotLetter(slot)), empty" : "Hot cue \(CuePoint.slotLetter(slot)), \(DJFormat.time(cue?.positionSeconds ?? 0))")
            }
        }
    }
}

struct MacPrepStickInspector: View {
    @ObservedObject var stick: MacPrepStickModel

    var body: some View {
        if let detail = stick.detail, let track = stick.selectedTrack {
            Form {
                trackSection(track)
                gridSection(detail)
                cuesSection(detail)
                soundingSection()
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trackSection(_ track: DJStickTrack) -> some View {
        Section("Track") {
            LabeledContent("Artist", value: track.artist.isEmpty ? "–" : track.artist)
            if !track.album.isEmpty { LabeledContent("Album", value: track.album) }
            LabeledContent("Time", value: DJFormat.time(TimeInterval(track.durationSeconds)))
            LabeledContent("Key", value: track.keyName ?? "–")
        }
    }

    private func gridSection(_ detail: MacPrepModel.Detail) -> some View {
        Section("Beat Grid") {
            if let grid = detail.grid {
                LabeledContent("Tempo", value: String(format: "%.2f BPM", grid.bpm))
                if let first = grid.segments.first {
                    LabeledContent("First Beat", value: DJFormat.time(CueTime.seconds(fromMillis: first.startMillis)))
                }
                if grid.isVariable { LabeledContent("Tempo Changes", value: "\(grid.segments.count - 1)") }
            } else {
                Text("No beat grid on the stick")
                    .foregroundStyle(MacSecondaryStyle())
            }
        }
    }

    private func cuesSection(_ detail: MacPrepModel.Detail) -> some View {
        Section("Cue Points") {
            if detail.cues.isEmpty {
                Text("None on the stick")
                    .foregroundStyle(MacSecondaryStyle())
            }
            ForEach(detail.cues) { cue in
                Button {
                    stick.selectedCueId = cue.id
                    stick.cursorSeconds = cue.positionSeconds
                } label: {
                    LabeledContent {
                        Text(timeText(cue)).monospacedDigit()
                    } label: {
                        Label {
                            Text(title(cue))
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(cue.color.color)
                        }
                    }
                }
                .buttonStyle(.plain)
                .fontWeight(cue.id == stick.selectedCueId ? .semibold : .regular)
            }
        }
    }

    private func soundingSection() -> some View {
        let row = stick.selectedRow
        let matched = row?.matchedTrackId != nil
        return Section {
            LabeledContent("Sounding", value: row.map { MacPrepStickView.label(for: $0.outcome) } ?? "–")
            Button("Import Cues into Sounding") {
                Task { await stick.importSelected() }
            }
            .disabled(!matched || stick.importState == .working)
            if stick.matchedRows.count > 1 {
                Button("Import All \(stick.matchedRows.count) Matched Tracks") {
                    Task { await stick.importAllMatched() }
                }
                .disabled(stick.importState == .working)
            }
            switch stick.importState {
            case .idle:
                EmptyView()
            case .working:
                ProgressView().controlSize(.small)
            case .done(let tracks, let cues, let kept):
                Text(summary(tracks: tracks, cues: cues, kept: kept))
                    .foregroundStyle(MacSecondaryStyle())
            }
        } footer: {
            Text("Sounding only reads the stick. Your own cues and grids are never replaced.")
        }
    }

    private func summary(tracks: Int, cues: Int, kept: Int) -> String {
        if cues == 0, kept == 0 { return "Already up to date" }
        var text = cues == 1 ? "1 cue point imported" : "\(cues) cue points imported"
        if tracks > 1 { text += " from \(tracks) tracks" }
        if kept > 0 { text += ", \(kept) of yours kept" }
        return text
    }

    private func title(_ cue: CuePoint) -> String {
        switch cue.kind {
        case .hotCue: return "Hot Cue \(CuePoint.slotLetter(cue.hotCueIndex ?? 0))" + (cue.label.isEmpty ? "" : " · \(cue.label)")
        case .loop:   return (cue.hotCueIndex.map { "Hot Loop \(CuePoint.slotLetter($0))" } ?? "Loop") + (cue.label.isEmpty ? "" : " · \(cue.label)")
        case .memory: return cue.label.isEmpty ? "Memory Cue" : cue.label
        case .mixIn:  return "Mix In"
        case .mixOut: return "Mix Out"
        }
    }

    private func timeText(_ cue: CuePoint) -> String {
        var text = DJFormat.time(cue.positionSeconds)
        if let end = cue.endSeconds { text += "–" + DJFormat.time(end) }
        return text
    }
}
