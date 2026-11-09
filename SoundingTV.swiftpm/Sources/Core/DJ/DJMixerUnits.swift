import Foundation

enum DJChannelFaderCurve: String, CaseIterable, Codable, Sendable {
    case smooth
    case linear
    case sharp

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .linear: return "Linear"
        case .sharp: return "Sharp"
        }
    }

    func gain(position: Double) -> Double {
        let p = min(1, max(0, position))
        switch self {
        case .smooth: return p * p
        case .linear: return p
        case .sharp: return 1 - pow(1 - p, 4)
        }
    }

    func position(gain: Double) -> Double {
        let g = min(1, max(0, gain))
        switch self {
        case .smooth: return g.squareRoot()
        case .linear: return g
        case .sharp: return 1 - pow(1 - g, 0.25)
        }
    }
}

enum DJCrossfaderCurve: String, CaseIterable, Codable, Sendable {
    case smooth
    case mix
    case cut

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .mix: return "Mix"
        case .cut: return "Cut"
        }
    }

    var shape: Double {
        switch self {
        case .smooth: return 0
        case .mix: return 0.2
        case .cut: return 1
        }
    }
}

enum DJMixerUnits {
    static let trimRange: ClosedRange<Double> = -24...12
    static let tempoRange = 0.16

    static func tempoRate(knob: Double) -> Double {
        1 + (min(1, max(0, knob)) * 2 - 1) * tempoRange
    }

    static func tempoKnob(rate: Double) -> Double {
        min(1, max(0, ((rate - 1) / tempoRange + 1) / 2))
    }

    static func trimDecibels(knob: Double) -> Double {
        let k = min(1, max(0, knob))
        return k <= 0.5 ? trimRange.lowerBound * (1 - k / 0.5) : (k - 0.5) / 0.5 * trimRange.upperBound
    }

    static func trimKnob(decibels: Double) -> Double {
        let d = min(trimRange.upperBound, max(trimRange.lowerBound, decibels))
        return d <= 0 ? 0.5 * (1 - d / trimRange.lowerBound) : 0.5 + d / trimRange.upperBound * 0.5
    }

    static func eqDecibels(knob: Double) -> Double {
        knob <= 0.5 ? -60 + (knob / 0.5) * 60 : (knob - 0.5) / 0.5 * 12
    }

    static func eqKnob(decibels: Double) -> Double {
        decibels <= 0 ? max(0, (decibels + 60) / 60 * 0.5) : min(1, 0.5 + (decibels / 12) * 0.5)
    }

    static func filterHertz(knob: Double) -> Double {
        let lo = log(MixEngine.filterCutoffRange.lowerBound)
        let hi = log(MixEngine.filterCutoffRange.upperBound)
        return exp(lo + min(1, max(0, knob)) * (hi - lo))
    }

    static func filterKnob(hertz: Double) -> Double {
        let lo = log(MixEngine.filterCutoffRange.lowerBound)
        let hi = log(MixEngine.filterCutoffRange.upperBound)
        return min(1, max(0, (log(max(hertz, 1)) - lo) / (hi - lo)))
    }

    static func bipolarFilterKnob(lowPass: Double, highPass: Double) -> Double {
        if highPass > MixEngine.filterCutoffRange.lowerBound + 5 {
            return 0.5 + filterKnob(hertz: highPass) * 0.5
        }
        if lowPass < MixEngine.filterOpenHertz {
            return filterKnob(hertz: lowPass) * 0.5
        }
        return 0.5
    }

    static func bipolarFilter(knob: Double) -> (lowPass: Double, highPass: Double) {
        let k = min(1, max(0, knob))
        if abs(k - 0.5) < 0.02 {
            return (MixEngine.filterCutoffRange.upperBound, MixEngine.filterCutoffRange.lowerBound)
        }
        if k < 0.5 {
            return (filterHertz(knob: k / 0.5), MixEngine.filterCutoffRange.lowerBound)
        }
        return (MixEngine.filterCutoffRange.upperBound, filterHertz(knob: (k - 0.5) / 0.5))
    }

    static func levelGain(knob: Double) -> Double {
        let k = min(1, max(0, knob))
        return k * k
    }

    static func levelKnob(gain: Double) -> Double {
        min(1, max(0, gain)).squareRoot()
    }

    static func decibelLabel(gain: Double) -> String {
        guard gain > 0.0005 else { return "−∞ dB" }
        return decibelLabel(20 * log10(gain))
    }

    static func decibelLabel(_ decibels: Double) -> String {
        if decibels <= MixIsolator.killDecibels { return "Kill" }
        let rounded = (decibels * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "0 dB" }
        let magnitude = String(format: abs(rounded) >= 10 ? "%.0f" : "%.1f", abs(rounded))
        return "\(rounded < 0 ? "−" : "+")\(magnitude) dB"
    }

    static func frequencyLabel(_ hertz: Double) -> String {
        hertz >= 1000 ? String(format: "%.1f kHz", hertz / 1000) : String(format: "%.0f Hz", hertz)
    }

    static func filterLabel(lowPass: Double, highPass: Double) -> String {
        if highPass > MixEngine.filterCutoffRange.lowerBound + 5 { return "HPF \(frequencyLabel(highPass))" }
        if lowPass < MixEngine.filterOpenHertz { return "LPF \(frequencyLabel(lowPass))" }
        return "Off"
    }

    static func beatsLabel(_ beats: Double) -> String {
        switch beats {
        case 0.25: return "1/4 beat"
        case 0.5: return "1/2 beat"
        case 0.75: return "3/4 beat"
        case 1: return "1 beat"
        default: return "\(Int(beats)) beats"
        }
    }
}
