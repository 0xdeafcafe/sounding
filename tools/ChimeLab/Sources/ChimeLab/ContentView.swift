import Charts
import SwiftUI

struct ContentView: View {
    @Bindable var model: LabModel

    var body: some View {
        HStack(spacing: 0) {
            DesignForm(model: model)
                .frame(minWidth: 520, idealWidth: 560)
            Divider()
            ListenForm(model: model)
                .frame(minWidth: 480, idealWidth: 540)
        }
        .frame(minWidth: 1_000, minHeight: 760)
    }
}

// MARK: - Design

struct DesignForm: View {
    @Bindable var model: LabModel

    private var presetBinding: Binding<String> {
        Binding(
            get: { model.presetName ?? "Custom" },
            set: { name in if let preset = LabPreset.all.first(where: { $0.name == name }) { model.apply(preset) } }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: presetBinding) {
                    ForEach(LabPreset.all) { Text($0.name).tag($0.name) }
                    if model.presetName == nil {
                        Divider()
                        Text("Custom").tag("Custom")
                    }
                }
            }
            DataNotesSection(design: $model.design)
            CarrierSection(design: $model.design)
            BedSection(design: $model.design)
            CueSection(title: "Beep", cue: $model.design.beep)
            CueSection(title: "Ping", cue: $model.design.ping)
            CueSection(title: "Success", cue: $model.design.success)
        }
        .formStyle(.grouped)
    }
}

struct DataNotesSection: View {
    @Binding var design: ChimeDesign

    private var baseBinding: Binding<ChimeLayerDesign.Base> {
        Binding(get: { design.layer.base }, set: { design.layer = ChimeLayerDesign(base: $0) })
    }

    var body: some View {
        let layer = design.layer.layer
        let on = design.voice.enabled
        Section {
            Toggle("Play data notes", isOn: $design.voice.enabled)
            Group {
                ValueSlider("Level", value: $design.voice.levelDB, in: ChimeVoiceSettings.silentDB...6) { $0 <= ChimeVoiceSettings.silentDB ? "−∞ dB" : Format.dB($0) }
                Picker("Layer", selection: baseBinding) {
                    ForEach(ChimeLayerDesign.Base.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Stepper(value: $design.layer.lowestMIDI, in: 40...88) {
                    LabeledContent("Lowest note", value: "\(Format.note(design.layer.lowestMIDI)) · \(Format.hz(layer.tones.first ?? 0))")
                }
                Stepper(value: $design.layer.rangeSemitones, in: (layer.tones.count - 1)...60) {
                    LabeledContent("Range", value: "\(design.layer.rangeSemitones) semitones, up to \(Format.hz(layer.tones.last ?? 0))")
                }
                ValueSlider("Note length", value: $design.layer.noteLength, in: 0.05...0.25, step: 0.002) { "\(Int(($0 * 1_000).rounded())) ms" }
                Picker("Timbre", selection: $design.voice.timbre) {
                    ForEach(ChimeVoiceSettings.Timbre.allCases, id: \.self) { Text(Format.timbre($0)).tag($0) }
                }
                ValueSlider("Attack", value: $design.voice.attack, in: 0.001...0.08) { "\(Int(($0 * 1_000).rounded())) ms" }
                ValueSlider("Release", value: $design.voice.release, in: 0.02...0.5) { "\(Int(($0 * 1_000).rounded())) ms" }
                LogSlider("Low-pass", value: $design.voice.lowpass, in: 200...20_000) { $0 >= 20_000 ? "Off" : Format.hz($0) }
                ValueSlider("High-note tilt", value: $design.voice.tilt, in: 0...1.2) { String(format: "%.2f", $0) }
                ValueSlider("Glide", value: $design.voice.glide, in: -0.03...0.03, step: 0.001) { String(format: "%+.1f%%", $0 * 100) }
                ValueSlider("Stereo spread", value: $design.voice.spread, in: 0...1) { String(format: "%.2f", $0) }
                Toggle("Overtones inside the data band", isOn: $design.voice.overtonesInBand)
                Toggle("Follow the pulse", isOn: $design.voice.followsPulse)
            }
            .disabled(!on)
        } header: {
            Text("Data Notes")
        } footer: {
            Text(design.layer.isHeardByShippingDecoder
                 ? "The app listens for this layer today."
                 : "The app doesn’t listen for this layer yet. Check Decode uses a decoder that matches it, so the app would need the same change.")
        }
    }
}

struct CarrierSection: View {
    @Binding var design: ChimeDesign

    private var ultrasonicOnly: Binding<Bool> {
        Binding(
            get: { !design.voice.enabled && design.carrier },
            set: { only in
                design.voice.enabled = !only
                if only { design.carrier = true }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Ultrasonic carrier", isOn: $design.carrier)
            ValueSlider("Level", value: $design.carrierLevelDB, in: -24...12) {
                "\(Format.dB($0)) · \(Format.dBFS(Double(ChimeSynth.carrierLevel) * pow(10, $0 / 20)))"
            }
            .disabled(!design.carrier)
            Toggle("Data only in ultrasonic", isOn: ultrasonicOnly)
        } header: {
            Text("Ultrasonic Carrier")
        } footer: {
            Text("The carrier carries the whole code by itself, at 18.2–19.4 kHz, which most adults can’t hear. With data only in ultrasonic, sign-in depends on the TV speaker playing 18–19 kHz.")
        }
    }
}

struct BedSection: View {
    @Binding var design: ChimeDesign

    private var styleBinding: Binding<ChimeBedDesign.Style> {
        Binding(get: { design.bed.style }, set: { design.bed = ChimeBedDesign(style: $0) })
    }

    var body: some View {
        let bass = design.bed.style.isBass
        let ornamented = [.toll, .pad].contains(design.bed.style)
        let ceiling = design.audibleData ? Format.ceiling(design.layer.layer) : 1_500
        Section {
            Picker("Style", selection: styleBinding) {
                ForEach(ChimeBedDesign.Style.allCases, id: \.self) { Text(Format.bed($0)).tag($0) }
            }
            Group {
                Stepper(value: $design.bed.rootMIDI, in: 21...52) {
                    LabeledContent("Root note", value: "\(Format.note(design.bed.rootMIDI)) · \(Format.hz(440 * pow(2, Double(design.bed.rootMIDI - 69) / 12)))")
                }
                ValueSlider("Slide range", value: $design.bed.slideRange, in: 0...2.5) { String(format: "×%.2f", $0) }
                ValueSlider("Slide time", value: $design.bed.slideTime, in: 0.4...1.6) { String(format: "×%.2f", $0) }
                ValueSlider("Wobble rate", value: $design.bed.wobbleRate, in: 0...10) { String(format: "%.2f Hz", $0) }
                ValueSlider("Wobble depth", value: $design.bed.wobbleDepth, in: 0...2) { String(format: "%.2f oct", $0) }
                ValueSlider("Throb rate", value: $design.bed.throbRate, in: 0...12) { String(format: "%.2f Hz", $0) }
                ValueSlider("Throb depth", value: $design.bed.throbDepth, in: 0...1) { String(format: "%.2f", $0) }
                ValueSlider("Drive", value: $design.bed.drive, in: 1...6) { String(format: "%.2f", $0) }
                ValueSlider("Grain", value: $design.bed.grain, in: 0...1) { String(format: "%.2f", $0) }
                ValueSlider("Phaser rate", value: $design.bed.phaserRate, in: 0...4) { String(format: "%.2f Hz", $0) }
                ValueSlider("Phaser depth", value: $design.bed.phaserDepth, in: 0...1) { String(format: "%.2f", $0) }
                LogSlider("Low-pass", value: $design.bed.lowpass, in: 40...1_500) { Format.hz($0) }
                LabeledContent("Ceiling", value: "\(Format.hz(ceiling)), \(design.audibleData ? "kept under the data notes" : "no data notes to avoid")")
            }
            .disabled(!bass)
            if ornamented {
                Toggle("Closing flourish", isOn: $design.bed.flourish)
            }
            ValueSlider("Level", value: $design.bed.levelDB, in: -24...12) { Format.dB($0) }
                .disabled(design.bed.style == .none)
        } header: {
            Text("Bass Bed")
        } footer: {
            if ornamented {
                Text("Toll and Pad keep their original voicing; only the level and the closing flourish change.")
            }
        }
    }
}

struct CueSection: View {
    let title: String
    @Binding var cue: ChimeCueDesign

    var body: some View {
        Section(title) {
            Picker("Style", selection: $cue.style) {
                Text("None").tag(ChimeSynth.Style?.none)
                Divider()
                ForEach(ChimeSynth.Style.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
            }
            Group {
                Stepper(value: $cue.pitch, in: -12...12, step: 1) {
                    LabeledContent("Pitch", value: cue.pitch == 0 ? "As designed" : String(format: "%+.0f semitones", cue.pitch))
                }
                ValueSlider("Level", value: $cue.levelDB, in: -24...12) { Format.dB($0) }
            }
            .disabled(cue.style == nil)
        }
    }
}

// MARK: - Listen

struct ListenForm: View {
    @Bindable var model: LabModel

    var body: some View {
        Form {
            Section("Listen") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Play Handshake") { model.play(.handshake) }
                        Button("Play Beep") { model.play(.beep) }
                        Button("Play Ping") { model.play(.ping) }
                    }
                    HStack {
                        Button("Play Success") { model.play(.success) }
                        Button("Play Whole Sequence") { model.play(.sequence) }
                        Button("Stop", role: .cancel) { model.stop() }
                    }
                }
            }
            Section {
                SpectrumChart(points: model.spectrum, data: model.design.audibleData ? model.design.layer.layer.tones : [], carrier: model.design.carrier)
                    .frame(height: 220)
            } header: {
                Text("Last Render")
            } footer: {
                Text("Blue band: data notes. Purple band: carrier. \(model.lastClip.rawValue), \(String(format: "%.1f", model.lastDuration)) s, peak \(Format.dBFS(Double(model.lastPeak))).")
            }
            DecodeSection(model: model)
            Section {
                HStack {
                    Button("Copy Settings") { model.copySettings() }
                    Button("Save WAV…") { model.saveWAV() }
                }
                if let status = model.status {
                    Text(status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Share")
            } footer: {
                Text("Copy Settings puts one JSON block on the clipboard. Save WAV writes every clip and the settings into a new folder.")
            }
        }
        .formStyle(.grouped)
    }
}

struct SpectrumChart: View {
    let points: [SpectrumPoint]
    let data: [Double]
    let carrier: Bool

    var body: some View {
        if points.isEmpty {
            ContentUnavailableView("Nothing Rendered Yet", systemImage: "waveform", description: Text("Play a clip to see where its energy sits."))
        } else {
            Chart {
                if let low = data.first, let high = data.last {
                    RectangleMark(xStart: .value("Hz", low), xEnd: .value("Hz", high), yStart: .value("dB", -100), yEnd: .value("dB", 0))
                        .foregroundStyle(.blue.opacity(0.12))
                }
                if carrier {
                    RectangleMark(xStart: .value("Hz", 18_100), xEnd: .value("Hz", 19_500), yStart: .value("dB", -100), yEnd: .value("dB", 0))
                        .foregroundStyle(.purple.opacity(0.15))
                }
                ForEach(points) { point in
                    AreaMark(x: .value("Hz", point.frequency), yStart: .value("dB", -100), yEnd: .value("dB", point.level))
                        .foregroundStyle(.secondary.opacity(0.35))
                    LineMark(x: .value("Hz", point.frequency), y: .value("dB", point.level))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: 20...23_000, type: .log)
            .chartYScale(domain: -100...0)
            .chartXAxis {
                AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hz = value.as(Double.self) { Text(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))") } }
                }
            }
            .chartYAxis { AxisMarks(values: [-80, -60, -40, -20, 0]) }
            .padding(.trailing, 8)
        }
    }
}

struct DecodeSection: View {
    @Bindable var model: LabModel

    var body: some View {
        let rows = model.checkRows
        Section {
            HStack {
                Button("Check Decode") { model.checkDecode() }
                    .disabled(model.checking)
                if model.checking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.checkedDesign != nil, model.checkedDesign != model.design, !model.checking {
                    Text("Settings changed since the check").foregroundStyle(.secondary)
                }
            }
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Channel")
                        Text("Notes")
                        Text("Carrier")
                        Text("Either")
                    }
                    .font(.headline)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.channel)
                            Text(Format.rate(row.notes, row.trials)).monospacedDigit()
                            Text(Format.rate(row.carrier, row.trials)).monospacedDigit()
                            Text(Format.rate(row.either, row.trials)).monospacedDigit().bold()
                        }
                    }
                }
                Text(Format.verdict(rows))
            }
        } header: {
            Text("Decode")
        } footer: {
            Text("Runs the app’s real decoder on fresh codes, 16 trials per channel. The handshake plays over the carrier, as on the TV.")
        }
    }
}

// MARK: - Controls

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: { new in value = step.map { (new / $0).rounded() * $0 } ?? new }), in: range).labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 128, alignment: .trailing)
            }
        }
    }
}

struct LogSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        ValueSlider(title, value: Binding(get: { log10(min(max(value, range.lowerBound), range.upperBound)) }, set: { value = (pow(10, $0)).rounded() }),
                    in: log10(range.lowerBound)...log10(range.upperBound)) { format(pow(10, $0).rounded()) }
    }
}

enum Format {
    static func dB(_ value: Double) -> String { value == 0 ? "0 dB" : String(format: "%+.1f dB", value) }

    static func dBFS(_ level: Double) -> String { level <= 0 ? "−∞ dBFS" : String(format: "%.1f dBFS", 20 * log10(level)) }

    static func hz(_ value: Double) -> String { value >= 1_000 ? String(format: "%.2f kHz", value / 1_000) : String(format: "%.0f Hz", value) }

    static func note(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(names[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    static func ceiling(_ layer: ChimeLayer) -> Double {
        layer.lowestFrequency * (1 - layer.pooling) / (layer.timeScales.max() ?? 1) * 0.9 * 0.75
    }

    static func timbre(_ timbre: ChimeVoiceSettings.Timbre) -> String {
        switch timbre {
        case .sine: "Sine"
        case .softSine: "Soft sine"
        case .filteredSaw: "Filtered saw"
        case .bell: "Bell"
        case .mutedPluck: "Muted pluck"
        }
    }

    static func bed(_ style: ChimeBedDesign.Style) -> String {
        switch style {
        case .slide: "Slide"
        case .pulse: "Pulse"
        case .click: "Click"
        case .drone: "Drone"
        case .omen: "Omen (throbbing drone)"
        case .abyss: "Abyss (sliding sub)"
        case .grit: "Grit (grainy pulse)"
        case .toll: "Toll (Eclipse)"
        case .pad: "Pad (Ripple)"
        case .none: "None"
        }
    }

    static func rate(_ value: Int?, _ trials: Int) -> String {
        guard let value else { return "Off" }
        return "\(Int((Double(value) / Double(trials) * 100).rounded()))%"
    }

    static func verdict(_ rows: [LabCheckRow]) -> String {
        let passing = rows.filter { $0.either == $0.trials }.map(\.channel)
        let failing = rows.filter { $0.either < $0.trials / 2 }.map(\.channel)
        if rows.allSatisfy({ $0.either == 0 }) { return "This setting can’t be decoded at all." }
        if failing.isEmpty, passing.count == rows.count { return "Decodes every time on every channel." }
        if failing.isEmpty { return "Decodes on every channel, with some misses." }
        return "Can’t be decoded reliably through: \(failing.joined(separator: ", "))."
    }
}
