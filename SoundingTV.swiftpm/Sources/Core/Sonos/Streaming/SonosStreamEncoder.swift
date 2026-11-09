import Foundation
import AVFoundation
import Synchronization

enum SonosStreamError: Error, Equatable {
    case encoderUnavailable
    case listenerFailed(String)
    case alreadyStopped
}

struct SonosEncodedPacket: Sendable {
    let bytes: Data
    let timelineFrame: UInt64
    let frames: Int
}

final class SonosStreamEncoder: @unchecked Sendable {
    static let tickInterval: TimeInterval = 0.02
    static let chunkFrames = 8192

    let ring: SonosAudioRingBuffer
    let format: SonosStreamFormat
    let sampleRate: Double
    let channels: Int
    private let queue: DispatchQueue
    private let converter: AVAudioConverter
    private let pcm: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer
    private let timeline = Atomic<UInt64>(0)
    private var packetsEmitted: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var pacer: SonosStreamPacer
    private let supply = InputSupply()

    var onPackets: (([SonosEncodedPacket]) -> Void)?

    init(ring: SonosAudioRingBuffer, format: SonosStreamFormat, sampleRate: Double, queue: DispatchQueue) throws {
        self.ring = ring
        self.format = format
        self.sampleRate = sampleRate
        self.channels = 2
        self.queue = queue
        pacer = SonosStreamPacer(sampleRate: sampleRate)
        guard let input = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let encoded = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC,
                  AVSampleRateKey: sampleRate,
                  AVNumberOfChannelsKey: 2,
              ]),
              let converter = AVAudioConverter(from: input, to: encoded),
              let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(Self.chunkFrames))
        else { throw SonosStreamError.encoderUnavailable }
        converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
        converter.bitRate = format.bitRate
        self.converter = converter
        self.pcm = pcm
        let packetCapacity = AVAudioPacketCount(Self.chunkFrames / format.framesPerPacket + 8)
        output = AVAudioCompressedBuffer(
            format: encoded,
            packetCapacity: packetCapacity,
            maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
        )
    }

    deinit {
        timer?.cancel()
    }

    var timelineFrame: UInt64 { timeline.load(ordering: .acquiring) }

    var producedFrame: UInt64 { timelineFrame &+ UInt64(ring.availableFrames) }

    var nextPacketFrame: UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        return packetsEmitted &* UInt64(format.framesPerPacket)
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            ring.discard(frames: ring.availableFrames)
            pacer.reset(at: DispatchTime.now().uptimeNanoseconds)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        var packets: [SonosEncodedPacket] = []
        let step = pacer.step(at: DispatchTime.now().uptimeNanoseconds, available: ring.availableFrames)
        if step.discard > 0 {
            ring.discard(frames: step.discard)
        }
        var remaining = step.read
        while remaining > 0 {
            let frames = min(remaining, Self.chunkFrames)
            let read = pcm.floatChannelData.map { ring.read(into: UnsafePointer($0), channelCount: channels, frames: frames) } ?? 0
            guard read > 0 else { break }
            encode(frames: read, into: &packets)
            remaining -= read
        }
        encodeSilence(frames: remaining + step.silence, into: &packets)
        if !packets.isEmpty {
            onPackets?(packets)
        }
    }

    private func encodeSilence(frames: Int, into packets: inout [SonosEncodedPacket]) {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, Self.chunkFrames)
            guard let data = pcm.floatChannelData else { return }
            for channel in 0..<channels {
                data[channel].update(repeating: 0, count: count)
            }
            encode(frames: count, into: &packets)
            remaining -= count
        }
    }

    private func encode(frames: Int, into packets: inout [SonosEncodedPacket]) {
        pcm.frameLength = AVAudioFrameCount(frames)
        timeline.add(UInt64(frames), ordering: .releasing)
        supply.pending = pcm
        while true {
            output.packetCount = 0
            output.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [supply] _, outStatus in
                guard let buffer = supply.pending else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supply.pending = nil
                outStatus.pointee = .haveData
                return buffer
            }
            collect(into: &packets)
            if status != .haveData || output.packetCount == 0 {
                break
            }
        }
        supply.pending = nil
    }

    private func collect(into packets: inout [SonosEncodedPacket]) {
        let count = Int(output.packetCount)
        guard count > 0, let descriptions = output.packetDescriptions else { return }
        let base = output.data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count {
            let description = descriptions[index]
            let size = Int(description.mDataByteSize)
            guard size > 0,
                  let header = ADTSHeader.make(payloadLength: size, sampleRate: sampleRate, channels: channels)
            else { continue }
            var bytes = Data(capacity: header.count + size)
            bytes.append(contentsOf: header)
            bytes.append(base + Int(description.mStartOffset), count: size)
            packets.append(SonosEncodedPacket(
                bytes: bytes,
                timelineFrame: packetsEmitted &* UInt64(format.framesPerPacket),
                frames: format.framesPerPacket
            ))
            packetsEmitted &+= 1
        }
    }

    private final class InputSupply: @unchecked Sendable {
        var pending: AVAudioPCMBuffer?
    }
}
