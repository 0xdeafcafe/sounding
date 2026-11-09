import Foundation
import Accelerate
import Synchronization
import Darwin

final class MixBeatTable: @unchecked Sendable {
    let frames: UnsafeMutablePointer<Double>
    let isDownbeat: UnsafeMutablePointer<Bool>
    let count: Int

    init?(grid: BeatGrid, sampleRate: Double) {
        guard grid.isPhaseVerified, let beats = grid.beats, beats.count >= 8 else { return nil }
        let sorted = beats.filter(\.isFinite).sorted()
        guard sorted.count >= 8 else { return nil }
        count = sorted.count
        frames = .allocate(capacity: count)
        isDownbeat = .allocate(capacity: count)
        let downbeats = (grid.downbeats ?? []).sorted()
        var cursor = 0
        for (index, beat) in sorted.enumerated() {
            frames[index] = beat * sampleRate
            while cursor < downbeats.count, downbeats[cursor] < beat - 0.01 { cursor += 1 }
            isDownbeat[index] = cursor < downbeats.count && abs(downbeats[cursor] - beat) <= 0.01
        }
    }

    deinit {
        frames.deallocate()
        isDownbeat.deallocate()
    }

    func firstIndex(atOrAfter frame: Double) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid] < frame { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func nearestIndex(to frame: Double) -> Int {
        let after = firstIndex(atOrAfter: frame)
        if after >= count { return count - 1 }
        if after == 0 { return 0 }
        return frame - frames[after - 1] <= frames[after] - frame ? after - 1 : after
    }

    func localPeriod(at index: Int) -> Double {
        let lo = max(0, min(index - 4, count - 9))
        let hi = min(count - 1, lo + 8)
        guard hi > lo else { return 0 }
        return (frames[hi] - frames[lo]) / Double(hi - lo)
    }
}

enum MixCommand {
    case none
    case event(seq: Int64, time: Int64, immediate: Bool, group: Int32, action: MixTimelineAction)
    case anchor(seq: Int64, group: Int32, anchor: MixTimelineAnchor)
    case cancelGroup(seq: Int64, group: Int32)
    case load(seq: Int64, deck: Int, source: Unmanaged<MixSource>?)
    case beats(seq: Int64, deck: Int, table: Unmanaged<MixBeatTable>?)
    case insert(seq: Int64, slot: Int, host: Unmanaged<MixAudioUnitHost>?)
    case freeze(seq: Int64, frozen: Bool)
    case jumpClock(seq: Int64, frames: Int64)
    case solo(seq: Int64, deck: Int)
    case own(seq: Int64, mask: UInt64)
    case restoreGroup(seq: Int64, group: Int32)

    var sequence: Int64 {
        switch self {
        case .none: return 0
        case .event(let seq, _, _, _, _), .anchor(let seq, _, _), .cancelGroup(let seq, _),
             .load(let seq, _, _), .beats(let seq, _, _), .insert(let seq, _, _),
             .freeze(let seq, _), .jumpClock(let seq, _), .solo(let seq, _), .own(let seq, _), .restoreGroup(let seq, _):
            return seq
        }
    }
}

final class MixCommandRing: @unchecked Sendable {
    let capacity = 4096
    private let slots: UnsafeMutablePointer<MixCommand>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init() {
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: .none, count: capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    func push(_ command: MixCommand) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t - h < capacity else { return false }
        slots[t % capacity] = command
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    func pop() -> MixCommand? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h != t else { return nil }
        let command = slots[h % capacity]
        head.store(h + 1, ordering: .releasing)
        return command
    }
}

struct MixDeckSnapshot {
    var position: Double = 0
    var content: Double = 0
    var playing = false
    var ended = false
    var sourceID = 0
    var beatsID = 0
    var insertID = 0
    var rate = 1.0
    var pitch = 0.0
    var gain = 1.0
    var inputGain = 0.0
    var low = 0.0
    var mid = 0.0
    var high = 0.0
    var lowPass = 20_000.0
    var highPass = 30.0
    var resonance = 0.0
    var echoSend = 0.0
    var reverbSend = 0.0
    var auxSend = 0.0
    var holdTail = false
    var loopStart = -1.0
    var loopLength = 0.0
    var rms: Float = 0
    var peak: Float = 0
    var splices = 0
    var missing = 0
    var lockErrorMs = 0.0
    var lockCorrections = 0
    var locked = false
    var beatOffsetMax = 0.0
    var beatOffsetSum = 0.0
    var beatOffsetCount = 0
}

struct MixCoreSnapshot {
    var frame: Int64 = 0
    var clock: Int64 = 0
    var hostTime: UInt64 = 0
    var appliedSequence: Int64 = 0
    var frozen = false
    var a = MixDeckSnapshot()
    var b = MixDeckSnapshot()
    var crossfade = 0.0
    var master = 1.0
    var echoFeedback = 0.45
    var limiterReduction = 1.0
    var renderNanos: UInt64 = 0
    var renderedFrames: Int64 = 0
    var maxQuantumNanos: UInt64 = 0
    var quanta: Int64 = 0
    var auxID = 0
    var anchorGroups: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var anchorClocks: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
    var droppedCommands = 0
    var missedAnchors = 0

    func deck(_ index: Int) -> MixDeckSnapshot { index == 0 ? a : b }

    func anchorClock(for group: Int32) -> Int64? {
        if anchorGroups.0 == group { return anchorClocks.0 }
        if anchorGroups.1 == group { return anchorClocks.1 }
        if anchorGroups.2 == group { return anchorClocks.2 }
        if anchorGroups.3 == group { return anchorClocks.3 }
        return nil
    }
}

private struct MixParamState {
    var from: Double
    var to: Double
    var start: Int64 = 0
    var length: Int64 = 0
    var curve: MixCurve = .linear

    @inline(__always)
    func value(at clock: Int64) -> Double {
        guard length > 0 else { return to }
        if clock <= start { return from }
        let t = Double(clock - start) / Double(length)
        return t >= 1 ? to : curve.interpolate(from: from, to: to, t: t)
    }

    func isRamping(at clock: Int64) -> Bool { length > 0 && clock < start + length }

    func display(at clock: Int64) -> Double {
        length > 0 && start + length - clock <= 512 ? to : value(at: clock)
    }
}

private struct MixPendingEvent {
    var time: Int64
    var group: Int32
    var resolved: Bool
    var order: Int64
    var action: MixTimelineAction
}

private struct MixPendingAnchor {
    var group: Int32
    var anchor: MixTimelineAnchor
    var armed = true
    var last = 0.0
}

private struct MixInterpolated {
    var v0: Double = 0
    var step: Double = 0

    @inline(__always)
    func at(_ k: Int) -> Double { v0 + step * Double(k) }
}

final class MixCoreDeck {
    let index: Int
    var source: Unmanaged<MixSource>?
    var sourceID = 0
    var sourceFrames = 0
    var beats: Unmanaged<MixBeatTable>?
    var beatsID = 0
    var insert: Unmanaged<MixAudioUnitHost>?
    var insertID = 0
    var insertLatency = 0
    let dryAlign = MixLatencyDelay()
    let compensation = MixLatencyDelay()

    var playing = false
    var stopping = false
    var ended = false
    var envelope = 0.0
    var nominal = 0.0
    var content = 0.0
    var oldContent = 0.0
    var fadeRemaining = 0
    var fadeLength = 0
    var fadeOldEnergy = 1.0
    var fadeNewEnergy = 1.0
    var fadeCross = 1.0
    var loopStart = -1.0
    var loopLength = 0.0
    var loopOwner: Int32 = 0
    var loopOriginClock: Int64 = 0
    var loopOriginFrame = 0.0
    var nextAnchor = 0
    var lockReference = -1
    var lockBeat = 0
    var lockErrorMs = 0.0
    var lockCorrections = 0
    var splices = 0
    var missing = 0
    var silentForFrames = 1 << 40
    var beatOffsetMax = 0.0
    var beatOffsetSum = 0.0
    var beatOffsetCount = 0

    var isolatorL: MixIsolatorChannel
    var isolatorR: MixIsolatorChannel
    var lowPassL = MixStateVariableFilter()
    var lowPassR = MixStateVariableFilter()
    var highPassL = MixStateVariableFilter()
    var highPassR = MixStateVariableFilter()
    var lowPassMix = 0.0
    var highPassMix = 0.0

    var rms: Float = 0
    var peak: Float = 0

    var cacheIndex = -1
    var cachePointer: UnsafeMutablePointer<Float>?

    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let channelGain: UnsafeMutablePointer<Float>
    let echoGain: UnsafeMutablePointer<Float>
    let reverbGain: UnsafeMutablePointer<Float>
    let auxGain: UnsafeMutablePointer<Float>
    let insertMix: UnsafeMutablePointer<Float>
    let dryLeft: UnsafeMutablePointer<Float>
    let dryRight: UnsafeMutablePointer<Float>
    let fxSend: UnsafeMutablePointer<Float>
    let fxWet: UnsafeMutablePointer<Float>
    let cueGain: UnsafeMutablePointer<Float>
    let fx: MixDeckFX

    init(index: Int, sampleRate: Double, capacity: Int) {
        self.index = index
        fx = MixDeckFX(sampleRate: sampleRate, capacity: capacity)
        isolatorL = MixIsolatorChannel(sampleRate: sampleRate)
        isolatorR = isolatorL
        func buffer() -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
        left = buffer()
        right = buffer()
        channelGain = buffer()
        echoGain = buffer()
        reverbGain = buffer()
        auxGain = buffer()
        insertMix = buffer()
        dryLeft = buffer()
        dryRight = buffer()
        fxSend = buffer()
        fxWet = buffer()
        cueGain = buffer()
    }

    deinit {
        for pointer in [left, right, channelGain, echoGain, reverbGain, auxGain, insertMix, dryLeft, dryRight, fxSend, fxWet, cueGain] {
            pointer.deallocate()
        }
    }

    @inline(__always)
    func frame(_ i: Int) -> (Float, Float) {
        guard i >= 0, i < sourceFrames, let source else { return (0, 0) }
        let chunk = i >> MixSource.chunkShift
        if chunk != cacheIndex {
            cacheIndex = chunk
            cachePointer = source._withUnsafeGuaranteedRef { $0.chunk(chunk) }
            if cachePointer == nil { missing += 1 }
        }
        guard let pointer = cachePointer else { return (0, 0) }
        let offset = (i & MixSource.chunkMask) << 1
        return (pointer[offset], pointer[offset + 1])
    }

    @inline(__always)
    func read(_ position: Double, integral: Bool) -> (Double, Double) {
        if integral {
            let s = frame(Int(position))
            return (Double(s.0), Double(s.1))
        }
        let base = position.rounded(.down)
        let i = Int(base)
        let t = position - base
        let p0 = frame(i - 1)
        let p1 = frame(i)
        let p2 = frame(i + 1)
        let p3 = frame(i + 2)
        func hermite(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float) -> Double {
            let a = Double(y0), b = Double(y1), c = Double(y2), d = Double(y3)
            let c0 = b
            let c1 = 0.5 * (c - a)
            let c2 = a - 2.5 * b + 2 * c - 0.5 * d
            let c3 = 0.5 * (d - a) + 1.5 * (b - c)
            return ((c3 * t + c2) * t + c1) * t + c0
        }
        return (hermite(p0.0, p1.0, p2.0, p3.0), hermite(p0.1, p1.1, p2.1, p3.1))
    }

    @inline(__always)
    func mono(_ i: Int) -> Float {
        let s = frame(i)
        return s.0 + s.1
    }

    func measureFade(from old: Double, to new: Double, length: Int, step: Double) {
        var oldEnergy = 0.0
        var newEnergy = 0.0
        var cross = 0.0
        for k in 0..<length {
            let offset = Double(k) * step
            let a = Double(mono(Int((old + offset).rounded())))
            let b = Double(mono(Int((new + offset).rounded())))
            oldEnergy += a * a
            newEnergy += b * b
            cross += a * b
        }
        if oldEnergy + newEnergy < 1e-9 {
            fadeOldEnergy = 1
            fadeNewEnergy = 1
            fadeCross = 1
        } else {
            fadeOldEnergy = oldEnergy
            fadeNewEnergy = newEnergy
            fadeCross = cross
        }
    }

    static let seamCompensationCeiling = 2.0.squareRoot()

    @inline(__always)
    func fadeCompensation(_ w: Double) -> Double {
        let a = 1 - w
        let mixed = a * a * fadeOldEnergy + w * w * fadeNewEnergy + 2 * a * w * fadeCross
        let target = a * fadeOldEnergy + w * fadeNewEnergy
        guard mixed > target * 0.5 else { return Self.seamCompensationCeiling }
        return min(Self.seamCompensationCeiling, (target / mixed).squareRoot())
    }
}

final class MixRenderCore: @unchecked Sendable {
    static let cell = 32
    static let capacity = 4096
    static let spliceFade = 256
    static let sustainedSpliceFade = 1024
    static let sustainedCorrelation = 0.8
    static let seekFade = 128
    static let loopFade = 256
    static let envelopeFrames = 64.0
    static let correlationLength = 384
    static let maximumDrift = 176.0
    static let anchorTolerance = 40.0
    static let settleTolerance = 24.0
    static let periodSearch = 1024

    let sampleRate: Double
    let ring = MixCommandRing()
    let decks: [MixCoreDeck]

    private let params: UnsafeMutablePointer<MixParamState>
    private let interpolated: UnsafeMutablePointer<MixInterpolated>
    private let held: UnsafeMutablePointer<Double>
    private let paramOwner: UnsafeMutablePointer<Int32>
    private let paramBefore: UnsafeMutablePointer<Double>
    private var pending: UnsafeMutablePointer<MixPendingEvent>
    private let pendingCapacity = 2048
    private var pendingCount = 0
    private var eventOrder: Int64 = 0
    private var anchors: UnsafeMutablePointer<MixPendingAnchor>
    private let anchorCapacity = 16
    private var anchorCount = 0

    private(set) var frame: Int64 = 0
    private(set) var clock: Int64 = 0
    private var frozen = false
    private var appliedSequence: Int64 = 0
    private var solo = -1
    private var ownedMask: UInt64 = 0
    private var aux: Unmanaged<MixAudioUnitHost>?
    private var auxID = 0
    private var auxLatency = 0
    private let auxAlign = MixLatencyDelay()
    private var droppedCommands = 0
    private var missedAnchors = 0
    private var resolvedGroups: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    private var resolvedClocks: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
    private var interpolationDirty = true

    private let echo: MixEcho
    private let reverb: MixReverb
    private let riser: MixRiser
    private let limiter: MixLimiter
    private let mixLeft: UnsafeMutablePointer<Float>
    private let mixRight: UnsafeMutablePointer<Float>
    private let busA: UnsafeMutablePointer<Float>
    private let busB: UnsafeMutablePointer<Float>
    private let busC: UnsafeMutablePointer<Float>
    private let busD: UnsafeMutablePointer<Float>
    private let masterGain: UnsafeMutablePointer<Float>
    private let feedbackGain: UnsafeMutablePointer<Float>
    private let echoReturnGain: UnsafeMutablePointer<Float>
    private let reverbReturnGain: UnsafeMutablePointer<Float>
    private let auxReturnGain: UnsafeMutablePointer<Float>
    private let riserGain: UnsafeMutablePointer<Float>
    private let riserSweep: UnsafeMutablePointer<Float>
    private let cueMixGain: UnsafeMutablePointer<Float>
    private let phonesGain: UnsafeMutablePointer<Float>
    private let splitGain: UnsafeMutablePointer<Float>
    private let cueLeft: UnsafeMutablePointer<Float>
    private let cueRight: UnsafeMutablePointer<Float>
    private let phonesLeft: UnsafeMutablePointer<Float>
    private let phonesRight: UnsafeMutablePointer<Float>
    private var riserLive = false
    let meters = MixMeterBank()
    let phonesRing = MixPhonesRing()
    let phonesActive = Atomic<Bool>(false)
    var phonesRequested = false
    private let correlationReference: UnsafeMutablePointer<Float>
    private let correlationCandidates: UnsafeMutablePointer<Float>
    private let correlationOutput: UnsafeMutablePointer<Float>
    private var echoActiveFrames = 0
    private var reverbActiveFrames = 0

    private var renderNanos: UInt64 = 0
    private var maxQuantumNanos: UInt64 = 0
    private var quanta: Int64 = 0
    private var renderedFrames: Int64 = 0
    private let timebase: mach_timebase_info_data_t

    private let snapshotVersion = Atomic<UInt64>(0)
    private let snapshotStorage: UnsafeMutablePointer<MixCoreSnapshot>

    init(sampleRate: Double = DJEngineConstants.canonicalSampleRate) {
        self.sampleRate = sampleRate
        decks = [
            MixCoreDeck(index: 0, sampleRate: sampleRate, capacity: Self.capacity),
            MixCoreDeck(index: 1, sampleRate: sampleRate, capacity: Self.capacity)
        ]
        params = .allocate(capacity: MixParameter.count)
        for raw in 0..<MixParameter.count {
            let value = MixParameter(raw: raw).defaultValue
            params[raw] = MixParamState(from: value, to: value)
        }
        interpolated = .allocate(capacity: MixParameter.count)
        interpolated.initialize(repeating: MixInterpolated(), count: MixParameter.count)
        held = .allocate(capacity: MixParameter.count)
        held.initialize(repeating: 0, count: MixParameter.count)
        paramOwner = .allocate(capacity: MixParameter.count)
        paramOwner.initialize(repeating: 0, count: MixParameter.count)
        paramBefore = .allocate(capacity: MixParameter.count)
        paramBefore.initialize(repeating: 0, count: MixParameter.count)
        pending = .allocate(capacity: pendingCapacity)
        anchors = .allocate(capacity: anchorCapacity)
        echo = MixEcho(sampleRate: sampleRate)
        reverb = MixReverb(sampleRate: sampleRate)
        riser = MixRiser(sampleRate: sampleRate)
        limiter = MixLimiter(sampleRate: sampleRate)
        func buffer(_ count: Int = MixRenderCore.capacity) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        mixLeft = buffer()
        mixRight = buffer()
        busA = buffer()
        busB = buffer()
        busC = buffer()
        busD = buffer()
        masterGain = buffer()
        feedbackGain = buffer()
        echoReturnGain = buffer()
        reverbReturnGain = buffer()
        auxReturnGain = buffer()
        riserGain = buffer()
        riserSweep = buffer()
        cueMixGain = buffer()
        phonesGain = buffer()
        splitGain = buffer()
        cueLeft = buffer()
        cueRight = buffer()
        phonesLeft = buffer()
        phonesRight = buffer()
        correlationReference = buffer(Self.correlationLength)
        correlationCandidates = buffer(Self.correlationLength + 2 * Self.periodSearch + 64)
        correlationOutput = buffer(2 * Self.periodSearch + 64)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
        snapshotStorage = .allocate(capacity: 1)
        snapshotStorage.initialize(to: MixCoreSnapshot())
        for raw in 0..<MixParameter.count { held[raw] = params[raw].to }
    }

    deinit {
        params.deallocate()
        interpolated.deallocate()
        held.deallocate()
        paramOwner.deallocate()
        paramBefore.deallocate()
        pending.deallocate()
        anchors.deallocate()
        for pointer in [mixLeft, mixRight, busA, busB, busC, busD, masterGain, feedbackGain,
                        echoReturnGain, reverbReturnGain, auxReturnGain, riserGain, riserSweep,
                        cueMixGain, phonesGain, splitGain, cueLeft, cueRight, phonesLeft, phonesRight, correlationReference,
                        correlationCandidates, correlationOutput] {
            pointer.deallocate()
        }
        snapshotStorage.deallocate()
    }

    // MARK: - Snapshot

    func snapshot() -> MixCoreSnapshot {
        while true {
            let before = snapshotVersion.load(ordering: .acquiring)
            if before & 1 == 1 { continue }
            let value = snapshotStorage.pointee
            atomicMemoryFence(ordering: .acquiring)
            let after = snapshotVersion.load(ordering: .relaxed)
            if before == after { return value }
        }
    }

    private func publish() {
        var s = MixCoreSnapshot()
        s.frame = frame
        s.clock = clock
        s.hostTime = mach_absolute_time()
        s.appliedSequence = appliedSequence
        s.frozen = frozen
        s.a = deckSnapshot(decks[0])
        s.b = deckSnapshot(decks[1])
        s.crossfade = params[MixParameter.crossfade.raw].display(at: clock)
        s.master = params[MixParameter.master.raw].display(at: clock)
        s.echoFeedback = params[MixParameter.echoFeedback.raw].value(at: clock)
        s.limiterReduction = limiter.reduction
        s.renderNanos = renderNanos
        s.renderedFrames = renderedFrames
        s.maxQuantumNanos = maxQuantumNanos
        s.quanta = quanta
        s.auxID = auxID
        s.anchorGroups = resolvedGroups
        s.anchorClocks = resolvedClocks
        s.droppedCommands = droppedCommands
        s.missedAnchors = missedAnchors
        let version = snapshotVersion.load(ordering: .relaxed)
        snapshotVersion.store(version &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        snapshotStorage.pointee = s
        snapshotVersion.store(version &+ 2, ordering: .releasing)
    }

    private func deckSnapshot(_ deck: MixCoreDeck) -> MixDeckSnapshot {
        let d = deck.index
        var s = MixDeckSnapshot()
        s.position = deck.nominal
        s.content = deck.content
        s.playing = deck.playing && !deck.stopping
        s.ended = deck.ended
        s.sourceID = deck.sourceID
        s.beatsID = deck.beatsID
        s.insertID = deck.insertID
        s.rate = params[MixParameter.rate(d).raw].display(at: clock)
        s.pitch = params[MixParameter.pitch(d).raw].display(at: clock)
        s.gain = params[MixParameter.gain(d).raw].display(at: clock)
        s.inputGain = params[MixParameter.inputGain(d).raw].display(at: clock)
        s.low = params[MixParameter.eqLow(d).raw].display(at: clock)
        s.mid = params[MixParameter.eqMid(d).raw].display(at: clock)
        s.high = params[MixParameter.eqHigh(d).raw].display(at: clock)
        s.lowPass = params[MixParameter.lowPass(d).raw].display(at: clock)
        s.highPass = params[MixParameter.highPass(d).raw].display(at: clock)
        s.resonance = params[MixParameter.resonance(d).raw].display(at: clock)
        s.echoSend = params[MixParameter.echoSend(d).raw].display(at: clock)
        s.reverbSend = params[MixParameter.reverbSend(d).raw].display(at: clock)
        s.auxSend = params[MixParameter.auxSend(d).raw].display(at: clock)
        s.holdTail = params[MixParameter.holdTail(d).raw].display(at: clock) > 0.5
        s.loopStart = deck.loopLength > 0 ? deck.loopStart : -1
        s.loopLength = deck.loopLength
        s.rms = deck.rms
        s.peak = deck.peak
        s.splices = deck.splices
        s.missing = deck.missing
        s.lockErrorMs = deck.lockErrorMs
        s.lockCorrections = deck.lockCorrections
        s.locked = deck.lockReference >= 0
        s.beatOffsetMax = deck.beatOffsetMax
        s.beatOffsetSum = deck.beatOffsetSum
        s.beatOffsetCount = deck.beatOffsetCount
        return s
    }

    // MARK: - Commands

    private func drain() {
        while let command = ring.pop() {
            appliedSequence = max(appliedSequence, command.sequence)
            switch command {
            case .none:
                break
            case .event(_, let time, let immediate, let group, let action):
                let when = immediate ? clock : time
                insertEvent(time: when, group: group, resolved: group == 0, action: action)
            case .anchor(_, let group, let anchor):
                switch anchor {
                case .now:
                    resolve(group: group, at: clock)
                case .clock(let t):
                    resolve(group: group, at: t)
                case .deckPosition(let deckIndex, let target):
                    guard anchorCount < anchorCapacity else { missedAnchors += 1; break }
                    var pendingAnchor = MixPendingAnchor(group: group, anchor: anchor)
                    if deckIndex < decks.count {
                        let deck = decks[deckIndex]
                        let loopEnd = deck.loopStart + deck.loopLength
                        if deck.loopLength > 0, target >= deck.loopStart - 1, target < loopEnd, deck.nominal > target + Self.anchorTolerance {
                            pendingAnchor.armed = false
                            pendingAnchor.last = deck.nominal
                        }
                    }
                    anchors[anchorCount] = pendingAnchor
                    anchorCount += 1
                }
            case .cancelGroup(_, let group):
                cancel(group: group)
            case .restoreGroup(_, let group):
                cancel(group: group)
                restore(group: group)
            case .load(_, let deckIndex, let source):
                let deck = decks[deckIndex]
                deck.source = source
                deck.sourceID = source.map { Int(bitPattern: $0.toOpaque()) } ?? 0
                deck.sourceFrames = source.map { $0._withUnsafeGuaranteedRef { $0.frameCount } } ?? 0
                deck.cacheIndex = -1
                deck.cachePointer = nil
                deck.playing = false
                deck.stopping = false
                deck.ended = false
                deck.envelope = 0
                deck.nominal = 0
                deck.content = 0
                deck.fadeRemaining = 0
                deck.loopLength = 0
                deck.loopStart = -1
                deck.nextAnchor = 0
                deck.lockReference = -1
                resetFilters(deck)
            case .beats(_, let deckIndex, let table):
                let deck = decks[deckIndex]
                deck.beats = table
                deck.beatsID = table.map { Int(bitPattern: $0.toOpaque()) } ?? 0
                reindexAnchors(deck)
            case .insert(_, let slot, let host):
                let latency = host.map { $0._withUnsafeGuaranteedRef { $0.latencyFrames } } ?? 0
                if slot < decks.count {
                    decks[slot].insert = host
                    decks[slot].insertID = host.map { Int(bitPattern: $0.toOpaque()) } ?? 0
                    decks[slot].insertLatency = latency
                    decks[slot].dryAlign.setDelay(latency)
                } else {
                    aux = host
                    auxID = host.map { Int(bitPattern: $0.toOpaque()) } ?? 0
                    auxLatency = latency
                    auxAlign.setDelay(latency)
                }
                let worst = decks.reduce(0) { max($0, $1.insertLatency) }
                for deck in decks { deck.compensation.setDelay(worst - deck.insertLatency) }
            case .freeze(_, let value):
                frozen = value
                interpolationDirty = true
            case .jumpClock(_, let frames):
                if frames > 0 {
                    clock += frames
                    interpolationDirty = true
                }
            case .solo(_, let deck):
                solo = deck
                interpolationDirty = true
            case .own(_, let mask):
                ownedMask = mask
            }
        }
    }

    static let restoreFrames: Int64 = 2_048

    private func cancel(group: Int32) {
        var write = 0
        for read in 0..<pendingCount where pending[read].group != group {
            pending[write] = pending[read]
            write += 1
        }
        pendingCount = write
        var anchorWrite = 0
        for read in 0..<anchorCount where anchors[read].group != group {
            anchors[anchorWrite] = anchors[read]
            anchorWrite += 1
        }
        anchorCount = anchorWrite
    }

    private func restore(group: Int32) {
        guard group != 0 else { return }
        for raw in 0..<MixParameter.count where paramOwner[raw] == group {
            paramOwner[raw] = 0
            let parameter = MixParameter(raw: raw)
            if parameter.isUserOwned || ownedMask & (UInt64(1) << UInt64(raw)) != 0 { continue }
            let target = parameter.restoresToNeutral ? parameter.defaultValue : paramBefore[raw]
            let current = params[raw].value(at: clock)
            params[raw] = MixParamState(from: current, to: target, start: clock, length: max(Self.restoreFrames, parameter.minimumRampFrames), curve: .linear)
        }
        for deck in decks where deck.loopOwner == group {
            deck.loopOwner = 0
            guard deck.loopLength > 0 else { continue }
            let rate = params[MixParameter.rate(deck.index).raw].value(at: clock)
            let dry = deck.loopOriginFrame + Double(max(0, clock - deck.loopOriginClock)) * rate
            deck.loopLength = 0
            deck.loopStart = -1
            position(deck, at: dry, fade: deck.playing)
        }
        interpolationDirty = true
    }

    private func insertEvent(time: Int64, group: Int32, resolved: Bool, action: MixTimelineAction) {
        guard pendingCount < pendingCapacity else {
            droppedCommands += 1
            return
        }
        eventOrder += 1
        pending[pendingCount] = MixPendingEvent(time: time, group: group, resolved: resolved, order: eventOrder, action: action)
        pendingCount += 1
    }

    private func resolve(group: Int32, at time: Int64) {
        for i in 0..<pendingCount where pending[i].group == group && !pending[i].resolved {
            pending[i].time += time
            pending[i].resolved = true
        }
        resolvedGroups = (group, resolvedGroups.0, resolvedGroups.1, resolvedGroups.2)
        resolvedClocks = (time, resolvedClocks.0, resolvedClocks.1, resolvedClocks.2)
    }

    private func nextDueIndex() -> Int? {
        var best: Int?
        for i in 0..<pendingCount where pending[i].resolved && pending[i].time <= clock {
            if let current = best {
                let a = pending[i]
                let b = pending[current]
                if a.time < b.time || (a.time == b.time && a.order < b.order) { best = i }
            } else {
                best = i
            }
        }
        return best
    }

    private func applyDueEvents() -> Bool {
        var applied = false
        while let index = nextDueIndex() {
            let event = pending[index]
            pendingCount -= 1
            if index != pendingCount { pending[index] = pending[pendingCount] }
            apply(event.action, at: event.time, group: event.group)
            applied = true
        }
        return applied
    }

    private func framesUntilNextEvent() -> Int64 {
        guard !frozen else { return Int64.max }
        var next = Int64.max
        for i in 0..<pendingCount where pending[i].resolved {
            next = min(next, pending[i].time - clock)
        }
        return next
    }

    private func checkAnchors(segment: Int) -> (Int, Bool) {
        var limit = segment
        var resolvedAny = false
        var i = 0
        while i < anchorCount {
            guard case .deckPosition(let deckIndex, let target) = anchors[i].anchor else { i += 1; continue }
            let deck = decks[deckIndex]
            let rate = max(0.01, held[MixParameter.rate(deckIndex).raw])
            guard deck.playing, !deck.stopping, !frozen else { i += 1; continue }
            var pastWrap = false
            if !anchors[i].armed {
                let loopEnd = deck.loopStart + deck.loopLength
                if deck.loopLength <= 0 || deck.nominal < anchors[i].last - 1 {
                    anchors[i].armed = true
                } else if deck.nominal >= loopEnd, deck.nominal - deck.loopLength >= target {
                    anchors[i].armed = true
                    pastWrap = true
                } else {
                    anchors[i].last = deck.nominal
                    let distance = (loopEnd - deck.nominal) + (target - deck.loopStart)
                    let crossing = Int((max(0, distance) / rate).rounded(.up))
                    if crossing < limit { limit = max(1, crossing) }
                    i += 1
                    continue
                }
            }
            if deck.nominal >= target || pastWrap {
                let effective = pastWrap ? deck.nominal - deck.loopLength : deck.nominal
                let late = Int64((max(0, effective - target) / rate).rounded())
                if late > Int64(Self.cell) { missedAnchors += 1 }
                let group = anchors[i].group
                anchorCount -= 1
                anchors[i] = anchors[anchorCount]
                resolve(group: group, at: clock - late)
                interpolationDirty = true
                resolvedAny = true
                continue
            }
            let crossing = Int(((target - deck.nominal) / rate).rounded(.up))
            if crossing < limit { limit = max(1, crossing) }
            i += 1
        }
        return (limit, resolvedAny)
    }

    // MARK: - Event application

    private func apply(_ action: MixTimelineAction, at time: Int64, group: Int32 = 0) {
        interpolationDirty = true
        let lateness = max(0, clock - time)
        switch action {
        case .ramp(let parameter, let target, let frames, let curve):
            if group != 0, ownedMask & (UInt64(1) << UInt64(parameter.raw)) != 0 { return }
            let current = params[parameter.raw].value(at: time)
            if paramOwner[parameter.raw] != group, group != 0 { paramBefore[parameter.raw] = current }
            paramOwner[parameter.raw] = group
            let length = max(frames, parameter.minimumRampFrames)
            params[parameter.raw] = MixParamState(from: current, to: target, start: time, length: length, curve: curve)
        case .start(let deckIndex, let fromFrame):
            let deck = decks[deckIndex]
            guard deck.source != nil else { return }
            let rate = params[MixParameter.rate(deckIndex).raw].value(at: clock)
            if let fromFrame {
                position(deck, at: fromFrame + Double(lateness) * rate, fade: deck.envelope > 0)
            } else if deck.ended {
                position(deck, at: 0, fade: false)
            }
            if !deck.playing || deck.envelope == 0 { resetFilters(deck) }
            deck.playing = true
            deck.stopping = false
            deck.ended = false
            if deck.lockReference >= 0 { relock(deck) }
        case .stop(let deckIndex):
            let deck = decks[deckIndex]
            if deck.playing { deck.stopping = true }
        case .seek(let deckIndex, let target):
            position(decks[deckIndex], at: target, fade: decks[deckIndex].playing)
        case .seekLinked(let lead, let target, let follower, let movesClock):
            let leader = decks[lead]
            let follows = decks[follower]
            let leadRate = max(0.01, params[MixParameter.rate(lead).raw].value(at: clock))
            let followRate = params[MixParameter.rate(follower).raw].value(at: clock)
            let wall = (target - leader.nominal) / leadRate
            let followTarget = follows.nominal + wall * followRate
            position(leader, at: target, fade: leader.playing)
            position(follows, at: followTarget, fade: follows.playing)
            if movesClock, wall > 0 {
                clock += Int64(wall.rounded())
            }
        case .loop(let deckIndex, let start, let length):
            let deck = decks[deckIndex]
            guard length >= 64 else { return }
            if group == 0 {
                deck.loopOwner = 0
            } else if deck.loopOwner != group {
                deck.loopOwner = group
                deck.loopOriginClock = time
                deck.loopOriginFrame = deck.loopLength > 0 ? start : deck.nominal - Double(lateness) * params[MixParameter.rate(deckIndex).raw].value(at: clock)
            }
            deck.loopStart = start
            deck.loopLength = length
            if deck.nominal >= start + length {
                let wrapped = start + (deck.nominal - start).truncatingRemainder(dividingBy: length)
                position(deck, at: wrapped, fade: deck.playing)
            }
        case .clearLoop(let deckIndex):
            decks[deckIndex].loopOwner = 0
            decks[deckIndex].loopLength = 0
            decks[deckIndex].loopStart = -1
        case .echoTime(let seconds):
            echo.setDelay(seconds: seconds)
        case .phaseLock(let deckIndex, let reference):
            let deck = decks[deckIndex]
            deck.lockReference = reference
            deck.lockCorrections = 0
            relock(deck)
        case .phaseUnlock(let deckIndex):
            decks[deckIndex].lockReference = -1
        case .clearFX:
            echo.clear()
            reverb.clear()
            riser.reset()
        case .deckFX(let deckIndex, let kind, let period, let feedback):
            guard deckIndex >= 0, deckIndex < decks.count else { return }
            decks[deckIndex].fx.configure(kind: kind, periodSeconds: period, feedback: feedback)
        case .holdParameters:
            for raw in 0..<MixParameter.count {
                let value = params[raw].value(at: clock)
                params[raw] = MixParamState(from: value, to: value)
            }
        case .resetParameters:
            for raw in 0..<MixParameter.count where !MixParameter(raw: raw).isUserOwned {
                let value = MixParameter(raw: raw).defaultValue
                paramOwner[raw] = 0
                params[raw] = MixParamState(from: value, to: value)
            }
            for deck in decks {
                deck.lockReference = -1
                deck.loopLength = 0
                deck.loopStart = -1
            }
        }
    }

    private func position(_ deck: MixCoreDeck, at target: Double, fade: Bool) {
        let bounded = max(0, min(Double(max(0, deck.sourceFrames - 1)), target))
        let q = pitchRatio(deck.index)
        let value = q == 1 ? bounded.rounded() : bounded
        if fade, deck.envelope > 0 {
            deck.oldContent = deck.content
            deck.fadeLength = Self.seekFade
            deck.fadeRemaining = Self.seekFade
            deck.measureFade(from: deck.content, to: value, length: Self.seekFade, step: q)
        } else {
            deck.fadeRemaining = 0
        }
        deck.nominal = value
        deck.content = value
        deck.ended = false
        reindexAnchors(deck)
        for other in decks where other.lockReference == deck.index { relock(other) }
        if deck.lockReference >= 0 { relock(deck) }
    }

    private func reindexAnchors(_ deck: MixCoreDeck) {
        guard let beats = deck.beats else {
            deck.nextAnchor = 0
            return
        }
        deck.nextAnchor = beats._withUnsafeGuaranteedRef { $0.firstIndex(atOrAfter: deck.nominal + 1) }
    }

    private func relock(_ deck: MixCoreDeck) {
        guard deck.lockReference >= 0, deck.lockReference < decks.count else { return }
        let reference = decks[deck.lockReference]
        guard let beats = reference.beats else { return }
        deck.lockBeat = beats._withUnsafeGuaranteedRef { $0.firstIndex(atOrAfter: reference.nominal) }
    }

    private func resetFilters(_ deck: MixCoreDeck) {
        deck.isolatorL.reset()
        deck.isolatorR.reset()
        deck.lowPassL.reset()
        deck.lowPassR.reset()
        deck.highPassL.reset()
        deck.highPassR.reset()
    }

    @inline(__always)
    private func pitchRatio(_ deck: Int) -> Double {
        let cents = held[MixParameter.pitch(deck).raw]
        return cents == 0 ? 1 : pow(2, cents / 1200)
    }

    // MARK: - Render

    func render(
        frames total: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        phonesLeft phonesOutLeft: UnsafeMutablePointer<Float>? = nil,
        phonesRight phonesOutRight: UnsafeMutablePointer<Float>? = nil
    ) {
        let started = mach_absolute_time()
        drain()
        guard total > 0 else {
            if applyDueEvents() { interpolationDirty = true }
            publish()
            return
        }
        for deck in decks {
            deck.cacheIndex = -1
            deck.cachePointer = nil
        }
        var offset = 0
        while offset < total {
            let chunk = min(Self.capacity, total - offset)
            renderBlock(frames: chunk, left: left + offset, right: right + offset)
            if let phonesOutLeft, let phonesOutRight {
                (phonesOutLeft + offset).update(from: phonesLeft, count: chunk)
                (phonesOutRight + offset).update(from: phonesRight, count: chunk)
            }
            offset += chunk
        }
        for deck in decks {
            if let source = deck.source {
                source._withUnsafeGuaranteedRef { $0.playhead.store(Int(deck.nominal), ordering: .relaxed) }
            }
        }
        let elapsed = (mach_absolute_time() - started) * UInt64(timebase.numer) / UInt64(timebase.denom)
        renderNanos &+= elapsed
        maxQuantumNanos = max(maxQuantumNanos, elapsed)
        quanta += 1
        renderedFrames += Int64(total)
        publish()
    }

    func resetCPUStatistics() {
        renderNanos = 0
        maxQuantumNanos = 0
        quanta = 0
        renderedFrames = 0
    }

    private func renderBlock(frames total: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var n = 0
        while n < total {
            if applyDueEvents() { interpolationDirty = true }
            let cellOffset = Int(frame % Int64(Self.cell))
            let toCellEnd = Self.cell - cellOffset
            if cellOffset == 0 || interpolationDirty {
                computeInterpolation(toCellEnd: toCellEnd)
                interpolationDirty = false
            }
            var segment = min(total - n, toCellEnd)
            let untilEvent = framesUntilNextEvent()
            if untilEvent > 0, untilEvent < Int64(segment) { segment = Int(untilEvent) }
            let (limited, resolvedAnchor) = checkAnchors(segment: segment)
            if resolvedAnchor { continue }
            segment = limited
            processSegment(at: n, count: segment)
            frame += Int64(segment)
            if !frozen { clock += Int64(segment) }
            n += segment
            if frame % Int64(Self.cell) == 0 {
                cellBoundary()
            }
        }
        mixDown(frames: total, left: left, right: right)
    }

    private var segmentOrigin: Int64 = 0

    private func computeInterpolation(toCellEnd: Int) {
        segmentOrigin = frame
        let endClock = frozen ? clock : clock + Int64(toCellEnd)
        let span = Double(max(1, toCellEnd))
        for raw in 0..<MixParameter.count {
            let state = params[raw]
            let v0 = state.value(at: clock)
            let v1 = state.value(at: endClock)
            held[raw] = v0
            let parameter = MixParameter(raw: raw)
            var a = v0
            var b = v1
            if let _ = parameter.deck {
                switch parameter.slot {
                case 1, 2, 3, 4:
                    a = MixIsolator.linearGain(decibels: v0)
                    b = MixIsolator.linearGain(decibels: v1)
                default:
                    break
                }
            }
            interpolated[raw] = MixInterpolated(v0: a, step: (b - a) / span)
        }
        let x0 = params[MixParameter.crossfade.raw].value(at: clock)
        let x1 = params[MixParameter.crossfade.raw].value(at: endClock)
        let shape = min(1, max(0, held[MixParameter.crossfadeCurve.raw]))
        let userShape = min(1, max(0, held[MixParameter.crossfaderShape.raw]))
        for deck in decks {
            let d = deck.index
            func fader(_ x: Double) -> Double {
                let clamped = min(1, max(0, x))
                let side = d == 0 ? 1 - clamped : clamped
                let power = sin(side * .pi / 2)
                let user = userShape > 0 ? MixRenderCore.crossfaderGain(side: side, shape: userShape) : 0
                guard shape > 0 else { return max(power, user) }
                let full = sin(min(1, side * 2) * .pi / 2)
                return max(power + (full - power) * shape, user)
            }
            var f0 = fader(x0)
            var f1 = fader(x1)
            if params[MixParameter.holdTail(d).raw].value(at: clock) > 0.5 { f0 = 1; f1 = 1 }
            if solo >= 0, solo != d { f0 = 0; f1 = 0 }
            faderInterpolation[d] = MixInterpolated(v0: f0, step: (f1 - f0) / span)
            let q = MixParameter.resonance(d).raw
            let quality = 0.7071 + held[q] * 6
            let lp = held[MixParameter.lowPass(d).raw]
            let hp = held[MixParameter.highPass(d).raw]
            deck.lowPassL.configure(cutoff: lp, q: quality, sampleRate: sampleRate)
            deck.lowPassR.configure(cutoff: lp, q: quality, sampleRate: sampleRate)
            deck.highPassL.configure(cutoff: hp, q: quality, sampleRate: sampleRate)
            deck.highPassR.configure(cutoff: hp, q: quality, sampleRate: sampleRate)
            let lpTarget = lp < MixEngine.filterOpenHertz ? 1.0 : 0.0
            let hpTarget = hp > MixEngine.filterCutoffRange.lowerBound + 5 ? 1.0 : 0.0
            lowPassMixInterpolation[d] = MixInterpolated(v0: deck.lowPassMix, step: (lpTarget - deck.lowPassMix) / span)
            highPassMixInterpolation[d] = MixInterpolated(v0: deck.highPassMix, step: (hpTarget - deck.highPassMix) / span)
            deck.lowPassMix = lpTarget
            deck.highPassMix = hpTarget
        }
    }

    @inline(__always)
    static func crossfaderGain(side: Double, shape: Double) -> Double {
        let steepness = pow(32, min(1, max(0, shape)))
        return sin(min(1, max(0, side) * steepness) * .pi / 2)
    }

    private var faderInterpolation = [MixInterpolated(), MixInterpolated()]
    private var lowPassMixInterpolation = [MixInterpolated(), MixInterpolated()]
    private var highPassMixInterpolation = [MixInterpolated(), MixInterpolated()]

    private func processSegment(at start: Int, count: Int) {
        let base = Int(frame - segmentOrigin)
        for k in 0..<count {
            let i = base + k
            masterGain[start + k] = Float(interpolated[MixParameter.master.raw].at(i))
            feedbackGain[start + k] = Float(interpolated[MixParameter.echoFeedback.raw].at(i))
            echoReturnGain[start + k] = Float(interpolated[MixParameter.echoReturn.raw].at(i))
            reverbReturnGain[start + k] = Float(interpolated[MixParameter.reverbReturn.raw].at(i))
            auxReturnGain[start + k] = Float(interpolated[MixParameter.auxReturn.raw].at(i))
            let level = Float(interpolated[MixParameter.riserLevel.raw].at(i))
            riserGain[start + k] = level
            riserSweep[start + k] = Float(interpolated[MixParameter.riserSweep.raw].at(i))
            cueMixGain[start + k] = Float(interpolated[MixParameter.cueMix.raw].at(i))
            phonesGain[start + k] = Float(interpolated[MixParameter.phonesLevel.raw].at(i))
            splitGain[start + k] = Float(min(1, max(0, interpolated[MixParameter.splitCue.raw].at(i))))
            if level > 0 { riserLive = true }
        }
        for deck in decks {
            processDeck(deck, at: start, count: count, base: base)
        }
    }

    private func processDeck(_ deck: MixCoreDeck, at start: Int, count: Int, base: Int) {
        let d = deck.index
        let fxSendLevel = interpolated[MixParameter.fxSend(d).raw]
        let fxWetLevel = interpolated[MixParameter.fxWet(d).raw]
        let cueLevel = interpolated[MixParameter.cue(d).raw]
        let channelLevel = interpolated[MixParameter.gain(d).raw]
        let faderLevel = faderInterpolation[d]
        for k in 0..<count {
            let i = base + k
            deck.fxSend[start + k] = Float(fxSendLevel.at(i))
            deck.fxWet[start + k] = Float(fxWetLevel.at(i))
            deck.cueGain[start + k] = Float(cueLevel.at(i))
        }
        let active = deck.playing && deck.source != nil
        guard active else {
            for k in 0..<count {
                deck.left[start + k] = 0
                deck.right[start + k] = 0
                deck.channelGain[start + k] = Float(channelLevel.at(base + k) * faderLevel.at(base + k))
                deck.echoGain[start + k] = 0
                deck.reverbGain[start + k] = 0
                deck.auxGain[start + k] = 0
                deck.insertMix[start + k] = 0
            }
            return
        }
        let rate = max(0.01, held[MixParameter.rate(d).raw])
        let q = pitchRatio(d)
        var nominal = deck.nominal
        var content = deck.content
        var oldContent = deck.oldContent
        var fadeRemaining = deck.fadeRemaining
        var fadeLength = max(1, deck.fadeLength)
        var envelope = deck.envelope
        let envelopeTarget = deck.stopping ? 0.0 : 1.0
        let envelopeStep = 1 / Self.envelopeFrames
        var isolatorL = deck.isolatorL
        var isolatorR = deck.isolatorR
        var lowPassL = deck.lowPassL
        var lowPassR = deck.lowPassR
        var highPassL = deck.highPassL
        var highPassR = deck.highPassR
        let gain = interpolated[MixParameter.gain(d).raw]
        let input = interpolated[MixParameter.inputGain(d).raw]
        let low = interpolated[MixParameter.eqLow(d).raw]
        let mid = interpolated[MixParameter.eqMid(d).raw]
        let high = interpolated[MixParameter.eqHigh(d).raw]
        let echoSend = interpolated[MixParameter.echoSend(d).raw]
        let reverbSend = interpolated[MixParameter.reverbSend(d).raw]
        let auxSend = interpolated[MixParameter.auxSend(d).raw]
        let insertMix = interpolated[MixParameter.insertMix(d).raw]
        let fader = faderInterpolation[d]
        let lpMix = lowPassMixInterpolation[d]
        let hpMix = highPassMixInterpolation[d]
        let integral = q == 1 && content == content.rounded() && (fadeRemaining == 0 || oldContent == oldContent.rounded())
        let loopEnd = deck.loopLength > 0 ? deck.loopStart + deck.loopLength : Double.infinity
        let end = Double(deck.sourceFrames)
        var stopAfter = -1

        for k in 0..<count {
            let i = base + k
            if nominal >= loopEnd {
                nominal -= deck.loopLength
                if fadeRemaining == 0 {
                    oldContent = content
                    fadeRemaining = Self.loopFade
                    fadeLength = Self.loopFade
                    deck.measureFade(from: content, to: content - deck.loopLength, length: Self.loopFade, step: q)
                } else {
                    oldContent -= deck.loopLength
                }
                content -= deck.loopLength
                reindexAnchorsInline(deck, nominal)
            }
            var (l, r) = deck.read(content, integral: integral)
            if fadeRemaining > 0 {
                let w = 0.5 - 0.5 * cos(Double.pi * Double(fadeLength - fadeRemaining) / Double(fadeLength))
                let (ol, or) = deck.read(oldContent, integral: integral)
                let g = deck.fadeCompensation(w)
                let boundL = max(abs(ol), abs(l))
                let boundR = max(abs(or), abs(r))
                l = max(-boundL, min(boundL, (ol + (l - ol) * w) * g))
                r = max(-boundR, min(boundR, (or + (r - or) * w) * g))
                oldContent += q
                fadeRemaining -= 1
            }
            content += q
            nominal += rate
            if envelope != envelopeTarget {
                envelope = envelopeTarget > envelope ? min(1, envelope + envelopeStep) : max(0, envelope - envelopeStep)
                if envelope == 0, envelopeTarget == 0, stopAfter < 0 { stopAfter = k }
            }
            let inputGain = input.at(i)
            l *= inputGain
            r *= inputGain
            let gl = low.at(i)
            let gm = mid.at(i)
            let gh = high.at(i)
            l = isolatorL.process(l, low: gl, mid: gm, high: gh)
            r = isolatorR.process(r, low: gl, mid: gm, high: gh)
            let lpAmount = lpMix.at(i)
            let lpL = lowPassL.lowPass(l)
            let lpR = lowPassR.lowPass(r)
            l += (lpL - l) * lpAmount
            r += (lpR - r) * lpAmount
            let hpAmount = hpMix.at(i)
            let hpL = highPassL.highPass(l)
            let hpR = highPassR.highPass(r)
            l += (hpL - l) * hpAmount
            r += (hpR - r) * hpAmount
            deck.left[start + k] = Float(l * envelope)
            deck.right[start + k] = Float(r * envelope)
            let channel = gain.at(i) * fader.at(i)
            deck.channelGain[start + k] = Float(channel)
            deck.echoGain[start + k] = Float(channel * echoSend.at(i))
            deck.reverbGain[start + k] = Float(channel * reverbSend.at(i))
            deck.auxGain[start + k] = Float(channel * auxSend.at(i))
            deck.insertMix[start + k] = Float(insertMix.at(i))
            if nominal >= end {
                deck.ended = true
                stopAfter = k
                break
            }
        }
        if stopAfter >= 0 {
            for k in (stopAfter + 1)..<max(stopAfter + 1, count) {
                deck.left[start + k] = 0
                deck.right[start + k] = 0
                deck.channelGain[start + k] = Float(channelLevel.at(base + k) * faderLevel.at(base + k))
                deck.echoGain[start + k] = 0
                deck.reverbGain[start + k] = 0
                deck.auxGain[start + k] = 0
            }
            deck.playing = false
            deck.stopping = false
            envelope = 0
        }
        deck.nominal = min(nominal, end)
        deck.content = content
        deck.oldContent = oldContent
        deck.fadeRemaining = fadeRemaining
        deck.fadeLength = fadeLength
        deck.envelope = envelope
        deck.isolatorL = isolatorL
        deck.isolatorR = isolatorR
        deck.lowPassL = lowPassL
        deck.lowPassR = lowPassR
        deck.highPassL = highPassL
        deck.highPassR = highPassR
    }

    @inline(__always)
    private func reindexAnchorsInline(_ deck: MixCoreDeck, _ nominal: Double) {
        guard let beats = deck.beats else { return }
        deck.nextAnchor = beats._withUnsafeGuaranteedRef { $0.firstIndex(atOrAfter: nominal + 1) }
        for other in decks where other.lockReference == deck.index {
            other.lockBeat = beats._withUnsafeGuaranteedRef { $0.firstIndex(atOrAfter: nominal) }
        }
    }

    // MARK: - Cell boundary: stretcher and phase lock

    private func cellBoundary() {
        for deck in decks where deck.playing && !deck.stopping && deck.source != nil {
            phaseLock(deck)
        }
        for deck in decks where deck.playing && !deck.stopping && deck.source != nil {
            stretch(deck)
        }
    }

    private func stretch(_ deck: MixCoreDeck) {
        guard deck.fadeRemaining == 0 else { return }
        let d = deck.index
        let rate = max(0.01, held[MixParameter.rate(d).raw])
        let q = pitchRatio(d)
        let drift = q - rate
        let offset = deck.content - deck.nominal
        let fade = Double(Self.spliceFade)
        let cell = Double(Self.cell)
        var room = Double.infinity

        if let beats = deck.beats {
            let table = beats._withUnsafeGuaranteedRef { $0 }
            while deck.nextAnchor < table.count, table.frames[deck.nextAnchor] < deck.nominal + 1 {
                let beat = table.frames[deck.nextAnchor]
                if deck.nominal - beat < cell * rate * 1.5 {
                    let since = (deck.nominal - beat) / rate
                    let contentAtBeat = deck.content - since * q
                    let error = abs(contentAtBeat - beat)
                    deck.beatOffsetMax = max(deck.beatOffsetMax, error)
                    deck.beatOffsetSum += error
                    deck.beatOffsetCount += 1
                }
                deck.nextAnchor += 1
            }
            if deck.nextAnchor < table.count {
                let beat = table.frames[deck.nextAnchor]
                let untilNominal = (beat - deck.nominal) / rate
                let untilContent = (beat - deck.content) / q
                let lead = min(untilNominal, untilContent) - 48
                let error = offset + drift * untilNominal
                if abs(error) > Self.anchorTolerance, lead <= fade + 4 * cell, lead >= fade {
                    splice(deck, center: -drift * untilNominal, radius: 24, rate: rate, q: q)
                    return
                }
                if lead < fade * 2 + 4 * cell, abs(offset) < Self.maximumDrift * 2 { return }
                room = lead - fade - 4 * cell
            }
        }
        if drift != 0 {
            let direction: Double = drift > 0 ? -1 : 1
            let lead = (offset + drift * cell * 2) * direction
            if lead < -Self.maximumDrift || lead > Self.maximumDrift + Double(Self.periodSearch) {
                let longest = Int(max(Double(Self.spliceFade), min(Double(Self.sustainedSpliceFade), room)))
                splice(deck, center: direction * Self.maximumDrift * 0.5, radius: Self.maximumDrift * 0.5, rate: rate, q: q, longestFade: longest, reach: min(Double(Self.periodSearch), max(0, room)))
            }
        } else if abs(offset) > Self.settleTolerance {
            splice(deck, center: 0, radius: Self.settleTolerance * 0.5, rate: rate, q: q)
        }
    }

    private func splice(_ deck: MixCoreDeck, center: Double, radius: Double, rate: Double, q: Double, longestFade: Int = MixRenderCore.spliceFade, reach: Double = 0) {
        let length = Self.correlationLength
        let reference = Int(deck.content.rounded())
        var referenceEnergy: Float = 0
        for k in 0..<length {
            let value = deck.mono(reference + k)
            correlationReference[k] = value
            referenceEnergy += value * value
        }
        let target = deck.nominal + center
        var (position, bestCorrelation) = bestMatch(deck, target: target, radius: radius, referenceEnergy: referenceEnergy)
        if reach > radius * 2, bestCorrelation < Self.sustainedCorrelation {
            let half = (reach * 0.5).rounded()
            let wide = bestMatch(deck, target: deck.nominal + (center < 0 ? -half : half), radius: half, referenceEnergy: referenceEnergy)
            if wide.correlation >= Self.sustainedCorrelation, wide.correlation > bestCorrelation + 0.1 {
                position = wide.position
                bestCorrelation = wide.correlation
            }
        }
        let fractional = q == 1 ? 0 : target - target.rounded()
        deck.oldContent = deck.content
        deck.content = Double(position) + fractional
        let fadeFrames = bestCorrelation >= Self.sustainedCorrelation ? max(Self.spliceFade, longestFade) : Self.spliceFade
        deck.fadeLength = fadeFrames
        deck.fadeRemaining = fadeFrames
        deck.measureFade(from: deck.oldContent, to: deck.content, length: fadeFrames, step: q)
        deck.splices += 1
    }

    private func bestMatch(_ deck: MixCoreDeck, target: Double, radius: Double, referenceEnergy: Float) -> (position: Int, correlation: Double) {
        let span = min(Self.periodSearch, max(0, Int(radius.rounded())))
        let length = Self.correlationLength
        let base = Int(target.rounded()) - span
        let candidates = 2 * span + 1
        var best = span
        var bestCorrelation = 0.0
        if referenceEnergy > 1e-6, span > 0 {
            for k in 0..<(candidates + length - 1) {
                correlationCandidates[k] = deck.mono(base + k)
            }
            vDSP_conv(
                correlationCandidates, 1,
                correlationReference, 1,
                correlationOutput, 1,
                vDSP_Length(candidates), vDSP_Length(length)
            )
            var energy: Float = 0
            for k in 0..<length { energy += correlationCandidates[k] * correlationCandidates[k] }
            var bestScore = -Double.infinity
            for k in 0..<candidates {
                if k > 0 {
                    let leaving = correlationCandidates[k - 1]
                    let entering = correlationCandidates[k + length - 1]
                    energy += entering * entering - leaving * leaving
                }
                let norm = Double(max(1e-9, energy)) * Double(referenceEnergy)
                let correlation = Double(correlationOutput[k]) / norm.squareRoot()
                let score = correlation - 0.15 * abs(Double(k - span)) / Double(max(1, span))
                if score > bestScore {
                    bestScore = score
                    best = k
                    bestCorrelation = correlation
                }
            }
        }
        return (base + best, bestCorrelation)
    }

    private func phaseLock(_ deck: MixCoreDeck) {
        guard deck.lockReference >= 0, deck.lockReference != deck.index else { return }
        let reference = decks[deck.lockReference]
        guard reference.playing, !reference.stopping,
              let referenceBeats = reference.beats, let deckBeats = deck.beats else { return }
        let referenceTable = referenceBeats._withUnsafeGuaranteedRef { $0 }
        let table = deckBeats._withUnsafeGuaranteedRef { $0 }
        let d = deck.index
        let referenceRate = max(0.01, held[MixParameter.rate(reference.index).raw])
        while deck.lockBeat < referenceTable.count, referenceTable.frames[deck.lockBeat] <= reference.nominal {
            let beat = referenceTable.frames[deck.lockBeat]
            let isBar = referenceTable.isDownbeat[deck.lockBeat]
            let referencePeriod = referenceTable.localPeriod(at: deck.lockBeat)
            deck.lockBeat += 1
            let rate = max(0.01, params[MixParameter.rate(d).raw].value(at: clock))
            let since = (reference.nominal - beat) / referenceRate
            let position = deck.nominal - since * rate
            let nearest = table.nearestIndex(to: position)
            let error = (position - table.frames[nearest]) / rate
            let period = referencePeriod / referenceRate
            guard abs(error) < period * 0.25, referencePeriod > 0 else { continue }
            deck.lockErrorMs = error / sampleRate * 1000
            let deckPeriod = table.localPeriod(at: nearest)
            if !params[MixParameter.rate(d).raw].isRamping(at: clock), deckPeriod > 0 {
                let target = referenceRate * deckPeriod / referencePeriod
                if target > 0.5, target < 2, abs(target - rate) < 0.08 {
                    params[MixParameter.rate(d).raw] = MixParamState(from: target, to: target, start: clock, length: 0)
                    held[MixParameter.rate(d).raw] = target
                }
            }
            if isBar, abs(error) > 2 {
                deck.nominal -= error * rate
                deck.lockCorrections += 1
            }
        }
    }

    // MARK: - Mix down

    private func mixDown(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for deck in decks where deck.insert != nil {
            guard deck.playing || deck.envelope > 0 || deck.silentForFrames < Int(sampleRate) else { continue }
            deck.dryLeft.update(from: deck.left, count: frames)
            deck.dryRight.update(from: deck.right, count: frames)
            deck.insert!._withUnsafeGuaranteedRef { $0.process(left: deck.left, right: deck.right, frames: frames) }
            deck.dryAlign.process(left: deck.dryLeft, right: deck.dryRight, frames: frames)
            for n in 0..<frames {
                let m = deck.insertMix[n]
                deck.left[n] = deck.dryLeft[n] + (deck.left[n] - deck.dryLeft[n]) * m
                deck.right[n] = deck.dryRight[n] + (deck.right[n] - deck.dryRight[n]) * m
            }
        }

        for deck in decks {
            deck.compensation.process(left: deck.left, right: deck.right, frames: frames)
            if !deck.fx.isIdle {
                deck.fx.process(left: deck.left, right: deck.right, send: deck.fxSend, wet: deck.fxWet, frames: frames)
            }
        }
        let wantsPhones = phonesActive.load(ordering: .relaxed) || phonesRequested

        for n in 0..<frames {
            mixLeft[n] = 0
            mixRight[n] = 0
            busA[n] = 0
            busB[n] = 0
            busC[n] = 0
            busD[n] = 0
            cueLeft[n] = 0
            cueRight[n] = 0
        }
        var echoInput = false
        var reverbInput = false
        for deck in decks {
            var sum: Float = 0
            var peak: Float = 0
            var audible = false
            for n in 0..<frames {
                let l = deck.left[n]
                let r = deck.right[n]
                let g = deck.channelGain[n]
                mixLeft[n] += l * g
                mixRight[n] += r * g
                let e = deck.echoGain[n]
                if e != 0 {
                    busA[n] += l * e
                    busB[n] += r * e
                    echoInput = true
                }
                let v = deck.reverbGain[n]
                if v != 0 {
                    busC[n] += (l + r) * v
                    reverbInput = true
                }
                sum += l * l + r * r
                peak = max(peak, max(abs(l), abs(r)))
                if l != 0 || r != 0 { audible = true }
                let c = deck.cueGain[n]
                if c != 0 {
                    cueLeft[n] += l * c
                    cueRight[n] += r * c
                }
            }
            if audible {
                meters.record(.deck(deck.index), left: deck.left, right: deck.right, frames: frames, sampleRate: sampleRate)
            } else {
                meters.clear(.deck(deck.index), frames: frames, sampleRate: sampleRate)
            }
            deck.rms = (sum / Float(max(1, 2 * frames))).squareRoot()
            deck.peak = max(peak, deck.peak * 0.9)
            deck.silentForFrames = audible ? 0 : min(1 << 40, deck.silentForFrames) + frames
        }

        if echoInput { echoActiveFrames = Int(sampleRate * 8) }
        if echoActiveFrames > 0 {
            echoActiveFrames -= frames
            echo.process(
                inputLeft: busA, inputRight: busB,
                outputLeft: busA, outputRight: busB,
                frames: frames, feedbackGain: feedbackGain
            )
            if echo.energy > 1e-5 { echoActiveFrames = max(echoActiveFrames, frames * 4) }
            for n in 0..<frames {
                mixLeft[n] += busA[n] * echoReturnGain[n]
                mixRight[n] += busB[n] * echoReturnGain[n]
            }
        }

        if reverbInput { reverbActiveFrames = Int(sampleRate * 10) }
        if reverbActiveFrames > 0 {
            reverbActiveFrames -= frames
            reverb.process(
                inputLeft: busC, inputRight: busD,
                outputLeft: busC, outputRight: busD,
                frames: frames
            )
            if reverb.energy > 1e-5 { reverbActiveFrames = max(reverbActiveFrames, frames * 4) }
            for n in 0..<frames {
                mixLeft[n] += busC[n] * reverbReturnGain[n]
                mixRight[n] += busD[n] * reverbReturnGain[n]
            }
        }

        auxAlign.process(left: mixLeft, right: mixRight, frames: frames)

        if let aux {
            for n in 0..<frames {
                busA[n] = 0
                busB[n] = 0
            }
            for deck in decks {
                for n in 0..<frames {
                    let g = deck.auxGain[n]
                    if g != 0 {
                        busA[n] += deck.left[n] * g
                        busB[n] += deck.right[n] * g
                    }
                }
            }
            aux._withUnsafeGuaranteedRef { $0.process(left: busA, right: busB, frames: frames) }
            for n in 0..<frames {
                mixLeft[n] += busA[n] * auxReturnGain[n]
                mixRight[n] += busB[n] * auxReturnGain[n]
            }
        }

        if riserLive, solo < 0 || solo == 2 {
            riser.process(gain: riserGain, sweep: riserSweep, addingTo: mixLeft, mixRight, frames: frames)
        } else if riser.active {
            riser.reset()
        }
        riserLive = false

        for n in 0..<frames {
            left[n] = mixLeft[n] * masterGain[n]
            right[n] = mixRight[n] * masterGain[n]
        }
        meters.record(.master, left: left, right: right, frames: frames, sampleRate: sampleRate)
        meters.record(.masterLeft, left: left, right: left, frames: frames, sampleRate: sampleRate)
        meters.record(.masterRight, left: right, right: right, frames: frames, sampleRate: sampleRate)
        limiter.process(left: left, right: right, frames: frames)
        if wantsPhones {
            mixPhones(frames: frames, masterLeft: left, masterRight: right)
        }
    }

    private func mixPhones(frames: Int, masterLeft: UnsafePointer<Float>, masterRight: UnsafePointer<Float>) {
        for n in 0..<frames {
            let mix = Double(min(1, max(0, cueMixGain[n])))
            let cueWeight = Float(cos(mix * .pi / 2))
            let masterWeight = Float(sin(mix * .pi / 2))
            let level = phonesGain[n]
            let split = splitGain[n]
            let blendL = cueLeft[n] * cueWeight + masterLeft[n] * masterWeight
            let blendR = cueRight[n] * cueWeight + masterRight[n] * masterWeight
            let splitL = (cueLeft[n] + cueRight[n]) * 0.5
            let splitR = (masterLeft[n] + masterRight[n]) * 0.5
            let l = (blendL + (splitL - blendL) * split) * level
            let r = (blendR + (splitR - blendR) * split) * level
            phonesLeft[n] = min(1, max(-1, l))
            phonesRight[n] = min(1, max(-1, r))
        }
        meters.record(.phones, left: phonesLeft, right: phonesRight, frames: frames, sampleRate: sampleRate)
        if phonesActive.load(ordering: .relaxed) {
            phonesRing.write(left: phonesLeft, right: phonesRight, frames: frames)
        }
    }
}
