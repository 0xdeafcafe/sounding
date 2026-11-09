import Foundation
import AVFoundation
import Synchronization
import os

final class MixSource: @unchecked Sendable {
    static let chunkShift = 15
    static let chunkFrames = 1 << chunkShift
    static let chunkMask = chunkFrames - 1
    static let behindFrames = 4 * 44_100
    static let aheadFrames = 30 * 44_100
    static let retireDelay: TimeInterval = 2

    let url: URL
    let frameCount: Int
    let chunkCount: Int
    let sampleRate: Double
    let duration: TimeInterval
    let synchronous: Bool

    private let table: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let file: AVAudioFile
    private let fileFrames: Int
    private let fileChannels: Int
    private let resamples: Bool
    private let lock = OSAllocatedUnfairLock()
    private var graveyard: [(UnsafeMutablePointer<Float>, Date)] = []
    private var readBuffer: AVAudioPCMBuffer?
    private var closed = false

    let playhead = Atomic<Int>(0)
    let pinned = Atomic<Int>(-1)
    let missing = Atomic<Int>(0)
    private let pendingWork = Atomic<Bool>(false)

    private static let queue = DispatchQueue(label: "sounding.mix.source", qos: .userInitiated)

    init(url: URL, synchronous: Bool = false) throws {
        self.url = url
        self.synchronous = synchronous
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        fileFrames = Int(file.length)
        fileChannels = Int(file.processingFormat.channelCount)
        guard fileFrames > 0, fileChannels >= 1 else {
            throw MixEngineError.decodeFailed("the audio file is empty")
        }
        sampleRate = DJEngineConstants.canonicalSampleRate
        let fileRate = file.processingFormat.sampleRate
        resamples = abs(fileRate - sampleRate) > 0.5
        frameCount = resamples ? Int((Double(fileFrames) * sampleRate / fileRate).rounded(.down)) : fileFrames
        duration = Double(frameCount) / sampleRate
        chunkCount = (frameCount + Self.chunkMask) >> Self.chunkShift
        table = .allocate(capacity: chunkCount)
        table.initialize(repeating: nil, count: chunkCount)
        if resamples {
            try decodeEverythingResampled()
        }
    }

    deinit {
        for index in 0..<chunkCount {
            table[index]?.deallocate()
        }
        table.deallocate()
        for (pointer, _) in graveyard { pointer.deallocate() }
    }

    @inline(__always)
    func chunk(_ index: Int) -> UnsafeMutablePointer<Float>? {
        guard index >= 0, index < chunkCount else { return nil }
        let pointer = table[index]
        atomicMemoryFence(ordering: .acquiring)
        if pointer == nil, synchronous {
            loadChunk(index)
            return table[index]
        }
        return pointer
    }

    func isLoaded(frame: Int) -> Bool {
        let index = frame >> Self.chunkShift
        guard index >= 0, index < chunkCount else { return true }
        return table[index] != nil
    }

    func pin(frame: Int?) {
        pinned.store(frame ?? -1, ordering: .relaxed)
        kick()
    }

    func prefetch(around frame: Int) {
        playhead.store(max(0, frame), ordering: .relaxed)
        kick()
    }

    func kick() {
        guard !resamples else { return }
        guard !pendingWork.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Self.queue.async { [self] in
            pendingWork.store(false, ordering: .releasing)
            maintain()
        }
    }

    func waitUntilLoaded(frame: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let first = max(0, frame) >> Self.chunkShift
        let last = min(chunkCount - 1, (max(0, frame) + 2 * 44_100) >> Self.chunkShift)
        while Date() < deadline {
            var ready = true
            if first <= last {
                for index in first...last where table[index] == nil { ready = false; break }
            }
            if ready { return true }
            kick()
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }

    func close() {
        lock.withLock { closed = true }
    }

    private func wanted(_ index: Int) -> Bool {
        let start = index << Self.chunkShift
        let end = start + Self.chunkFrames
        func near(_ point: Int) -> Bool {
            guard point >= 0 else { return false }
            return end > point - Self.behindFrames && start < point + Self.aheadFrames
        }
        return near(playhead.load(ordering: .relaxed)) || near(pinned.load(ordering: .relaxed))
    }

    func maintain() {
        guard !resamples else { return }
        let now = Date()
        lock.withLock {
            graveyard.removeAll { entry in
                guard now.timeIntervalSince(entry.1) > Self.retireDelay else { return false }
                entry.0.deallocate()
                return true
            }
        }
        var order: [Int] = []
        let head = playhead.load(ordering: .relaxed) >> Self.chunkShift
        let pin = pinned.load(ordering: .relaxed)
        for offset in 0..<(Self.aheadFrames >> Self.chunkShift) + 2 {
            order.append(head + offset)
            if pin >= 0 { order.append((pin >> Self.chunkShift) + offset) }
        }
        for offset in 1...(Self.behindFrames >> Self.chunkShift) + 1 {
            order.append(head - offset)
            if pin >= 0 { order.append((pin >> Self.chunkShift) - offset) }
        }
        for index in order where index >= 0 && index < chunkCount && table[index] == nil && wanted(index) {
            if lock.withLock({ closed }) { return }
            loadChunk(index)
        }
        for index in 0..<chunkCount where table[index] != nil && !wanted(index) {
            lock.withLock {
                guard let pointer = table[index] else { return }
                table[index] = nil
                atomicMemoryFence(ordering: .releasing)
                graveyard.append((pointer, now))
            }
        }
    }

    private func loadChunk(_ index: Int) {
        lock.withLock {
            guard !closed, table[index] == nil else { return }
            let start = index << Self.chunkShift
            let count = min(Self.chunkFrames, frameCount - start)
            guard count > 0 else { return }
            let capacity = AVAudioFrameCount(Self.chunkFrames)
            if readBuffer == nil {
                readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
            }
            guard let buffer = readBuffer else { return }
            buffer.frameLength = 0
            file.framePosition = AVAudioFramePosition(start)
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            } catch {
                missing.add(1, ordering: .relaxed)
                return
            }
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames * 2)
            pointer.initialize(repeating: 0, count: Self.chunkFrames * 2)
            if let channels = buffer.floatChannelData {
                let got = Int(buffer.frameLength)
                let left = channels[0]
                let right = fileChannels > 1 ? channels[1] : channels[0]
                for frame in 0..<got {
                    pointer[frame * 2] = left[frame]
                    pointer[frame * 2 + 1] = right[frame]
                }
            }
            atomicMemoryFence(ordering: .releasing)
            table[index] = pointer
        }
    }

    private func decodeEverythingResampled() throws {
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MixEngineError.unsupportedFormat("cannot convert this sample rate")
        }
        guard duration < 20 * 60 else {
            throw MixEngineError.unsupportedFormat("long audio at this sample rate needs a 44.1 kHz source")
        }
        let blockIn = AVAudioFrameCount(16_384)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: blockIn),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else {
            throw MixEngineError.decodeFailed("could not allocate conversion buffers")
        }
        file.framePosition = 0
        var written = 0
        var finished = false
        let source = file
        while !finished, written < frameCount {
            output.frameLength = 0
            var status: AVAudioConverterOutputStatus = .haveData
            var conversionError: NSError?
            status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                input.frameLength = 0
                do {
                    try source.read(into: input, frameCount: blockIn)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw MixEngineError.decodeFailed(conversionError?.localizedDescription ?? "conversion failed") }
            if status == .endOfStream || output.frameLength == 0 { finished = true }
            guard let channels = output.floatChannelData else { break }
            for frame in 0..<Int(output.frameLength) where written < frameCount {
                let index = written >> Self.chunkShift
                if table[index] == nil {
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames * 2)
                    pointer.initialize(repeating: 0, count: Self.chunkFrames * 2)
                    table[index] = pointer
                }
                let offset = (written & Self.chunkMask) * 2
                table[index]![offset] = channels[0][frame]
                table[index]![offset + 1] = channels[1][frame]
                written += 1
            }
        }
        atomicMemoryFence(ordering: .releasing)
    }
}
