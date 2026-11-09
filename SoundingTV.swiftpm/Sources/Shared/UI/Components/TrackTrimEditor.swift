import SwiftUI

enum TrackTrimFormat {
    static func string(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    static func seconds(from text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            if index < parts.count - 1, value != value.rounded() { return nil }
            total = total * 60 + value
        }
        return total
    }
}

#if !os(tvOS)
struct TrackTrimEditor: View {
    let track: Track
    let onPreview: ((TimeInterval) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var waveforms = WaveformService.shared
    @State private var start: TimeInterval
    @State private var end: TimeInterval
    @State private var original: TrackTrim?

    init(track: Track, initial: TrackTrim? = nil, onPreview: ((TimeInterval) -> Void)? = nil) {
        self.track = track
        self.onPreview = onPreview
        let range = initial.map { TrackTrimStore.range($0, duration: track.duration) }
            ?? TrackTrimStore.shared.effectiveRange(for: track)
        _start = State(initialValue: range.lowerBound)
        _end = State(initialValue: track.duration > 0 ? range.upperBound : 0)
        _original = State(initialValue: TrackTrimStore.shared.trim(for: track.id))
    }

    private var duration: TimeInterval { max(track.duration, 0) }
    private var waveform: Waveform? { waveforms.state(for: track.id).waveform }
    private var draft: TrackTrim { TrackTrim(start: start, end: end) }
    private var isUntrimmed: Bool { draft.normalised(duration: duration) == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TrackTrimWaveform(
                        state: waveforms.state(for: track.id),
                        duration: duration,
                        start: $start,
                        end: $end
                    )
                    .frame(height: 96)
                } footer: {
                    Text("Plays \(TrackTrimFormat.string(max(0, end - start))) of \(track.formattedDuration).")
                        .monospacedDigit()
                }

                Section {
                    TrackTrimTimeField(title: "Start", value: $start, bounds: 0...max(0, end - TrackTrim.minimumLength))
                    TrackTrimTimeField(title: "End", value: $end, bounds: min(duration, start + TrackTrim.minimumLength)...duration)
                }

                Section {
                    #if os(macOS)
                    HStack {
                        previewButtons
                        Spacer()
                        editButtons
                    }
                    #else
                    previewButtons
                    editButtons
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Start & End")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        TrackTrimStore.shared.setTrim(original, for: track.id, duration: duration)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440)
        #endif
        .onAppear { waveforms.load(track) }
    }

    @ViewBuilder
    private var previewButtons: some View {
        Button {
            preview(at: start)
        } label: {
            Label("Preview Start", systemImage: "play")
        }
        Button {
            preview(at: max(start, end - 5))
        } label: {
            Label("Preview End", systemImage: "play")
        }
    }

    @ViewBuilder
    private var editButtons: some View {
        Button {
            suggest()
        } label: {
            Label("Suggest", systemImage: "wand.and.stars")
        }
        .disabled(waveform == nil)
        Button(role: .destructive) {
            start = 0
            end = duration
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .disabled(isUntrimmed)
    }

    private func save() {
        TrackTrimStore.shared.setTrim(draft, for: track.id, duration: duration)
    }

    private func preview(at position: TimeInterval) {
        save()
        if let onPreview {
            onPreview(position)
        } else {
            Task { await PlayerService.shared.beginPreviewPlayback(of: track, at: position) }
        }
    }

    private func suggest() {
        guard let waveform else { return }
        let suggestion = TrackTrimSuggestion.silence(in: waveform.samples, duration: duration)
        let range = TrackTrimStore.range(suggestion, duration: duration)
        start = range.lowerBound
        end = range.upperBound
    }
}

private struct TrackTrimTimeField: View {
    let title: String
    @Binding var value: TimeInterval
    let bounds: ClosedRange<TimeInterval>

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isFocused)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
        }
        .onAppear { text = TrackTrimFormat.string(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = TrackTrimFormat.string(newValue) }
        }
    }

    private func commit() {
        if let parsed = TrackTrimFormat.seconds(from: text) {
            value = min(bounds.upperBound, max(bounds.lowerBound, parsed))
        }
        text = TrackTrimFormat.string(value)
    }
}

private struct TrackTrimWaveform: View {
    let state: WaveformState
    let duration: TimeInterval
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                bars(width: width, height: proxy.size.height)
                handle(for: $start, width: width, height: proxy.size.height, label: "Start") { candidate in
                    min(max(0, candidate), end - TrackTrim.minimumLength)
                }
                handle(for: $end, width: width, height: proxy.size.height, label: "End") { candidate in
                    max(min(duration, candidate), start + TrackTrim.minimumLength)
                }
            }
        }
    }

    @ViewBuilder
    private func bars(width: CGFloat, height: CGFloat) -> some View {
        switch state {
        case .ready(let waveform):
            let count = max(1, Int(width / 3))
            let samples = waveform.displayBars(count: count)
            Canvas { context, size in
                let barWidth = size.width / CGFloat(count)
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * barWidth
                    let time = duration * Double(index) / Double(count)
                    let barHeight = max(2, CGFloat(sample) * size.height)
                    let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: max(1, barWidth - 1), height: barHeight)
                    let kept = time >= start && time <= end
                    context.fill(Path(rect), with: .style(kept ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)))
                }
            }
            .accessibilityHidden(true)
        case .failed:
            Rectangle()
                .fill(.quaternary)
                .frame(height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        case .pending, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func handle(
        for value: Binding<TimeInterval>,
        width: CGFloat,
        height: CGFloat,
        label: String,
        constrain: @escaping (TimeInterval) -> TimeInterval
    ) -> some View {
        Capsule()
            .fill(.tint)
            .frame(width: 4, height: height)
            .frame(width: 44, height: height)
            .contentShape(Rectangle())
            .offset(x: x(for: value.wrappedValue, width: width) - 22)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                    .onChanged { gesture in
                        guard width > 0 else { return }
                        value.wrappedValue = constrain(Double(gesture.location.x / width) * duration)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(TrackTrimFormat.string(value.wrappedValue))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value.wrappedValue = constrain(value.wrappedValue + 1)
                case .decrement: value.wrappedValue = constrain(value.wrappedValue - 1)
                @unknown default: break
                }
            }
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
    }
}

#if DEBUG
enum TrackTrimFixture {
    static var isRequested: Bool {
        VisualFixtures.isEnabled && ProcessInfo.processInfo.environment["SOUNDING_TV_TRACK_TRIM"] == "1"
    }

    @MainActor
    static func prepare() -> Track {
        let track = VisualFixtures.tracks[0]
        WaveformService.shared.installFixture(waveform(), for: track.id)
        return track
    }

    static func draft(for track: Track) -> TrackTrim? {
        TrackTrimSuggestion.silence(in: waveform().samples, duration: track.duration)
    }

    static func waveform(count: Int = 600) -> Waveform {
        let lead = count * 8 / 100
        let tail = count * 90 / 100
        let samples: [Float] = (0..<count).map { index in
            guard index >= lead, index < tail else { return 0.01 }
            let t = Float(index)
            let body = 0.35 + 0.45 * abs(sinf(t * 0.37)) * (0.6 + 0.4 * sinf(t * 0.045))
            let swell = min(1, Float(index - lead) / 30) * min(1, Float(tail - index) / 30)
            return min(1, body * swell)
        }
        return Waveform(samples: samples)
    }
}

struct TrackTrimFixtureSheet: ViewModifier {
    @State private var track: Track?

    func body(content: Content) -> some View {
        content
            .sheet(item: $track) { track in
                TrackTrimEditor(track: track, initial: TrackTrimFixture.draft(for: track))
            }
            .task {
                guard TrackTrimFixture.isRequested, track == nil else { return }
                try? await Task.sleep(for: .seconds(1))
                track = TrackTrimFixture.prepare()
            }
    }
}
#endif
#endif
