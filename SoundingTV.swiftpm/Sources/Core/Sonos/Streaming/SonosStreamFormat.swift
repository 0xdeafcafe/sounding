import Foundation

enum SonosStreamFormat: String, Sendable, CaseIterable {
    case aacADTS

    var mimeType: String {
        switch self {
        case .aacADTS: "audio/aac"
        }
    }

    var fileExtension: String {
        switch self {
        case .aacADTS: "aac"
        }
    }

    var sonosURIScheme: String {
        switch self {
        case .aacADTS: "x-rincon-mp3radio"
        }
    }

    var framesPerPacket: Int {
        switch self {
        case .aacADTS: 1024
        }
    }

    var bitRate: Int {
        switch self {
        case .aacADTS: 256_000
        }
    }

    func sonosURI(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = sonosURIScheme
        return components.string ?? url.absoluteString
    }
}

enum ADTSHeader {
    static let length = 7

    static func samplingFrequencyIndex(for sampleRate: Double) -> UInt8? {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        return rates.firstIndex(of: sampleRate).map { UInt8($0) }
    }

    static func make(payloadLength: Int, sampleRate: Double, channels: Int, audioObjectType: UInt8 = 2) -> [UInt8]? {
        guard let frequency = samplingFrequencyIndex(for: sampleRate), (1...7).contains(channels) else { return nil }
        let frameLength = payloadLength + length
        guard frameLength < 1 << 13 else { return nil }
        let profile = (audioObjectType - 1) & 0x3
        let channel = UInt8(channels)
        return [
            0xFF,
            0xF1,
            (profile << 6) | (frequency << 2) | ((channel >> 2) & 0x1),
            ((channel & 0x3) << 6) | UInt8((frameLength >> 11) & 0x3),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8((frameLength & 0x7) << 5) | 0x1F,
            0xFC,
        ]
    }
}

struct SonosLatencyEstimator: Sendable {
    static let range: ClosedRange<TimeInterval> = 0.2...10

    var window: Int = 8
    private(set) var samples: [TimeInterval] = []

    init(window: Int = 8) {
        self.window = max(1, window)
    }

    var current: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return min(Self.range.upperBound, max(Self.range.lowerBound, median))
    }

    mutating func add(producedFrame: UInt64, streamStartFrame: UInt64, sonosElapsed: TimeInterval, sampleRate: Double) -> TimeInterval? {
        guard sampleRate > 0, sonosElapsed.isFinite, sonosElapsed >= 0, producedFrame >= streamStartFrame else { return current }
        let produced = Double(producedFrame - streamStartFrame) / sampleRate
        let latency = produced - sonosElapsed
        guard latency.isFinite, latency > -1, latency < 60 else { return current }
        samples.append(latency)
        if samples.count > window {
            samples.removeFirst(samples.count - window)
        }
        return current
    }

    mutating func reset() {
        samples.removeAll()
    }
}
