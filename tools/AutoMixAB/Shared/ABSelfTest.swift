import Foundation

enum ABSelfTest {
    static func run() -> Bool {
        var ok = true
        func expect(_ name: String, _ pass: Bool, _ detail: String) {
            print("\(pass ? "PASS" : "FAIL") \(name): \(detail)")
            ok = ok && pass
        }
        let fs = 48_000.0
        let sine = (0..<Int(fs * 5)).map { Float(0.1 * sin(2 * .pi * 997 * Double($0) / fs)) }
        let stereo = ABAudio.integratedLoudness([sine, sine], sampleRate: fs)
        expect("997 Hz -20 dBFS stereo", abs(stereo + 20) < 0.15, String(format: "%.2f LUFS, want -20.0", stereo))
        let mono = ABAudio.integratedLoudness([sine, [Float](repeating: 0, count: sine.count)], sampleRate: fs)
        expect("997 Hz -20 dBFS one channel", abs(mono + 23.01) < 0.15, String(format: "%.2f LUFS, want -23.0", mono))
        let gated = ABAudio.integratedLoudness([sine + [Float](repeating: 0, count: sine.count * 3), sine + [Float](repeating: 0, count: sine.count * 3)], sampleRate: fs)
        expect("silence is gated out", abs(gated + 20) < 0.3, String(format: "%.2f LUFS", gated))
        let low = (0..<Int(44_100.0 * 5)).map { Float(0.1 * sin(2 * .pi * 997 * Double($0) / 44_100)) }
        let at44 = ABAudio.integratedLoudness([low, low], sampleRate: 44_100)
        expect("44.1 kHz coefficients", abs(at44 + 20) < 0.15, String(format: "%.2f LUFS", at44))
        let (ga, gb) = ABAudio.matchedGains(-9, -12)
        expect("matching only attenuates", ga == -3 && gb == 0, "\(ga) \(gb)")

        func judgment(_ pair: String, _ pref: ABPreference, artist: String, flip: Bool) -> ABJudgment {
            ABJudgment(trial: 0, pair: pair, kind: .transition, aRender: "", bRender: "", aVariant: flip ? "before" : "after", bVariant: flip ? "after" : "before",
                       preference: pref, preferredVariant: nil, aFaults: flip ? [.muddyBass] : [], bFaults: flip ? [] : [.muddyBass], note: nil,
                       aLoudnessLUFS: -10, bLoudnessLUFS: -10, aGainDB: 0, bGainDB: 0, listenedA: 0, listenedB: 0,
                       tracks: [ABTrack(id: pair + "o", title: "", artist: artist), ABTrack(id: pair + "i", title: "", artist: "x\(pair)")], date: Date())
        }
        var js: [ABJudgment] = []
        for k in 0..<20 {
            let flip = k % 2 == 0
            let afterWins = k < 16
            js.append(judgment("p\(k)", afterWins ? (flip ? .b : .a) : (flip ? .a : .b), artist: "artist\(k % 5)", flip: flip))
        }
        js.append(judgment("p0", .neither, artist: "artist0", flip: false))
        let r = ABAnalysis.compare(js, focus: "after", other: "before", kind: "all")
        expect("pair-level rate", abs(r.preferenceRate - (15.75 / 20)) < 1e-9, String(format: "%.4f over %d pairs", r.preferenceRate, r.pairs))
        expect("bootstrap brackets the rate", r.interval.low < r.preferenceRate && r.interval.high > r.preferenceRate && r.interval.low > 0.5, String(format: "%.2f–%.2f", r.interval.low, r.interval.high))
        expect("faults follow the variant, not the side", r.faults["before"]?["muddyBass"] == 21 && (r.faults["after"]?["muddyBass"] ?? 0) == 0, "\(r.faults)")
        expect("leave one artist out", r.heldOut.first?.splits.count == 25 && r.heldOut.first?.flips == 0, "\(r.heldOut.first?.splits.map(\.rate) ?? [])")
        return ok
    }
}
