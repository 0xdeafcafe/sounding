import Foundation

enum LoudnessNormalization {
    static let targetLUFS: Float = -14

    static let floor: Double = 0.35

    static func attenuation(measuredLUFS: Float) -> Double {
        guard measuredLUFS.isFinite else { return 1 }
        let deltaDB = Double(targetLUFS - measuredLUFS)
        guard deltaDB < 0 else { return 1 } // at or under target — never boost
        return min(1, max(floor, pow(10, deltaDB / 20)))
    }

    static let referenceRMS: Float = 0.75

    static func attenuation(waveformRMS: Float) -> Double {
        guard waveformRMS.isFinite, waveformRMS > referenceRMS else { return 1 } // never boost
        return min(1, max(floor, Double(referenceRMS / waveformRMS)))
    }
}
