import SwiftUI

struct TrackMapSheet: View {
    @ObservedObject var model: TrackMapModel
    let isPlaying: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @ScaledMetric(relativeTo: .body) private var laneHeight: CGFloat = 72

    var body: some View {
        NavigationStack {
            TimelineView(.animation(minimumInterval: 1, paused: !isPlaying)) { _ in
                List {
                    Section {
                        timeline
                            .listRowInsets(EdgeInsets(top: Space.tight, leading: Space.base, bottom: Space.tight, trailing: Space.base))
                            .listRowBackground(Color.clear)
                    } header: {
                        Text(model.trackTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                            .lineLimit(2)
                    }

                    TrackMapSections(model: model) { row in
                        TrackMapStandardRow(model: model, row: row)
                    } pads: {
                        TrackMapPadGrid(model: model)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: Space.base, bottom: 0, trailing: Space.base))
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaBar(edge: .bottom) { footer }
            }
            .navigationTitle(TrackMapCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(item: editingBinding) { id in
                editor(id)
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: model.jumpCount) { _, _ in dismiss() }
    }

    private var editingBinding: Binding<String?> {
        Binding(get: { model.editingCueId }, set: { model.editingCueId = $0 })
    }

    @ViewBuilder
    private func editor(_ id: String) -> some View {
        if let cue = model.cue(id) {
            Form {
                TrackMapCueEditor(model: model, cue: cue)
            }
            .navigationTitle(TrackMapCopy.editTitle)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(TrackMapCopy.emptyTitle, systemImage: "bookmark")
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            GeometryReader { geo in
                TrackMapLane(model: model, height: laneHeight, style: laneStyle, highlightedId: model.selectedCueId)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard geo.size.width > 0 else { return }
                                model.previewFraction(value.location.x / geo.size.width)
                            }
                    )
            }
            .frame(height: laneHeight + (model.phrases.isEmpty ? 0 : 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TrackMapCopy.timeline)
            .accessibilityValue(TrackMapCopy.timelineValue(model.markText, of: model.durationText))
            .accessibilityHint(TrackMapCopy.timelineHint)
            .accessibilityAdjustableAction { direction in
                model.nudgePreview(by: direction == .increment ? 10 : -10)
            }

            TrackMapReadout(model: model)
                .font(.subheadline)
        }
    }

    private var laneStyle: SCWaveformStyle {
        let accent = NowPlayingPalette.shared.current.accent
        var style = SCWaveformStyle.phone
        style.playedShellColors = [accent]
        style.glowColor = accent
        return style
    }

    private var footer: some View {
        HStack(spacing: Space.tight) {
            Button(action: model.saveCue) {
                Label(TrackMapCopy.save(at: model.markText), systemImage: "plus")
                    .font(.headline)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Menu {
                Button(TrackMapCopy.addLoop, systemImage: "repeat", action: { model.addLoop() })
                ForEach(TrackMapModel.MixRole.allCases, id: \.self) { role in
                    Button(TrackMapCopy.setMix(role.title, at: model.markText), systemImage: "arrow.right.to.line") {
                        model.setMix(role)
                    }
                }
            } label: {
                Label(TrackMapCopy.options, systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.tight)
        .sensoryFeedback(.selection, trigger: model.cueCount)
    }
}

#if DEBUG
struct TrackMapSheetDemoView: View {
    @StateObject private var model = TrackMapDemo.makeModel()

    var body: some View {
        TrackMapSheet(model: model, isPlaying: false)
            .task { await TrackMapDemo.seed(model) }
    }
}
#endif
