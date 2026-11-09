import SwiftUI

// MARK: - Settings status

struct AnalysisLibraryStatusSection: View {
    @ObservedObject private var progress = AnalysisLibraryProgress.shared
    @ObservedObject private var work = AutomaticAnalysisStatus.shared

    private var isAnalysing: Bool {
        work.states.values.contains(.analysing)
    }

    private var status: AnalysisLibraryStatus {
        AnalysisStatusCopy.library(
            gate: progress.gate,
            device: .current,
            done: progress.done,
            total: progress.total,
            isAnalysing: isAnalysing,
            batch: progress.batch
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.message)
                if let detail = status.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if case .running(let done, let total) = progress.batch, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            #if !os(tvOS)
            if progress.isRunningAll {
                Button("Stop") { progress.stop() }
            } else if progress.canAnalyseAll {
                Button("Analyse All Now") { progress.analyseAll() }
            }
            #endif
        } header: {
            Text("BPM and Key")
        } footer: {
            #if !os(tvOS)
            Text("Analyse All Now runs until it’s done, even on battery. It stops if your \(DeviceClass.current.displayName) gets too warm.")
            #endif
        }
        .task { await progress.watch() }
    }
}

#if !os(tvOS)

// MARK: - Cells

enum TrackAnalysisValueKind: Sendable {
    case bpm
    case key
}

struct TrackAnalysisValueCell: View {
    let track: Track
    let kind: TrackAnalysisValueKind
    let summary: TrackAnalysisSummary?

    private var value: String? {
        switch kind {
        case .bpm: return TrackValueFormat.bpm(summary?.bpm)
        case .key: return TrackValueFormat.key(summary?.key)
        }
    }

    private var isEdited: Bool {
        switch kind {
        case .bpm: return summary?.bpm != nil && summary?.bpmProvenance == .stated
        case .key: return summary?.key != nil && summary?.keyProvenance == .stated
        }
    }

    var body: some View {
        if let value {
            HStack(spacing: 3) {
                Text(value)
                    .lineLimit(1)
                if isEdited {
                    TrackAnalysisEditedMark()
                }
            }
            .help(isEdited ? "Set by you" : (kind == .bpm ? "BPM" : "Key"))
        } else {
            TrackAnalysisPendingMark(track: track)
        }
    }
}

struct TrackAnalysisEditedMark: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Edited")
    }
}

struct TrackAnalysisPendingMark: View {
    let track: Track

    @ObservedObject private var work = AutomaticAnalysisStatus.shared

    private var state: AnalysisWorkState? { work.state(for: track.id) }

    private var isWorking: Bool {
        state == .analysing || state?.isQueued == true
    }

    private var willAnalyse: Bool {
        guard TrackTempoKey.isAnalysable(track) else { return false }
        switch state {
        case nil: return true
        case .queued?, .analysing?: return true
        case .failed?, .complete?, .notEligible?: return false
        }
    }

    var body: some View {
        let message = TrackTempoKey.pendingMessage(for: track)
        Group {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
            } else if willAnalyse {
                Image(systemName: "clock")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            } else {
                Text(TrackValueFormat.missing)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

// MARK: - Menu items

extension EnvironmentValues {
    @Entry var presentTrackTempoKey: (@MainActor (Track) -> Void)? = nil
}

struct TrackTempoKeyMenuItems: View {
    let track: Track
    var present: (@MainActor (Track) -> Void)? = nil

    @Environment(\.presentTrackTempoKey) private var environmentPresent
    @ObservedObject private var summaries = AnalysisSummaries.shared

    private var hasValues: Bool {
        guard let summary = summaries.summary(for: track) else { return false }
        return summary.bpm != nil || summary.key != nil
    }

    var body: some View {
        if let present {
            Button { present(track) } label: {
                Label("Tempo & Key…", systemImage: "metronome")
            }
        } else if let environmentPresent {
            Button { environmentPresent(track) } label: {
                Label("Tempo & Key…", systemImage: "metronome")
            }
        }
        if !hasValues, TrackTempoKey.isAnalysable(track) {
            Button { TrackTempoKey.analyseNow(track) } label: {
                Label("Analyse Now", systemImage: "waveform.badge.magnifyingglass")
            }
        }
    }
}

@MainActor
final class TrackTempoKeyPresenter: ObservableObject {
    static let shared = TrackTempoKeyPresenter()

    @Published var track: Track?

    func present(_ track: Track) { self.track = track }
}

extension View {
    func trackTempoKeySheet() -> some View {
        modifier(TrackTempoKeyPresenterSheet())
    }

    func trackTempoKeySheet(_ track: Binding<Track?>) -> some View {
        sheet(item: track) { track in
            TrackTempoKeySheet(track: track)
        }
        .environment(\.presentTrackTempoKey, { track.wrappedValue = $0 })
    }
}

private struct TrackTempoKeyPresenterSheet: ViewModifier {
    @ObservedObject private var presenter = TrackTempoKeyPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.track) { track in
            TrackTempoKeySheet(track: track)
        }
    }
}

// MARK: - Sheet

@MainActor
final class TrackTempoKeyModel: ObservableObject {
    let track: Track

    @Published var bpmText = ""
    @Published var key: CamelotKey?
    @Published var genreText = ""
    @Published private(set) var analysed: AnalysisFeatureSummary?
    @Published private(set) var manual: UserAnalysisCorrectionPayload?
    @Published private(set) var tapCount = 0
    @Published private(set) var isLoaded = false

    private var tapTempo = TapTempo()

    init(track: Track) {
        self.track = track
    }

    var bpmIsValid: Bool { ManualTempoKey.isValidBPMText(bpmText) }

    var hasManualTempoOrKey: Bool { manual?.bpm != nil || manual?.keyLabel.flatMap(CamelotKey.parse) != nil }

    var analysedText: String? {
        let parts = [
            analysed?.bpm.map { "\(ManualTempoKey.format($0)) BPM" },
            analysed?.key?.fullLabel,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func load() async {
        manual = await TrackTempoKey.manual(for: track)
        analysed = await TrackTempoKey.analysed(for: track)
        bpmText = manual?.bpm.map(ManualTempoKey.format) ?? ""
        key = manual?.keyLabel.flatMap(CamelotKey.parse)
        genreText = manual?.genre ?? ""
        isLoaded = true
    }

    func tap() {
        let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime)
        tapCount = tapTempo.count
        if let bpm { bpmText = ManualTempoKey.format(bpm) }
    }

    func save() async {
        let trimmedGenre = genreText.trimmingCharacters(in: .whitespacesAndNewlines)
        await TrackTempoKey.save(
            track,
            bpm: ManualTempoKey.parseBPM(bpmText),
            key: key,
            genre: trimmedGenre.isEmpty ? nil : trimmedGenre
        )
    }

    func resetToAnalysed() async {
        await TrackTempoKey.resetToAnalysed(track)
        await load()
    }

    func reloadAnalysed() async {
        analysed = await TrackTempoKey.analysed(for: track)
    }
}

struct TrackTempoKeySheet: View {
    @StateObject private var model: TrackTempoKeyModel
    @ObservedObject private var work = AutomaticAnalysisStatus.shared
    @Environment(\.dismiss) private var dismiss

    init(track: Track) {
        _model = StateObject(wrappedValue: TrackTempoKeyModel(track: track))
    }

    private var track: Track { model.track }

    private var isWorking: Bool {
        let state = work.state(for: track.id)
        return state == .analysing || state?.isQueued == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("BPM") {
                        HStack(spacing: 12) {
                            TextField("BPM", text: $model.bpmText, prompt: Text(model.analysed?.bpm.map(ManualTempoKey.format) ?? "Not Set"))
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .accessibilityLabel("BPM")
                            Button("Tap Tempo") { model.tap() }
                                .buttonStyle(.borderless)
                                .accessibilityHint("Tap four times or more in time with the music")
                        }
                    }
                    Picker("Key", selection: $model.key) {
                        Text(model.analysed?.key.map { "Analysed (\($0.label))" } ?? "Not Set")
                            .tag(CamelotKey?.none)
                        ForEach(CamelotKey.all, id: \.self) { key in
                            Text(key.fullLabel).tag(CamelotKey?.some(key))
                        }
                    }
                    LabeledContent("Genre") {
                        TextField("Genre", text: $model.genreText, prompt: Text(model.analysed?.genre ?? "Not Set"))
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if !model.bpmIsValid {
                        Text("Enter a BPM between 40 and 250.")
                    } else if model.tapCount > 0, model.tapCount < TapTempo.minimumTaps {
                        Text("Keep tapping: \(TapTempo.minimumTaps - model.tapCount) more.")
                    } else {
                        Text("Your values are used everywhere, including Auto Mix, and sync to your other devices.")
                    }
                }

                Section {
                    LabeledContent("Analysed") {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(model.analysedText ?? "Not Yet")
                                .monospacedDigit()
                        }
                    }
                    if TrackTempoKey.isAnalysable(track) {
                        Button("Analyse Now") { TrackTempoKey.analyseNow(track) }
                            .disabled(isWorking)
                    }
                    if model.hasManualTempoOrKey {
                        Button("Reset to Analysed") {
                            Task { await model.resetToAnalysed() }
                        }
                    }
                } footer: {
                    if model.isLoaded, model.analysed?.bpm == nil, model.analysed?.key == nil, !isWorking {
                        Text(TrackTempoKey.pendingMessage(for: track))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Tempo & Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save()
                            dismiss()
                        }
                    }
                    .disabled(!model.bpmIsValid || !model.isLoaded)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task {
            await model.load()
        }
        .onChange(of: work.state(for: track.id)) { _, state in
            guard state == .complete else { return }
            Task { await model.reloadAnalysed() }
        }
    }
}

#endif
