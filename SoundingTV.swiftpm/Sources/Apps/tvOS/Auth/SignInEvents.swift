import Foundation
import QuartzCore

enum SignInEvent: Equatable, Sendable {
    case codeRotated
    case carrier(ChimeCarrierLoop?)
    case chime(ChimeSchedule)
    case scanned
    case offerReceived
    case exchangeStarted
    case offerClosed
    case confirmed
    case failed
    case signedIn
    case notificationSent
    case phoneConnecting
}

struct ChimeCarrierLoop: Equatable, Sendable {
    var start: CFTimeInterval
    var period: TimeInterval
}

struct ChimeSchedule: Equatable, Sendable {
    static let rate: Double = 60

    var start: CFTimeInterval
    var duration: TimeInterval
    var beats: [TimeInterval]
    var pump: [Double]
    var sparkle: [Double]

    init(start: CFTimeInterval, duration: TimeInterval, beats: [TimeInterval], pump: [Double], sparkle: [Double]) {
        self.start = start
        self.duration = duration
        self.beats = beats
        self.pump = pump
        self.sparkle = sparkle
    }

    init(samples: [Float], sampleRate: Double, start: CFTimeInterval) {
        self.start = start
        duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let hop = max(1, Int(sampleRate / Self.rate))
        let frames = samples.count / hop + 1
        let smoothing = exp(-2 * Double.pi * 180 / max(1, sampleRate))
        var low = 0.0
        var lowEnergy = [Double](repeating: 0, count: frames)
        var highEnergy = [Double](repeating: 0, count: frames)
        for (index, sample) in samples.enumerated() {
            let x = Double(sample)
            low = smoothing * low + (1 - smoothing) * x
            let high = x - low
            lowEnergy[index / hop] += low * low
            highEnergy[index / hop] += high * high
        }

        func envelope(_ energy: [Double], floor: Double, curve: Double) -> [Double] {
            let rms = energy.map { sqrt($0 / Double(hop)) }
            let smoothed = rms.indices.map { index in
                (rms[max(0, index - 1)] + 2 * rms[index] + rms[min(rms.count - 1, index + 1)]) / 4
            }
            let peak = smoothed.max() ?? 0
            guard peak > 0 else { return smoothed.map { _ in 0 } }
            return smoothed.map { pow(min(1, max(0, ($0 / peak - floor) / (1 - floor))), curve) }
        }

        pump = envelope(lowEnergy, floor: 0.4, curve: 1.5)
        sparkle = envelope(highEnergy, floor: 0.2, curve: 1)

        var beats: [TimeInterval] = []
        var armed = true
        for (index, value) in pump.enumerated() {
            if armed, value > 0.5 {
                beats.append(Double(index) / Self.rate)
                armed = false
            } else if !armed, value < 0.3 {
                armed = true
            }
        }
        self.beats = beats
    }

    func value(_ curve: [Double], at time: TimeInterval) -> Double {
        guard !curve.isEmpty, time >= 0 else { return 0 }
        let x = time * Self.rate
        let index = Int(x)
        guard index + 1 < curve.count else { return index < curve.count ? curve[index] : 0 }
        let f = x - Double(index)
        return curve[index] * (1 - f) + curve[index + 1] * f
    }

    func kick(at time: TimeInterval) -> Double {
        var total = 0.0
        for beat in beats where beat <= time && time - beat < 0.6 {
            let age = time - beat
            total += min(1, age / 0.03) * exp(-age / 0.16)
        }
        return min(1, total)
    }
}

#if DEBUG
enum SignInStory: String {
    case idle, carrier, chime, scanned, incoming, connecting, success, failed, rotate, notified, picker

    static let current: SignInStory? = ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_STORY"]
        .flatMap(SignInStory.init(rawValue:))

    var wantsCarrier: Bool { self != .idle }

    @MainActor
    func run(send: (SignInEvent) -> Void, chime: () -> Void) async {
        try? await Task.sleep(for: .seconds(5))
        if self == .connecting {
            send(.exchangeStarted)
            return
        }
        while !Task.isCancelled {
            switch self {
            case .idle, .carrier, .connecting:
                return
            case .chime:
                chime()
            case .scanned:
                send(.scanned)
            case .incoming:
                send(.offerReceived)
            case .success:
                send(.signedIn)
            case .failed:
                send(.failed)
            case .rotate:
                send(.codeRotated)
            case .notified:
                send(.notificationSent)
            case .picker:
                send(.phoneConnecting)
            }
            try? await Task.sleep(for: .seconds(self == .success ? 4.5 : 3.5))
        }
    }
}
#endif
