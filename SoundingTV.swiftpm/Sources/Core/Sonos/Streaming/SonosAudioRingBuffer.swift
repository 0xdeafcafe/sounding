import Foundation
import AVFoundation
import Synchronization

final class SonosAudioRingBuffer: @unchecked Sendable {
    static let maximumChannels = 8

    let capacityFrames: Int
    let channels: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let dropped = Atomic<UInt64>(0)

    init(capacityFrames: Int, channels: Int) {
        precondition(capacityFrames > 0 && channels > 0 && channels <= Self.maximumChannels)
        self.capacityFrames = capacityFrames
        self.channels = channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit {
        storage.deallocate()
    }

    var framesWritten: UInt64 { writeIndex.load(ordering: .acquiring) }
    var framesRead: UInt64 { readIndex.load(ordering: .acquiring) }
    var droppedFrames: UInt64 { dropped.load(ordering: .relaxed) }

    var availableFrames: Int {
        let read = readIndex.load(ordering: .acquiring)
        let written = writeIndex.load(ordering: .acquiring)
        return Int(written &- read)
    }

    @discardableResult
    func write(_ buffers: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int) -> Int {
        guard frames > 0, channelCount > 0 else { return 0 }
        let written = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacityFrames - Int(written &- read)
        let count = min(frames, max(0, free))
        if count < frames {
            dropped.add(UInt64(frames - count), ordering: .relaxed)
        }
        guard count > 0 else { return 0 }
        let start = Int(written % UInt64(capacityFrames))
        let first = min(count, capacityFrames - start)
        for channel in 0..<channels {
            let source = UnsafePointer(buffers[min(channel, channelCount - 1)])
            let destination = storage + channel * capacityFrames
            (destination + start).update(from: source, count: first)
            if count > first {
                destination.update(from: source + first, count: count - first)
            }
        }
        writeIndex.store(written &+ UInt64(count), ordering: .releasing)
        return count
    }

    @discardableResult
    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = min(buffers.count, Self.maximumChannels)
        guard count > 0 else { return 0 }
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: Self.maximumChannels) { pointers in
            for index in 0..<count {
                guard let data = buffers[index].mData else { return 0 }
                pointers[index] = data.assumingMemoryBound(to: Float.self)
            }
            return write(UnsafePointer(pointers.baseAddress!), channelCount: count, frames: frames)
        }
    }

    @discardableResult
    func read(into buffers: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int) -> Int {
        guard frames > 0, channelCount > 0 else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let written = writeIndex.load(ordering: .acquiring)
        let count = min(frames, Int(written &- read))
        guard count > 0 else { return 0 }
        let start = Int(read % UInt64(capacityFrames))
        let first = min(count, capacityFrames - start)
        for channel in 0..<min(channels, channelCount) {
            let source = storage + channel * capacityFrames
            buffers[channel].update(from: source + start, count: first)
            if count > first {
                (buffers[channel] + first).update(from: source, count: count - first)
            }
        }
        if channelCount > channels {
            for channel in channels..<channelCount {
                buffers[channel].update(from: buffers[channels - 1], count: count)
            }
        }
        readIndex.store(read &+ UInt64(count), ordering: .releasing)
        return count
    }

    @discardableResult
    func discard(frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let written = writeIndex.load(ordering: .acquiring)
        let count = min(frames, Int(written &- read))
        guard count > 0 else { return 0 }
        readIndex.store(read &+ UInt64(count), ordering: .releasing)
        return count
    }
}
