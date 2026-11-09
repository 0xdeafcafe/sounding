import Foundation

struct SonosStreamPacer: Sendable, Equatable {
    struct Step: Sendable, Equatable {
        var read: Int
        var discard: Int
        var silence: Int
    }

    static let defaultLeadSeconds: TimeInterval = 0.25
    static let defaultLagSeconds: TimeInterval = 0.3
    static let defaultBacklogSeconds: TimeInterval = 0.75
    static let defaultResyncSeconds: TimeInterval = 3

    let sampleRate: Double
    let leadFrames: Int
    let lagFrames: Int
    let backlogFrames: Int
    let resyncFrames: Int
    private(set) var emittedFrames: UInt64 = 0
    private(set) var skippedFrames: UInt64 = 0
    private var anchorNanoseconds: UInt64?

    init(
        sampleRate: Double,
        leadSeconds: TimeInterval = Self.defaultLeadSeconds,
        lagSeconds: TimeInterval = Self.defaultLagSeconds,
        backlogSeconds: TimeInterval = Self.defaultBacklogSeconds,
        resyncSeconds: TimeInterval = Self.defaultResyncSeconds
    ) {
        self.sampleRate = max(1, sampleRate)
        leadFrames = max(0, Int(leadSeconds * self.sampleRate))
        lagFrames = max(0, Int(lagSeconds * self.sampleRate))
        backlogFrames = max(0, Int(backlogSeconds * self.sampleRate))
        resyncFrames = max(lagFrames, Int(resyncSeconds * self.sampleRate))
    }

    mutating func reset(at now: UInt64) {
        anchorNanoseconds = now
        emittedFrames = 0
        skippedFrames = 0
    }

    func targetFrames(at now: UInt64) -> UInt64 {
        guard let anchorNanoseconds, now > anchorNanoseconds else { return 0 }
        let elapsed = Double(now - anchorNanoseconds) / 1_000_000_000
        let frames = UInt64((elapsed * sampleRate).rounded(.down))
        return frames > skippedFrames ? frames - skippedFrames : 0
    }

    mutating func step(at now: UInt64, available: Int) -> Step {
        if anchorNanoseconds == nil { reset(at: now) }
        let available = max(0, available)
        let target = Int64(clamping: targetFrames(at: now))
        let emitted = Int64(clamping: emittedFrames)
        let budget = max(0, target + Int64(leadFrames) - emitted)
        let discard = max(0, available - Int(clamping: budget) - backlogFrames)
        let read = min(available - discard, Int(clamping: budget))
        let backlog = available - discard - read
        var lag = target - (emitted + Int64(read))
        if lag > Int64(resyncFrames) {
            skippedFrames &+= UInt64(lag - Int64(resyncFrames))
            lag = Int64(resyncFrames)
        }
        let silence = backlog == 0 && lag > Int64(lagFrames) ? Int(lag) : 0
        emittedFrames &+= UInt64(read + silence)
        return Step(read: read, discard: discard, silence: silence)
    }
}
