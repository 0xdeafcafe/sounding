import Foundation

enum LoudnessNormalization {
    static let targetLUFS: Float = -14

    static let floor: Double = 0.2

    static let maximumBoostDecibels: Double = 6

    static let ceilingDecibels: Double = -1

    static let peakMarginDecibels: Double = 0.5

    static func gain(measuredLUFS: Float, peakDecibels: Float?) -> Double {
        guard measuredLUFS.isFinite else { return 1 }
        let deltaDB = Double(targetLUFS - measuredLUFS)
        if deltaDB < 0 { return min(1, max(floor, pow(10, deltaDB / 20))) }
        guard let peakDecibels, peakDecibels.isFinite else { return 1 }
        let headroom = ceilingDecibels - peakMarginDecibels - Double(peakDecibels)
        let boost = max(0, min(deltaDB, maximumBoostDecibels, headroom))
        return pow(10, boost / 20)
    }

    static func attenuation(measuredLUFS: Float) -> Double {
        gain(measuredLUFS: measuredLUFS, peakDecibels: nil)
    }

    static let referenceRMS: Float = 0.75

    static func attenuation(waveformRMS: Float) -> Double {
        guard waveformRMS.isFinite, waveformRMS > referenceRMS else { return 1 }
        return min(1, max(floor, Double(referenceRMS / waveformRMS)))
    }
}
