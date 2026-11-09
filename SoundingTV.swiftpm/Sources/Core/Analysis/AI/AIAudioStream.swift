import AVFoundation
import Foundation

enum AIAudioStreamError: Error {
    case unreadable
    case converterUnavailable
}

struct AIAudioStream {
    let url: URL
    let sampleRate: Double
    let channels: Int

    var duration: Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func read(blockFrames: Int = 1 << 18, _ body: ([[Float]]) throws -> Bool) throws {
        let file = try AVAudioFile(forReading: url)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw AIAudioStreamError.unreadable
        }
        let input = file.processingFormat
        let mono = channels == 1 && input.channelCount > 1
        let sourceFormat: AVAudioFormat
        if mono {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false) else { throw AIAudioStreamError.unreadable }
            sourceFormat = format
        } else {
            sourceFormat = input
        }
        let passthrough = sourceFormat.sampleRate == sampleRate && Int(sourceFormat.channelCount) == channels
        var converter: AVAudioConverter?
        if !passthrough {
            guard let made = AVAudioConverter(from: sourceFormat, to: output) else { throw AIAudioStreamError.converterUnavailable }
            made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            made.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter = made
        }
        let readFrames = AVAudioFrameCount(blockFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: readFrames) else { throw AIAudioStreamError.unreadable }
        var finished = false

        func nextSource() throws -> AVAudioPCMBuffer? {
            if finished || file.framePosition >= file.length { finished = true; return nil }
            try file.read(into: readBuffer, frameCount: readFrames)
            let count = Int(readBuffer.frameLength)
            if count == 0 { finished = true; return nil }
            guard mono, let data = readBuffer.floatChannelData else { return readBuffer }
            guard let mixed = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: readBuffer.frameLength), let out = mixed.floatChannelData?[0] else { return nil }
            mixed.frameLength = readBuffer.frameLength
            let n = Int(input.channelCount)
            let scale = 1 / Float(n)
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<n { sum += data[c][i] }
                out[i] = sum * scale
            }
            return mixed
        }

        func emit(_ buffer: AVAudioPCMBuffer) throws -> Bool {
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { return true }
            let planes = (0..<channels).map { c in Array(UnsafeBufferPointer(start: data[min(c, Int(buffer.format.channelCount) - 1)], count: count)) }
            return try body(planes)
        }

        guard let converter else {
            while let source = try nextSource() {
                if try !emit(source) { return }
            }
            return
        }
        let outFrames = AVAudioFrameCount(Double(blockFrames) * sampleRate / sourceFormat.sampleRate) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outFrames) else { throw AIAudioStreamError.unreadable }
        var readError: Error?
        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, state in
                do {
                    if let source = try nextSource() {
                        state.pointee = .haveData
                        return source
                    }
                } catch {
                    readError = error
                }
                state.pointee = .endOfStream
                return nil
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if try !emit(outBuffer) { return }
            if status == .endOfStream || status == .error { return }
        }
    }
}
