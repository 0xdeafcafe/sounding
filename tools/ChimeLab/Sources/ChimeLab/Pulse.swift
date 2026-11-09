import Accelerate
import AppKit
import Foundation

enum PulsePack {
    static let candidates: [(slug: String, name: String, style: ChimeSynth.Style)] = [
        ("1-omen", "Omen", .omen),
        ("2-abyss", "Abyss", .abyss),
        ("3-grit", "Grit", .grit),
    ]

    static func extraChannels() -> [LabChannel] {
        [
            LabChannel(name: "Music at 2x the chime") { x, rng in (Channel.withMusic(x, relativeLevel: 2, rng: &rng), 48_000) },
            LabChannel(name: "White noise at 0 dB SNR") { x, rng in (Channel.noise(x, snr: 0, rng: &rng), 48_000) },
            LabChannel(name: "Speed and pitch -2%, echo, 6 dB SNR") { x, rng in
                (Channel.noise(Channel.reverb(Channel.drift(x, factor: 0.98), rt60: 0.5, wet: 0.8), snr: 6, rng: &rng), 48_000)
            },
            LabChannel(name: "One stereo channel at 4 m, 44.1 kHz, drift") { x, rng in
                LabChannel.phone(Channel.drift(x, factor: 1.003), rng: &rng, snr: 8)
            },
        ]
    }

    static func run(directory: String, trials: Int, quick: Bool) {
        let start = Date()
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("veil layer: \(ChimeLayer.veil.frameStepCount) steps x \(Int(ChimeLayer.veil.symbolDuration * 1000)) ms = \(String(format: "%.2f", ChimeLayer.veil.frameDuration)) s, \(String(format: "%.0f-%.0f Hz", ChimeLayer.veil.lowestFrequency, ChimeLayer.veil.highestFrequency)), FFT \(ChimeLayer.veil.fftSize)")
        for candidate in candidates {
            let design = design(candidate.style)
            var rng = SeededGenerator(state: UInt64(candidate.slug.hashValue & 0xFFFF) | 0x1000)
            let code = ChimeCode.random() ?? rng.code()
            let handshake = ChimeSynth.renderHandshake(code, design: design, sampleRate: Lab.sampleRate)
            var dataOnly = design
            dataOnly.bed.levelDB = -120
            var bedOnly = design
            bedOnly.voice.enabled = false
            let veil = ChimeSynth.renderHandshake(code, design: dataOnly, sampleRate: Lab.sampleRate)
            let solo = Channel.padded(handshake.mono)
            let heard = decode(solo, layers: [ChimeLayer.veil])
            let listening = decode(Channel.padded(Lab.render(.handshake, design: design, code: code).mono), layers: ChimeLayer.listening)
            let bands = energyBands(handshake.mono)
            print(String(format: "%@: %.2f s, peak %.2f, rms %.3f; below 160 Hz %.0f%%, 160-350 %.0f%%, 350-4k %.0f%%, above 4k %.0f%%; veil alone rms %.4f; pulse data decodes: %@; listening decoder: %@",
                         candidate.name, Double(handshake.count) / Lab.sampleRate, handshake.peak, Channel.rms(handshake.mono),
                         bands[0] * 100, bands[1] * 100, bands[2] * 100, bands[3] * 100, Channel.rms(veil.mono),
                         heard.contains { $0.code == code } ? "yes" : "NO",
                         listening.filter { $0.code == code }.map(\.layer.rawValue).joined(separator: "+")))
            guard !quick else { continue }
            let sequence = Lab.render(.sequence, design: design, code: code)
            let sequenceHeard = decode(sequence.mono, layers: ChimeLayer.listening)
            print("  whole sequence decodes: \(sequenceHeard.filter { $0.code == code }.map(\.layer.rawValue).joined(separator: "+")), wrong: \(sequenceHeard.filter { $0.code != code }.count)")
            var waiting = Lab.carrier(code, design: design, seconds: 15)
            let ping = design.ping.render(.ping, sampleRate: Lab.sampleRate)
            for index in 0..<ChimeSynth.audiblePings {
                waiting.mix(ping, at: Lab.pingRest + Double(index) * Double(ping.count) / Lab.sampleRate, gain: 1, sampleRate: Lab.sampleRate)
            }
            let files: [(String, ChimeStereo)] = [
                ("a-beep", Lab.render(.beep, design: design, code: code)),
                ("b-handshake", Lab.render(.handshake, design: design, code: code)),
                ("c-waiting", waiting),
                ("d-success", Lab.render(.success, design: design, code: code)),
                ("e-whole-sequence", sequence),
                ("f-data-texture-alone", veil),
                ("g-pulse-alone", ChimeSynth.renderHandshake(code, design: bedOnly, sampleRate: Lab.sampleRate)),
            ]
            for (suffix, stereo) in files {
                try? Lab.wav(stereo).write(to: folder.appendingPathComponent("\(candidate.slug)-\(suffix).wav"))
            }
            for (suffix, stereo) in [("b-handshake", handshake), ("e-whole-sequence", sequence)] {
                spectrogram(stereo.mono, to: folder.appendingPathComponent("\(candidate.slug)-\(suffix).png"))
            }
        }
        guard !quick else {
            quickCheck(trials: trials)
            print(String(format: "%.0f s", Date().timeIntervalSince(start)))
            return
        }
        margins(trials: trials)
        print(String(format: "\n%.0f s", Date().timeIntervalSince(start)))
    }

    static func quickCheck(trials: Int) {
        let channels = [Report.carrierChannels[5], Report.carrierChannels[7], Report.carrierChannels[10]] + extraChannels()
        print("| Channel | " + candidates.map(\.name).joined(separator: " | ") + " |")
        var columns: [[LabCheckRow]] = []
        for candidate in candidates {
            var design = design(candidate.style)
            design.carrier = false
            columns.append(Lab.check(design, channels: channels, trials: trials, seed: 91))
        }
        for index in channels.indices {
            print("| \(channels[index].name) | " + columns.map { Report.percent($0[index].notes, trials) + ($0[index].wrong > 0 ? " (\($0[index].wrong) wrong)" : "") }.joined(separator: " | ") + " |")
        }
    }

    static func margins(trials: Int) {
        let channels = Report.carrierChannels + extraChannels()
        let carrierRows = Lab.check(LabPreset.bassOnly, channels: channels, trials: trials, seed: 41)
        var header = "| Channel | Carrier only |"
        var rule = "|---|---|"
        var columns: [[LabCheckRow]] = []
        for candidate in candidates {
            columns.append(Lab.check(design(candidate.style), channels: channels, trials: trials, seed: 47))
            header += " \(candidate.name): pulse data | \(candidate.name): data or carrier |"
            rule += "---|---|"
        }
        print("\n" + header)
        print(rule)
        var wrong = carrierRows.reduce(0) { $0 + $1.wrong }
        for index in channels.indices {
            var line = "| \(channels[index].name) | \(Report.percent(carrierRows[index].carrier, trials)) |"
            for column in columns {
                line += " \(Report.percent(column[index].notes, trials)) | \(Report.percent(column[index].either, trials)) |"
                wrong += column[index].wrong
            }
            print(line)
        }
        print("\nTrials per cell: \(trials). Wrong codes across every cell: \(wrong).")
        var rng = SeededGenerator(state: 40)
        var falseDetections = 0
        for _ in 0..<4 {
            let music = Channel.music(count: Int(20 * Lab.sampleRate), level: 0.2, rng: &rng)
            falseDetections += decode(Channel.whiteNoise(music, dBFS: -50, rng: &rng), layers: ChimeLayer.listening).count
        }
        var cueDetections = 0
        for candidate in candidates {
            let design = design(candidate.style)
            var cues = design.beep.render(.beep, sampleRate: Lab.sampleRate)
            for _ in 0..<4 { cues.append(design.ping.render(.ping, sampleRate: Lab.sampleRate)) }
            cues.append(design.success.render(.success, sampleRate: Lab.sampleRate))
            cueDetections += decode(Channel.padded(cues.mono), layers: ChimeLayer.listening).count
        }
        print("False detections by the phone's full listening decoder: \(falseDetections) in 80 s of music-like audio, \(cueDetections) in every beep, ping and success.")
    }

    static func decode(_ signal: [Float], layers: [ChimeLayer], sampleRate: Double = Lab.sampleRate) -> [ChimeDecoder.Detection] {
        let decoder = ChimeDecoder(sampleRate: sampleRate, layers: layers)
        var detections: [ChimeDecoder.Detection] = []
        var index = 0
        while index < signal.count {
            let end = min(signal.count, index + 4096)
            detections += decoder.process(Array(signal[index..<end]))
            index = end
        }
        return detections
    }

    static func energyBands(_ x: [Float]) -> [Double] {
        let edges: [Double] = [0, 160, 350, 4_000, 24_000]
        var sums = [Double](repeating: 0, count: 4)
        for (low, high) in zip(edges, edges.dropFirst()).enumerated().map({ ($0.element.0, $0.element.1) }) {
            var y = low > 0 ? Channel.highpass(x, cutoff: low, stages: 4) : x
            if high < 24_000 { y = Channel.lowpass(y, cutoff: high, stages: 4) }
            sums[edges.firstIndex(of: low)!] = Double(y.reduce(0) { $0 + $1 * $1 })
        }
        let total = max(sums.reduce(0, +), 1e-12)
        return sums.map { $0 / total }
    }

    static func spectrogram(_ x: [Float], to url: URL) {
        let size = 4096
        let hop = 480
        let width = max(1, (x.count - size) / hop)
        let height = 420
        let log2n = vDSP_Length(12)
        guard width > 1, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        let binHz = Lab.sampleRate / Double(size)
        let lowLog = log10(25.0), highLog = log10(20_000.0)
        let rows = (0..<height).map { row -> Int in
            let frequency = pow(10, lowLog + (highLog - lowLog) * Double(height - 1 - row) / Double(height - 1))
            return min(size / 2 - 1, max(1, Int(frequency / binHz)))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for column in 0..<width {
            let windowed = vDSP.multiply(Array(x[(column * hop)..<(column * hop + size)]), window)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    windowed.withUnsafeBufferPointer { w in
                        w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for (row, bin) in rows.enumerated() {
                let power = Double(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) / Double(size * size)
                let level = max(0, min(1, (10 * log10(max(power, 1e-14)) + 110) / 90))
                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(255 * min(1, level * 1.6))
                pixels[offset + 1] = UInt8(255 * max(0, min(1, level * 1.6 - 0.5)))
                pixels[offset + 2] = UInt8(255 * max(0, min(1, (level - 0.6) * 2.5 + 0.25 * (1 - level))))
                pixels[offset + 3] = 255
            }
        }
        for frequency in [100.0, 350, 1_000, 4_000, 18_000] {
            let row = Int((Double(height - 1) * (1 - (log10(frequency) - lowLog) / (highLog - lowLog))).rounded())
            for column in stride(from: 0, to: width, by: 3) {
                let offset = (row * width + column) * 4
                pixels[offset] = 90; pixels[offset + 1] = 200; pixels[offset + 2] = 90
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        let representation = NSBitmapImageRep(cgImage: image)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension PulsePack {
    static func design(_ style: ChimeSynth.Style) -> ChimeDesign {
        var design = ChimeDesign(style: style)
        if let value = ProcessInfo.processInfo.environment["CHIME_VEIL_DB"].flatMap(Double.init) { design.voice.levelDB = value }
        return design
    }
}
