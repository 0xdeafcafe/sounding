import Foundation

enum Report {
    static let carrierChannels: [LabChannel] = [
        LabChannel(name: "Clean") { x, _ in (x, 48_000) },
        LabChannel(name: "TV, gentle roll-off above 16 kHz") { x, rng in tv(x, cutoff: 16_000, stages: 2, rng: &rng) },
        LabChannel(name: "TV, steep cut at 16 kHz") { x, rng in tv(x, cutoff: 16_000, stages: 4, rng: &rng) },
        LabChannel(name: "TV, steep cut at 15 kHz") { x, rng in tv(x, cutoff: 15_000, stages: 4, rng: &rng) },
        LabChannel(name: "TV, cut at 12 kHz") { x, rng in tv(x, cutoff: 12_000, stages: 4, rng: &rng) },
        LabChannel(name: "Tiny speaker, 4 kHz") { x, rng in
            (Channel.noise(Channel.reverb(Channel.lowpass(x, cutoff: 4_000, stages: 4), rt60: 0.5, wet: 0.8), snr: 10, rng: &rng), 48_000)
        },
        LabChannel(name: "Phone at 4 m, quiet room") { x, rng in LabChannel.phone(x, rng: &rng, snr: nil) },
        LabChannel(name: "Phone at 4 m, noisy room (8 dB SNR)") { x, rng in LabChannel.phone(x, rng: &rng, snr: 8) },
        LabChannel(name: "Phone at 4 m, TV rolls off at 16 kHz") { x, rng in
            LabChannel.phone(Channel.lowpass(x, cutoff: 16_000, stages: 2), rng: &rng, snr: nil)
        },
        LabChannel(name: "Phone at 4 m, room noise at -60 dBFS") { x, rng in
            let room = Channel.reverb(Channel.drift(x, factor: 48_000.0 / 44_100.0), rt60: 0.6, wet: 0.8).map { $0 * 0.0316 }
            return (Channel.whiteNoise(room, dBFS: -60, rng: &rng), 44_100)
        },
        LabChannel(name: "Music as loud as the chime") { x, rng in (Channel.withMusic(x, relativeLevel: 1, rng: &rng), 48_000) },
        LabChannel(name: "Clock drift 0.3%, echo") { x, rng in
            (Channel.whiteNoise(Channel.reverb(Channel.drift(x, factor: 1.003), rt60: 0.3, wet: 0.5), dBFS: -80, rng: &rng), 48_000)
        },
    ]

    static func tv(_ x: [Float], cutoff: Double, stages: Int, rng: inout SeededGenerator) -> (signal: [Float], sampleRate: Double) {
        (Channel.whiteNoise(Channel.reverb(Channel.lowpass(x, cutoff: cutoff, stages: stages), rt60: 0.4, wet: 0.6), dBFS: -70, rng: &rng), 48_000)
    }

    static func percent(_ value: Int?, _ trials: Int) -> String {
        guard let value else { return "off" }
        return "\(Int((Double(value) / Double(trials) * 100).rounded()))%"
    }

    static func run(trials: Int) {
        let start = Date()
        let losses = ChimeLayer.carrier.tones.map { tone in
            [(16_000.0, 2), (16_000, 4), (15_000, 4), (12_000, 4)].map { String(format: "%.0f", Channel.toneLoss(tone, cutoff: $0.0, stages: $0.1)) }.joined(separator: "/")
        }
        print("carrier tone loss (dB) for 16k gentle / 16k steep / 15k steep / 12k: " + zip(ChimeLayer.carrier.tones, losses).map { "\(Int($0)) Hz \($1)" }.joined(separator: ", "))
        let bassOnly = LabPreset.bassOnly
        var louder = bassOnly
        louder.carrierLevelDB = 6
        let slide = ChimeDesign(style: .slide)
        let carrierRows = Lab.check(bassOnly, channels: carrierChannels, trials: trials, seed: 41)
        let louderRows = Lab.check(louder, channels: carrierChannels, trials: trials, seed: 43)
        let slideRows = Lab.check(slide, channels: carrierChannels, trials: trials, seed: 47)
        print("\n| Channel | Carrier only | Carrier +6 dB | Slide notes | Slide notes or carrier |")
        print("|---|---|---|---|---|")
        for index in carrierRows.indices {
            let a = carrierRows[index], b = louderRows[index], c = slideRows[index]
            print("| \(a.channel) | \(percent(a.carrier, trials)) | \(percent(b.carrier, trials)) | \(percent(c.notes, trials)) | \(percent(c.either, trials)) |" + (a.wrong + b.wrong + c.wrong > 0 ? " wrong codes: \(a.wrong + b.wrong + c.wrong)" : ""))
        }

        print("\nLow data bands under the bass (notes only, carrier off):")
        var candidates: [(String, ChimeDesign)] = []
        for (lowest, length) in [(69, 0.116), (57, 0.116), (57, 0.15), (52, 0.15), (45, 0.15), (45, 0.2)] {
            var design = ChimeDesign(style: .slide)
            design.carrier = false
            design.layer.lowestMIDI = lowest
            design.layer.noteLength = length
            let tones = design.layer.layer.tones
            candidates.append((String(format: "%.0f–%.0f Hz, %.0f ms notes, FFT %d", tones.first!, tones.last!, length * 1000, design.layer.layer.fftSize), design))
        }
        print("| Band | " + LabChannel.quick.map(\.name).joined(separator: " | ") + " |")
        print("|---|" + LabChannel.quick.map { _ in "---|" }.joined())
        for (name, design) in candidates {
            let rows = Lab.check(design, trials: trials, seed: 53)
            print("| \(name) | " + rows.map { percent($0.notes, trials) + ($0.wrong > 0 ? " (\($0.wrong) wrong)" : "") }.joined(separator: " | ") + " |")
        }
        print(String(format: "\n%.0f s", Date().timeIntervalSince(start)))
    }
}
