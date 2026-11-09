import AppKit
import SwiftUI

struct DJPlanAxis {
    let lower: Double
    let upper: Double
    let width: CGFloat

    init(timeline: DJPlanTimeline, width: CGFloat) {
        lower = -4
        upper = max(28, timeline.endBar + 3)
        self.width = max(1, width)
    }

    func x(_ bar: Double) -> CGFloat {
        CGFloat((bar - lower) / (upper - lower)) * width
    }

    func bar(_ x: CGFloat) -> Double {
        lower + Double(x / width) * (upper - lower)
    }
}

struct DJPlanEditor: View {
    let model: DJPlanModel
    let timeline: DJPlanTimeline
    @State private var drag: (id: DJPlanPointID, bar: Double)?

    static let labelWidth: CGFloat = 124

    private var shown: DJPlanTimeline {
        guard let drag else { return timeline }
        return timeline.applying(drag.id, bar: drag.bar)
    }

    private var topIsIncoming: Bool {
        if let deck = model.deck(for: timeline.incoming.id) { return deck == .a }
        if let deck = model.deck(for: timeline.outgoing.id) { return deck == .b }
        return true
    }

    private func deck(for role: DJPlanRole) -> MixEngine.Deck {
        let incomingIsA = topIsIncoming
        switch role {
        case .incoming: return incomingIsA ? .a : .b
        case .outgoing: return incomingIsA ? .b : .a
        }
    }

    var body: some View {
        let shown = self.shown
        VStack(alignment: .leading, spacing: 10) {
            header
            DJPlanWaveformPair(timeline: shown, top: topIsIncoming ? .incoming : .outgoing, deck: deck(for:), samples: model.waveforms)
                .frame(height: 210)
            VStack(spacing: 8) {
                ForEach(shown.lanes) { lane in
                    DJPlanLaneRow(
                        model: model,
                        timeline: shown,
                        base: timeline,
                        lane: lane,
                        deck: deck(for:),
                        drag: $drag
                    )
                    .frame(height: Self.height(lane))
                }
            }
            if let snap = model.snapNote, snap.key == model.selectedKey {
                snapBar(snap.note)
            }
            footer(shown)
        }
    }

    static func height(_ lane: DJPlanLane) -> CGFloat {
        switch lane {
        case .loop: return 40
        case .fade: return 88
        case .bass: return 56
        case .filter: return 88
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    titleGroup(liveness: true)
                    Spacer(minLength: 8)
                    actions(compact: false)
                }
                HStack(spacing: 10) {
                    titleGroup(liveness: false)
                    Spacer(minLength: 8)
                    actions(compact: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleGroup(liveness: true)
                    actions(compact: true)
                }
            }
            Text(model.editSummary(timeline))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func titleGroup(liveness showsLiveness: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(timeline.outgoing.title) → \(timeline.incoming.title)")
                .font(.title2.bold())
                .lineLimit(1)
                .fixedSize()
            Menu {
                ForEach(moveChoices, id: \.self) { kind in
                    Button {
                        model.choose(move: kind)
                    } label: {
                        if kind == timeline.moveKind {
                            Label(DJPlanMoves.name(kind), systemImage: "checkmark")
                        } else {
                            Text(DJPlanMoves.name(kind))
                        }
                    }
                }
            } label: {
                Text(timeline.auto.moveName.capitalized)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(!model.selectedIsEditable)
            if showsLiveness {
                Text(liveness).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private func actions(compact: Bool) -> some View {
        let record = model.selectedRecord
        let editable = model.selectedIsEditable
        return HStack(spacing: 8) {
            if record.edit.count > 0 {
                Text(record.edit.count == 1 ? "1 edit" : "\(record.edit.count) edits").foregroundStyle(.secondary).fixedSize()
            }
            Group {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!record.canUndo)
                    .labelStyle(.titleAndIcon)
                Button(compact ? "Revert" : "Revert to Auto") { model.revert() }
                    .disabled(record.edit.isEmpty || !editable)
                    .help("Revert to Auto")
                if model.actions.skip != nil {
                    Button(compact ? "Skip" : "Skip \(timeline.incoming.title)") { model.skip() }
                        .disabled(!editable)
                        .help("Skip \(timeline.incoming.title)")
                }
                Button(compact ? "Preview" : "Preview in Headphones", systemImage: "headphones") { model.togglePreview() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.headphones.isAvailable)
                    .help(model.headphones.isAvailable ? "Plays this mix in your headphones only" : "Choose a headphone output in Decks View to preview")
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .background {
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!record.canRedo)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var moveChoices: [MixMove.Kind] {
        var kinds = DJPlanMoves.choices
        if let current = timeline.moveKind, !kinds.contains(current) { kinds.insert(current, at: 0) }
        return kinds
    }

    private var liveness: String {
        guard let key = model.selectedKey, let index = model.crate.joins.firstIndex(of: key) else { return "" }
        switch model.joinState(index) {
        case .played: return "Played"
        case .live: return "Live now · edit it from the strip"
        case .upcoming:
            if index == model.crate.lockedCount - 1, let starts = model.live?.nextStartsIn {
                return "Not live yet · starts in \(DJPlanFormat.time(starts))"
            }
            return "Not live yet"
        }
    }

    // MARK: Footer

    private func snapBar(_ note: DJPlanSnapNote) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(note.text)
            Spacer()
            Button("Undo") { model.undoSnap() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DJPlanPalette.join.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DJPlanPalette.join.opacity(0.5), lineWidth: 0.5))
    }

    private func footer(_ shown: DJPlanTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    legend
                    Spacer(minLength: 8)
                    checks(shown)
                }
                VStack(alignment: .leading, spacing: 6) {
                    legend
                    checks(shown)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text("Edits save with the crate. Nothing here changes the live mix.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendLine(dashed: false, color: DJPlanPalette.a, label: "A")
            legendLine(dashed: true, color: DJPlanPalette.b, label: "B")
            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 10, height: 10).overlay(Circle().strokeBorder(DJPlanPalette.you, lineWidth: 2).padding(-2))
                Text("Yours")
            }
            Text(model.refusal ?? "Snaps to the beat · ⌥ drag moves freely")
                .foregroundStyle(model.refusal == nil ? Color.secondary : Color.primary)
        }
        .fixedSize()
    }

    private func checks(_ shown: DJPlanTimeline) -> some View {
        HStack(spacing: 12) {
            ForEach(shown.checks) { check in
                HStack(spacing: 4) {
                    Image(systemName: check.passed ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(check.passed ? DJPlanPalette.auto : Color.yellow)
                    Text(check.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(check.passed ? "Passes" : "Fails")
            }
        }
        .fixedSize()
    }

    private func legendLine(dashed: Bool, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 22, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.2, dash: dashed ? [6, 4] : []))
            .frame(width: 22, height: 8)
            Text(label)
        }
    }
}
