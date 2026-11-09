import Foundation

enum PulseOnly {
    static func designs() -> [(slug: String, name: String, design: ChimeDesign)] {
        var unblended = ChimeSynth.Handshake.coded.design
        unblended.voice.followsPulse = false
        var unboosted = ChimeSynth.Handshake.coded.design
        unboosted.carrierLevelDB = 0
        return [
            ("default", "Default: pulse alone", ChimeSynth.Handshake.pulse.design),
            ("fallback", "Fallback: code follows the pulse, +6 dB", ChimeSynth.Handshake.coded.design),
            ("fallback-plain", "Fallback: plain veil, +6 dB", unblended),
            ("fallback-0db", "Fallback: follows, carrier +0 dB", unboosted),
        ]
    }

    static func run(directory: String, trials: Int, quick: Bool) {
        let started = Date()
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })!
        let pulseAlone = { () -> ChimeDesign in var d = ChimeDesign(style: .omen); d.voice.enabled = false; return d }()
        let reference = ChimeSynth.renderHandshake(code, design: pulseAlone, sampleRate: Lab.sampleRate).mono
        let referenceVeilBand = veilBand(reference)
        print(String(format: "pulse-alone reference: veil-band rms %.5f", referenceVeilBand))
        for entry in designs() {
            let handshake = ChimeSynth.renderHandshake(code, design: entry.design, sampleRate: Lab.sampleRate)
            var dataOnly = entry.design
            dataOnly.bed.levelDB = -120
            let data = ChimeSynth.renderHandshake(code, design: dataOnly, sampleRate: Lab.sampleRate)
            let heard = PulsePack.decode(Channel.padded(Lab.render(.handshake, design: entry.design, code: code).mono), layers: ChimeLayer.listening)
            print(String(format: "%@: %.2f s, peak %.2f, veil-band rms %.5f (%.1f dB vs pulse alone), data alone rms %.4f, decodes via %@",
                         entry.name, Double(handshake.count) / Lab.sampleRate, handshake.peak, veilBand(handshake.mono),
                         20 * log10(max(veilBand(handshake.mono), 1e-9) / referenceVeilBand), Channel.rms(data.mono),
                         heard.filter { $0.code == code }.map(\.layer.rawValue).joined(separator: "+")))
        }
        let pulse = ChimeSynth.Handshake.pulse.design
        let coded = ChimeSynth.Handshake.coded.design
        let files: [(String, ChimeStereo)] = [
            ("default-whole-sequence", Lab.render(.sequence, design: pulse, code: code)),
            ("fallback-whole-sequence", replay(code, design: coded)),
            ("fallback-plain-veil-whole-sequence", replay(code, design: designs()[2].design)),
            ("fallback-code-alone", { var d = coded; d.bed.levelDB = -120; d.carrier = false; return ChimeSynth.renderHandshake(code, design: d, sampleRate: Lab.sampleRate) }()),
        ]
        for (name, stereo) in files {
            try? Lab.wav(stereo).write(to: folder.appendingPathComponent("\(name).wav"))
            PulsePack.spectrogram(stereo.mono, to: folder.appendingPathComponent("\(name).png"))
        }
        let channels = quick
            ? [Report.carrierChannels[3], Report.carrierChannels[4], Report.carrierChannels[5], Report.carrierChannels[7], Report.carrierChannels[9], Report.carrierChannels[10], PulsePack.extraChannels()[0]]
            : Report.carrierChannels + PulsePack.extraChannels()
        var columns: [(String, [LabCheckRow])] = []
        for entry in designs() {
            columns.append((entry.name, Lab.check(entry.design, channels: channels, trials: trials, seed: 47)))
        }
        print("\n| Channel | " + columns.map(\.0).joined(separator: " | ") + " |")
        print("|---|" + columns.map { _ in "---|" }.joined())
        var wrong = 0
        for index in channels.indices {
            let cells = columns.map { column -> String in
                let row = column.1[index]
                wrong += row.wrong
                let notes = row.notes.map { "code \(Report.percent($0, trials)), " } ?? ""
                return "\(notes)carrier \(Report.percent(row.carrier, trials)), either \(Report.percent(row.either, trials))"
            }
            print("| \(channels[index].name) | " + cells.joined(separator: " | ") + " |")
        }
        print(String(format: "\nTrials per cell: %d. Wrong codes: %d. %.0f s", trials, wrong, Date().timeIntervalSince(started)))
    }

    static func replay(_ code: ChimeCode, design: ChimeDesign) -> ChimeStereo {
        var cue = ChimeSynth.renderHandshake(code, design: design, sampleRate: Lab.sampleRate)
        cue.append(ChimeStereo(seconds: Lab.carrierTail, sampleRate: Lab.sampleRate))
        let carrierSeconds = Double(cue.count) / Lab.sampleRate
        cue.append(design.success.render(.success, sampleRate: Lab.sampleRate))
        var output = Lab.carrier(code, design: design, seconds: carrierSeconds)
        output.append(ChimeStereo(seconds: Double(cue.count - output.count) / Lab.sampleRate, sampleRate: Lab.sampleRate))
        output.mix(cue, gain: 1, sampleRate: Lab.sampleRate)
        return output
    }

    static func veilBand(_ x: [Float]) -> Double {
        Double(Channel.rms(Channel.lowpass(Channel.highpass(x, cutoff: ChimeLayer.veil.lowestFrequency * 0.95, stages: 4), cutoff: ChimeLayer.veil.highestFrequency * 1.05, stages: 4)))
    }
}
