import Foundation
@testable import SoundingTV

#if DEBUG

enum LoudnessSelfTest {
    private static let measuredLibraryLUFS: [Float] = [
        -15.0, -13.8, -12.7, -11.4, -11.3, -10.7, -10.1, -10.1, -10.0, -9.7,
         -9.6,  -9.6,  -9.0,  -8.8,  -8.8,  -8.7,  -8.3,  -8.2,  -8.2, -8.2,
         -8.1,  -7.8,  -7.8,  -7.7,  -7.6,  -7.6,  -7.6,  -7.5,  -7.5, -7.3,
         -7.2,  -7.1,  -6.8,  -6.7,  -6.5,  -5.5,  -5.2,  -4.8,  -4.3,
    ]

    private static let measuredLibraryRMS: [Float] = [
        0.6025, 0.7159, 0.7827, 0.8022, 0.8087, 0.8548, 0.8619, 0.8645,
        0.8694, 0.8779, 0.8800, 0.8851, 0.8890, 0.8899, 0.8912, 0.8913,
        0.8985, 0.8989, 0.9161, 0.9164, 0.9327, 0.9334, 0.9363, 0.9386,
        0.9444, 0.9479, 0.9523, 0.9532, 0.9561, 0.9595, 0.9599, 0.9610,
        0.9634, 0.9667, 0.9674, 0.9719, 0.9774, 0.9781, 0.9818, 0.9880,
    ]

    static func run() -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("\(name) → ok")
            } else {
                report.failures.append(name)
            }
        }

        let target = LoudnessNormalization.targetLUFS       // -14
        let floor = LoudnessNormalization.floor             // 0.35
        let reference = LoudnessNormalization.referenceRMS  // 0.75

        var lufsMax = -Double.infinity
        var lufsMin = Double.infinity
        var lufsMonotone = true
        var previousLUFSGain = Double.infinity
        var step = 0
        while step <= 900 {
            let lufs = Float(-60.0 + Double(step) * 0.1)
            let gain = LoudnessNormalization.attenuation(measuredLUFS: lufs)
            lufsMax = max(lufsMax, gain)
            lufsMin = min(lufsMin, gain)
            if gain > previousLUFSGain + 1e-12 { lufsMonotone = false }
            previousLUFSGain = gain
            step += 1
        }

        var rmsMax = -Double.infinity
        var rmsMin = Double.infinity
        var rmsMonotone = true
        var previousRMSGain = Double.infinity
        var bucket = 0
        while bucket <= 1000 {
            let rms = Float(Double(bucket) / 1000.0)
            let gain = LoudnessNormalization.attenuation(waveformRMS: rms)
            rmsMax = max(rmsMax, gain)
            rmsMin = min(rmsMin, gain)
            if gain > previousRMSGain + 1e-12 { rmsMonotone = false }
            previousRMSGain = gain
            bucket += 1
        }

        expect("LUFS branch never boosts (901-point sweep, max gain \(lufsMax))", lufsMax <= 1)
        expect("LUFS branch never silences (sweep min gain \(lufsMin))", lufsMin >= floor)
        expect("LUFS branch is non-increasing in loudness", lufsMonotone)
        expect("waveform branch never boosts (1001-point sweep, max gain \(rmsMax))", rmsMax <= 1)
        expect("waveform branch never silences (sweep min gain \(rmsMin))", rmsMin >= floor)
        expect("waveform branch is non-increasing in loudness", rmsMonotone)

        expect("no measured library LUFS produces gain > 1",
               measuredLibraryLUFS.allSatisfy { LoudnessNormalization.attenuation(measuredLUFS: $0) <= 1 })
        expect("no measured library LUFS produces gain < floor",
               measuredLibraryLUFS.allSatisfy { LoudnessNormalization.attenuation(measuredLUFS: $0) >= floor })
        expect("no measured library RMS produces gain > 1",
               measuredLibraryRMS.allSatisfy { LoudnessNormalization.attenuation(waveformRMS: $0) <= 1 })
        expect("no measured library RMS produces gain < reference",
               measuredLibraryRMS.allSatisfy { LoudnessNormalization.attenuation(waveformRMS: $0) >= Double(reference) })

        expect("NaN LUFS → 1", LoudnessNormalization.attenuation(measuredLUFS: .nan) == 1)
        expect("-infinity LUFS (digital silence) → 1",
               LoudnessNormalization.attenuation(measuredLUFS: -.infinity) == 1)
        expect("+infinity LUFS → 1", LoudnessNormalization.attenuation(measuredLUFS: .infinity) == 1)
        expect("NaN RMS → 1", LoudnessNormalization.attenuation(waveformRMS: .nan) == 1)
        expect("infinite RMS → 1", LoudnessNormalization.attenuation(waveformRMS: .infinity) == 1)
        expect("empty-envelope RMS 0 → 1", LoudnessNormalization.attenuation(waveformRMS: 0) == 1)

        let everyProducedGain =
            measuredLibraryLUFS.map { LoudnessNormalization.attenuation(measuredLUFS: $0) }
            + measuredLibraryRMS.map { LoudnessNormalization.attenuation(waveformRMS: $0) }
        expect("MixEngine's own clamp is a no-op on every produced gain",
               everyProducedGain.allSatisfy { min(1, max(0, $0)) == $0 })
        expect("every produced gain survives the Float narrowing AVPlayer.volume takes",
               everyProducedGain.allSatisfy { Float($0) > 0 && Float($0) <= 1 })

        let threeTimesLouder = target + Float(20 * log10(3.0))   // -4.4576 LUFS
        let threeTimesGain = LoudnessNormalization.attenuation(measuredLUFS: threeTimesLouder)

        expect("3× louder is attenuated at all", threeTimesGain < 1)
        expect("3× louder is not silenced", threeTimesGain > 0.3)
        expect("3× louder lands exactly on the floor, which is where it binds",
               abs(threeTimesGain - floor) < 1e-9)

        let threeTimesResidual = Double(threeTimesLouder) + 20 * log10(threeTimesGain)
        expect("3× louder ends within 1 dB of the target (residual \(threeTimesResidual) LUFS)",
               abs(threeTimesResidual - Double(target)) < 1.0)

        let hottestMeasured: Float = -4.3
        let hottestGain = LoudnessNormalization.attenuation(measuredLUFS: hottestMeasured)
        let hottestResidual = Double(hottestMeasured) + 20 * log10(hottestGain)
        expect("the library's hottest real master (-4.3 LUFS) is attenuated",
               hottestGain < 1 && hottestGain >= floor)
        expect("…and ends within 1 dB of the target (residual \(hottestResidual) LUFS)",
               abs(hottestResidual - Double(target)) < 1.0)

        let floorBindsAt = Double(target) - 20 * log10(floor)     // -4.8814 LUFS
        expect("just under the floor's binding point the exact ratio is still used",
               LoudnessNormalization.attenuation(measuredLUFS: Float(floorBindsAt - 0.5)) > floor)
        expect("just over it the floor takes over",
               abs(LoudnessNormalization.attenuation(measuredLUFS: Float(floorBindsAt + 0.5)) - floor) < 1e-9)

        let medianGain = LoudnessNormalization.attenuation(measuredLUFS: -8.2)
        expect("the library's median master (-8.2 LUFS) lands on target, unclamped",
               abs((Double(-8.2) + 20 * log10(medianGain)) - Double(target)) < 0.01)

        expect("a track quieter than target is untouched (LUFS)",
               LoudnessNormalization.attenuation(measuredLUFS: -20) == 1)
        expect("a track exactly at target is untouched (LUFS)",
               LoudnessNormalization.attenuation(measuredLUFS: target) == 1)
        expect("the library's quietest real master (-15.0 LUFS) is untouched",
               LoudnessNormalization.attenuation(measuredLUFS: -15.0) == 1)
        expect("a very quiet master (-30 LUFS) is untouched, not lifted",
               LoudnessNormalization.attenuation(measuredLUFS: -30) == 1)

        expect("an envelope quieter than reference is untouched (RMS)",
               LoudnessNormalization.attenuation(waveformRMS: 0.6025) == 1)
        expect("an envelope exactly at reference is untouched (RMS)",
               LoudnessNormalization.attenuation(waveformRMS: reference) == 1)
        expect("a very quiet envelope (RMS 0.2) is untouched, not lifted",
               LoudnessNormalization.attenuation(waveformRMS: 0.2) == 1)

        expect("waveform branch bottoms out at exactly referenceRMS",
               abs(LoudnessNormalization.attenuation(waveformRMS: 1.0) - Double(reference)) < 1e-9)
        expect("waveform branch can never reach the floor",
               rmsMin > floor)
        expect("waveform branch's hardest trim is only 2.5 dB",
               abs(20 * log10(rmsMin) + 2.4988) < 0.01)
        expect("LUFS branch does reach the floor, and stops there",
               abs(lufsMin - floor) < 1e-9)

        return report
    }
}
#endif
