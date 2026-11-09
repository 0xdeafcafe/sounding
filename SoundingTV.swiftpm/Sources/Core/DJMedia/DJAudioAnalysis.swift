import AVFoundation
import Foundation

struct DJAudioFileInfo: Equatable, Sendable {
    var durationSeconds: Double
    var sampleRate: Int
    var bitDepth: Int
    var bitrateKbps: Int
    var fileSize: Int64
}

enum DJAudioAnalysis {
    static func info(_ url: URL) throws -> DJAudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        let duration = rate > 0 ? Double(file.length) / rate : 0
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let depth = file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 16
        let bitrate = duration > 0 ? Int((Double(size) * 8 / duration / 1000).rounded()) : 0
        return DJAudioFileInfo(durationSeconds: duration, sampleRate: Int(rate), bitDepth: depth, bitrateKbps: bitrate, fileSize: size)
    }

    static func waveform(_ url: URL, entriesPerSecond: Double = DJWaveformSynth.detailEntriesPerSecond, useGPU: Bool = true) throws -> DJExportWaveform {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return DJExportWaveform(amplitude: []) }
        let chunk: AVAudioFrameCount = 1 << 15
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return DJExportWaveform(amplitude: [])
        }
        let filter = WaveformBandFilter(sampleRate: rate, entriesPerSecond: entriesPerSecond)
        var stream = makeStream(filter: filter, expectedSamples: Int(file.length), useGPU: useGPU)
        var mono = [Float](repeating: 0, count: Int(chunk))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for i in 0 ..< frames {
                var x: Float = 0
                for c in 0 ..< channelCount { x += channels[c][i] }
                mono[i] = x / Float(max(channelCount, 1))
            }
            mono.withUnsafeBufferPointer { stream.append(UnsafeBufferPointer(rebasing: $0[0 ..< frames])) }
        }
        let bands = stream.finish()
        return DJExportWaveform(amplitude: bands.amplitude, low: bands.low, mid: bands.mid, high: bands.high)
    }

    private static func makeStream(filter: WaveformBandFilter, expectedSamples: Int, useGPU: Bool) -> WaveformBandStream {
        #if canImport(Metal) && !os(watchOS)
        if useGPU { return .best(filter: filter, expectedSamples: expectedSamples) }
        #endif
        return .cpu(filter: filter, expectedSamples: expectedSamples)
    }
}
