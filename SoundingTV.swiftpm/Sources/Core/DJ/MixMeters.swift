import Foundation
import Synchronization

enum MixMeterChannel: Int, CaseIterable, Sendable {
    case deckA = 0
    case deckB = 1
    case master = 2
    case phones = 3
    case masterLeft = 4
    case masterRight = 5

    static func deck(_ index: Int) -> MixMeterChannel { index == 0 ? .deckA : .deckB }
}

struct MixMeterReading: Equatable, Sendable {
    var peak: Float = 0
    var rms: Float = 0
    var clips = 0
}

final class MixMeterSlot: @unchecked Sendable {
    let peak = Atomic<UInt32>(0)
    let level = Atomic<UInt32>(0)
    let clips = Atomic<Int>(0)
    var smoothed: Float = 0
}

final class MixMeterBank: @unchecked Sendable {
    static let clipThreshold: Float = 1

    private let slots: [MixMeterSlot] = MixMeterChannel.allCases.map { _ in MixMeterSlot() }

    @inline(__always)
    func record(_ channel: MixMeterChannel, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        guard frames > 0 else { return }
        var peak: Float = 0
        var sum: Float = 0
        var clipped = 0
        for n in 0..<frames {
            let l = abs(left[n])
            let r = abs(right[n])
            let m = max(l, r)
            if m > peak { peak = m }
            if m >= Self.clipThreshold { clipped += 1 }
            sum += left[n] * left[n] + right[n] * right[n]
        }
        let rms = (sum / Float(2 * frames)).squareRoot()
        let slot = slots[channel.rawValue]
        let alpha = Float(1 - exp(-Double(frames) / (0.3 * sampleRate)))
        slot.smoothed += (rms - slot.smoothed) * alpha
        if slot.smoothed < 1e-6 { slot.smoothed = 0 }
        slot.level.store(slot.smoothed.bitPattern, ordering: .relaxed)
        raisePeak(slot, peak)
        if clipped > 0 { slot.clips.add(clipped, ordering: .relaxed) }
    }

    @inline(__always)
    func clear(_ channel: MixMeterChannel, frames: Int, sampleRate: Double) {
        let slot = slots[channel.rawValue]
        guard slot.smoothed > 0 else { return }
        let alpha = Float(1 - exp(-Double(frames) / (0.3 * sampleRate)))
        slot.smoothed -= slot.smoothed * alpha
        if slot.smoothed < 1e-6 { slot.smoothed = 0 }
        slot.level.store(slot.smoothed.bitPattern, ordering: .relaxed)
    }

    @inline(__always)
    private func raisePeak(_ slot: MixMeterSlot, _ value: Float) {
        guard value > 0 else { return }
        let bits = value.bitPattern
        var current = slot.peak.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = slot.peak.compareExchange(expected: current, desired: bits, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    func take(_ channel: MixMeterChannel) -> MixMeterReading {
        let slot = slots[channel.rawValue]
        let peak = Float(bitPattern: slot.peak.exchange(0, ordering: .relaxed))
        let rms = Float(bitPattern: slot.level.load(ordering: .relaxed))
        let clips = slot.clips.exchange(0, ordering: .relaxed)
        return MixMeterReading(peak: peak, rms: rms, clips: clips)
    }
}

final class MixPhonesRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(frames: Int = 16_384) {
        capacity = frames
        storage = .allocate(capacity: frames * 2)
        storage.initialize(repeating: 0, count: frames * 2)
    }

    deinit {
        storage.deallocate()
    }

    var available: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let room = capacity - (t - h)
        let count = min(frames, room)
        for n in 0..<count {
            let slot = ((t + n) % capacity) * 2
            storage[slot] = left[n]
            storage[slot + 1] = right[n]
        }
        tail.store(t + count, ordering: .releasing)
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, target: Int) -> Int {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if t - h > target * 2 {
            h = t - target
        }
        let count = min(frames, t - h)
        for n in 0..<count {
            let slot = ((h + n) % capacity) * 2
            left[n] = storage[slot]
            right[n] = storage[slot + 1]
        }
        for n in count..<max(count, frames) {
            left[n] = 0
            right[n] = 0
        }
        head.store(h + count, ordering: .releasing)
        return count
    }

    func reset() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}

struct DJMeterBallistics: Equatable, Sendable {
    static let holdSeconds: Double = 1.5
    static let fallDecibelsPerSecond: Double = 20
    static let clipLatchSeconds: Double = 2

    var level: Float = 0
    var peak: Float = 0
    var heldPeak: Float = 0
    var heldAt: Double = -.infinity
    var clippedAt: Double = -.infinity

    var isClipping: Bool { clippedUntil > lastUpdate }
    private var clippedUntil: Double = -.infinity
    private var lastUpdate: Double = 0

    mutating func update(_ reading: MixMeterReading, at time: Double) {
        let elapsed = max(0, time - lastUpdate)
        lastUpdate = time
        level = reading.rms
        let fall = Float(pow(10, -Self.fallDecibelsPerSecond * elapsed / 20))
        peak = max(reading.peak, peak * fall)
        if peak < 1e-5 { peak = 0 }
        if reading.peak >= heldPeak {
            heldPeak = reading.peak
            heldAt = time
        } else if time - heldAt > Self.holdSeconds {
            heldPeak = max(peak, heldPeak * fall)
            if heldPeak < 1e-5 { heldPeak = 0 }
        }
        if reading.clips > 0 {
            clippedAt = time
            clippedUntil = time + Self.clipLatchSeconds
        }
    }

    mutating func resetClip() {
        clippedUntil = -.infinity
    }

    static func meterFraction(_ amplitude: Float, floorDecibels: Double = -48) -> Double {
        guard amplitude > 0 else { return 0 }
        let decibels = 20 * log10(Double(amplitude))
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}
