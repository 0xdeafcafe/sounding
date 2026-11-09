import Foundation

enum MixFXKind: Int, CaseIterable, Codable, Sendable {
    case echo = 1
    case reverb = 2
    case filter = 3
    case plugin = 4

    var title: String {
        switch self {
        case .echo: return "Echo"
        case .reverb: return "Reverb"
        case .filter: return "Filter"
        case .plugin: return "Plug-in"
        }
    }

    var isBuiltIn: Bool { self != .plugin }
}

final class MixDeckFX {
    static let switchFrames = 512.0
    static let filterLowHertz = 280.0
    static let filterHighHertz = 7_500.0

    let sampleRate: Double
    let echo: MixEcho
    let reverb: MixReverb
    var filterL = MixStateVariableFilter()
    var filterR = MixStateVariableFilter()

    var kind = 0
    var requestedKind = 0
    var periodFrames = 22_050.0
    var feedback = 0.5
    var switchGain = 1.0
    var phase = 0.0
    var tailFrames = 0
    var filterCounter = 0

    let sendLeft: UnsafeMutablePointer<Float>
    let sendRight: UnsafeMutablePointer<Float>
    let wetLeft: UnsafeMutablePointer<Float>
    let wetRight: UnsafeMutablePointer<Float>
    let feedbackGain: UnsafeMutablePointer<Float>
    let switchRamp: UnsafeMutablePointer<Float>

    init(sampleRate: Double, capacity: Int) {
        self.sampleRate = sampleRate
        echo = MixEcho(sampleRate: sampleRate)
        reverb = MixReverb(sampleRate: sampleRate, seconds: 3.2)
        func buffer() -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
        sendLeft = buffer()
        sendRight = buffer()
        wetLeft = buffer()
        wetRight = buffer()
        feedbackGain = buffer()
        switchRamp = buffer()
    }

    deinit {
        for pointer in [sendLeft, sendRight, wetLeft, wetRight, feedbackGain, switchRamp] { pointer.deallocate() }
    }

    func configure(kind newKind: Int, periodSeconds: Double, feedback newFeedback: Double) {
        requestedKind = newKind
        if periodSeconds.isFinite, periodSeconds > 0 {
            periodFrames = max(64, periodSeconds * sampleRate)
            if newKind == MixFXKind.echo.rawValue, kind == newKind {
                echo.setDelay(seconds: echoSeconds)
            }
        }
        feedback = min(0.9, max(0, newFeedback))
    }

    var isIdle: Bool { kind == 0 && requestedKind == 0 }

    private var echoSeconds: Double { min(MixEcho.maximumSeconds - 0.01, periodFrames / sampleRate) }

    func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        send: UnsafePointer<Float>,
        wet: UnsafePointer<Float>,
        frames: Int
    ) {
        let step = 1 / Self.switchFrames
        var segmentStart = 0
        var n = 0
        while n < frames {
            var switched = false
            if requestedKind != kind {
                switchGain = max(0, switchGain - step)
                switched = switchGain == 0
            } else if switchGain < 1 {
                switchGain = min(1, switchGain + step)
            }
            switchRamp[n] = Float(switchGain)
            n += 1
            if switched {
                run(left: left, right: right, send: send, wet: wet, from: segmentStart, to: n)
                kind = requestedKind
                resetState()
                segmentStart = n
            }
        }
        if segmentStart < frames {
            run(left: left, right: right, send: send, wet: wet, from: segmentStart, to: frames)
        }
    }

    private func run(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        send: UnsafePointer<Float>,
        wet: UnsafePointer<Float>,
        from: Int,
        to: Int
    ) {
        guard kind != 0, kind != MixFXKind.plugin.rawValue, to > from else { return }
        var engaged = false
        for n in from..<to where send[n] > 0 || wet[n] > 0 {
            engaged = true
            break
        }
        let count = to - from
        if engaged { tailFrames = Int(sampleRate * 10) }
        guard tailFrames > 0 else { return }
        tailFrames -= count

        switch kind {
        case MixFXKind.echo.rawValue, MixFXKind.reverb.rawValue:
            for n in from..<to {
                let g = send[n] * switchRamp[n]
                sendLeft[n] = left[n] * g
                sendRight[n] = right[n] * g
                feedbackGain[n] = Float(feedback)
            }
            if kind == MixFXKind.echo.rawValue {
                echo.process(
                    inputLeft: sendLeft + from, inputRight: sendRight + from,
                    outputLeft: wetLeft + from, outputRight: wetRight + from,
                    frames: count, feedbackGain: feedbackGain + from
                )
                if echo.energy > 1e-5 { tailFrames = max(tailFrames, count * 4) }
            } else {
                reverb.process(
                    inputLeft: sendLeft + from, inputRight: sendRight + from,
                    outputLeft: wetLeft + from, outputRight: wetRight + from,
                    frames: count
                )
                if reverb.energy > 1e-5 { tailFrames = max(tailFrames, count * 4) }
            }
            for n in from..<to {
                let w = wet[n] * switchRamp[n]
                left[n] += wetLeft[n] * w
                right[n] += wetRight[n] * w
            }
        case MixFXKind.filter.rawValue:
            let increment = 1 / periodFrames
            let lo = log2(Self.filterLowHertz)
            let hi = log2(Self.filterHighHertz)
            for n in from..<to {
                if filterCounter & 31 == 0 {
                    let sweep = 0.5 - 0.5 * cos(2 * Double.pi * phase)
                    let cutoff = pow(2, lo + (hi - lo) * sweep)
                    filterL.configure(cutoff: cutoff, q: 2.2, sampleRate: sampleRate)
                    filterR.configure(cutoff: cutoff, q: 2.2, sampleRate: sampleRate)
                }
                filterCounter &+= 1
                phase += increment
                if phase >= 1 { phase -= 1 }
                let dryL = Double(left[n])
                let dryR = Double(right[n])
                let lpL = filterL.lowPass(dryL)
                let lpR = filterR.lowPass(dryR)
                let amount = Double(min(send[n], wet[n]) * switchRamp[n])
                left[n] = Float(dryL + (lpL - dryL) * amount)
                right[n] = Float(dryR + (lpR - dryR) * amount)
            }
        default:
            break
        }
    }

    func resetState() {
        echo.clear()
        echo.setDelay(seconds: echoSeconds)
        echo.delayFrames = echo.targetDelayFrames
        reverb.clear()
        filterL.reset()
        filterR.reset()
        phase = 0
        tailFrames = 0
    }
}
