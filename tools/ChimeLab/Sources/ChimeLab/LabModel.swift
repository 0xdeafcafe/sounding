import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor
final class LabPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Lab.sampleRate, channels: 2)!

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ stereo: ChimeStereo) {
        guard let buffer = Self.buffer(stereo, format: format) else { return }
        if !engine.isRunning { try? engine.start() }
        node.stop()
        node.scheduleBuffer(buffer, at: nil)
        node.play()
    }

    func stop() {
        node.stop()
    }

    nonisolated static func buffer(_ stereo: ChimeStereo, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard stereo.count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stereo.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(stereo.count)
        stereo.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: stereo.count) }
        stereo.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: stereo.count) }
        return buffer
    }
}

struct SpectrumPoint: Identifiable {
    let frequency: Double
    let level: Double
    var id: Double { frequency }
}

@MainActor
@Observable
final class LabModel {
    var design = LabPreset.all[0].design {
        didSet { if design != oldValue { designChanged() } }
    }
    var presetName: String? = LabPreset.all[0].name
    var spectrum: [SpectrumPoint] = []
    var lastClip: LabClip = .handshake
    var lastDuration = 0.0
    var lastPeak: Float = 0
    var rendering = false
    var checking = false
    var checkRows: [LabCheckRow] = []
    var checkedDesign: ChimeDesign?
    var status: String?

    private let player = LabPlayer()
    private var renderTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let code = Lab.previewCode()

    init() {
        refreshPreview()
    }

    func apply(_ preset: LabPreset) {
        design = preset.design
        presetName = preset.name
    }

    private func designChanged() {
        if let presetName, LabPreset.all.first(where: { $0.name == presetName })?.design != design { self.presetName = nil }
        refreshPreview()
    }

    private func refreshPreview() {
        previewTask?.cancel()
        let design = design
        let code = code
        let clip = lastClip
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await Self.renderOff(clip, design: design, code: code)
            guard !Task.isCancelled else { return }
            show(result, clip: clip)
        }
    }

    nonisolated private static func renderOff(_ clip: LabClip, design: ChimeDesign, code: ChimeCode) async -> (ChimeStereo, [SpectrumPoint]) {
        await Task.detached(priority: .userInitiated) {
            let stereo = Lab.render(clip, design: design, code: code)
            return (stereo, Lab.spectrum(stereo).map { SpectrumPoint(frequency: $0.frequency, level: $0.level) })
        }.value
    }

    private func show(_ result: (ChimeStereo, [SpectrumPoint]), clip: LabClip) {
        lastClip = clip
        spectrum = result.1
        lastDuration = Double(result.0.count) / Lab.sampleRate
        lastPeak = result.0.peak
    }

    func play(_ clip: LabClip) {
        renderTask?.cancel()
        rendering = true
        let design = design
        let code = code
        renderTask = Task {
            let result = await Self.renderOff(clip, design: design, code: code)
            rendering = false
            guard !Task.isCancelled else { return }
            show(result, clip: clip)
            player.play(result.0)
        }
    }

    func stop() {
        renderTask?.cancel()
        rendering = false
        player.stop()
    }

    func checkDecode() {
        checkTask?.cancel()
        checking = true
        let design = design
        checkTask = Task {
            let rows = await Task.detached(priority: .userInitiated) { Lab.check(design) }.value
            guard !Task.isCancelled else { return }
            checkRows = rows
            checkedDesign = design
            checking = false
        }
    }

    func copySettings() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Lab.json(design), forType: .string)
        status = "Settings copied. Paste them into the chat."
    }

    func saveWAV() {
        let panel = NSSavePanel()
        panel.title = "Save WAV Files"
        panel.message = "Choose a name for the folder. It will hold every clip and the settings."
        panel.nameFieldStringValue = "Sign-in Sound"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let design = design
        let code = code
        status = "Saving…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for clip in LabClip.allCases {
                        let name = clip.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".wav"
                        try Lab.wav(Lab.render(clip, design: design, code: code)).write(to: folder.appendingPathComponent(name))
                    }
                    try Lab.json(design).write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
                    return "Saved to \(folder.path)."
                } catch {
                    return "Couldn’t save: \(error.localizedDescription)"
                }
            }.value
            status = result
        }
    }
}
