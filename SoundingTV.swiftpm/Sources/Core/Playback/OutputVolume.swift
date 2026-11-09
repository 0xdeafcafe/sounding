import Foundation

// MARK: - Pure logic

enum OutputVolumeRoute: Equatable, Sendable {
    case system
    case linked
    case sonos

    static func resolve(sonosActive: Bool, remoteOutput: Bool) -> OutputVolumeRoute {
        if sonosActive { return .sonos }
        return remoteOutput ? .linked : .system
    }

    var isRemote: Bool { self != .system }
}

struct VolumeReconciler: Equatable, Sendable {
    static let defaultHold: TimeInterval = 1.5

    var hold: TimeInterval = VolumeReconciler.defaultHold
    private(set) var local: Double?
    private(set) var isAdjusting = false
    private(set) var lastLocalChange: Date?

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    mutating func begin(at now: Date) {
        isAdjusting = true
        lastLocalChange = now
    }

    @discardableResult
    mutating func set(_ value: Double, at now: Date) -> Double {
        let clamped = Self.clamp(value)
        local = clamped
        lastLocalChange = now
        return clamped
    }

    mutating func end(at now: Date) {
        isAdjusting = false
        lastLocalChange = now
    }

    mutating func reset() {
        local = nil
        isAdjusting = false
        lastLocalChange = nil
    }

    func isHolding(at now: Date) -> Bool {
        if isAdjusting { return true }
        guard let lastLocalChange else { return false }
        return now.timeIntervalSince(lastLocalChange) < hold
    }

    func displayed(echo: Double?, at now: Date) -> Double? {
        let echo = echo.map(Self.clamp)
        if isHolding(at: now) { return local ?? echo }
        return echo ?? local
    }

    func releaseDelay(at now: Date) -> TimeInterval? {
        guard !isAdjusting, let lastLocalChange else { return nil }
        let remaining = hold - now.timeIntervalSince(lastLocalChange)
        return remaining > 0 ? remaining : nil
    }
}

struct VolumeSendThrottle: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case send(Double)
        case wait(TimeInterval)
        case skip
    }

    static let defaultInterval: TimeInterval = 0.12

    let interval: TimeInterval
    private(set) var lastSend: Date?
    private(set) var lastSentValue: Double?
    private(set) var pending: Double?

    init(interval: TimeInterval = VolumeSendThrottle.defaultInterval) {
        self.interval = interval
    }

    mutating func submit(_ value: Double, at now: Date) -> Decision {
        if pending == nil, let lastSentValue, abs(lastSentValue - value) < 0.0005 { return .skip }
        let elapsed = lastSend.map { now.timeIntervalSince($0) } ?? .infinity
        if pending == nil, elapsed >= interval {
            lastSend = now
            lastSentValue = value
            return .send(value)
        }
        let alreadyWaiting = pending != nil
        pending = value
        return alreadyWaiting ? .skip : .wait(max(0, interval - elapsed))
    }

    mutating func flush(at now: Date) -> Double? {
        guard let value = pending else { return nil }
        pending = nil
        if let lastSentValue, abs(lastSentValue - value) < 0.0005 { return nil }
        lastSend = now
        lastSentValue = value
        return value
    }

    mutating func forget() {
        lastSend = nil
        lastSentValue = nil
        pending = nil
    }
}

enum HardwareVolumeStep {
    static let system: Float = 1.0 / 16.0
    static let remote: Double = 1.0 / 16.0
    static let tolerance: Float = 0.01

    static func steps(from previous: Float, to current: Float) -> Int {
        let delta = current - previous
        guard abs(delta) > 0.001 else { return 0 }
        let rounded = Int((delta / system).rounded())
        if rounded != 0 { return rounded }
        return delta > 0 ? 1 : -1
    }

    static func anchor(for original: Float) -> Float {
        min(1 - system, max(system, original))
    }

    static func applying(_ steps: Int, to level: Double, step: Double = remote) -> Double {
        VolumeReconciler.clamp(level + Double(steps) * step)
    }
}

struct HardwareVolumeTracker: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        let steps: Int
        let resetTo: Float?
    }

    let original: Float
    let anchor: Float
    private(set) var last: Float
    private(set) var awaitingReset: Bool

    init(original: Float) {
        self.original = original
        anchor = HardwareVolumeStep.anchor(for: original)
        last = original
        awaitingReset = abs(anchor - original) > HardwareVolumeStep.tolerance
    }

    var needsInitialReset: Bool { awaitingReset }

    var restoreOnFinish: Float? {
        abs(anchor - original) > HardwareVolumeStep.tolerance ? original : nil
    }

    mutating func observe(_ value: Float) -> Reading {
        if awaitingReset, abs(value - anchor) <= HardwareVolumeStep.tolerance {
            awaitingReset = false
            last = value
            return Reading(steps: 0, resetTo: nil)
        }
        let steps = HardwareVolumeStep.steps(from: last, to: value)
        last = value
        guard steps != 0 else { return Reading(steps: 0, resetTo: nil) }
        awaitingReset = true
        return Reading(steps: steps, resetTo: anchor)
    }
}

// MARK: - Channel

@MainActor
final class RemoteVolumeChannel {
    private var reconciler = VolumeReconciler()
    private var throttle: VolumeSendThrottle
    private let send: @MainActor (Double) -> Void
    var willChange: @MainActor () -> Void = {}
    private var trailingTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    init(
        interval: TimeInterval = VolumeSendThrottle.defaultInterval,
        hold: TimeInterval = VolumeReconciler.defaultHold,
        send: @escaping @MainActor (Double) -> Void
    ) {
        throttle = VolumeSendThrottle(interval: interval)
        reconciler.hold = hold
        self.send = send
    }

    var isAdjusting: Bool { reconciler.isAdjusting }

    var isHolding: Bool { reconciler.isHolding(at: Date()) }

    func value(echo: Double?) -> Double? {
        reconciler.displayed(echo: echo, at: Date())
    }

    func begin() {
        guard !reconciler.isAdjusting else { return }
        willChange()
        reconciler.begin(at: Date())
        releaseTask?.cancel()
    }

    func set(_ value: Double) {
        willChange()
        let now = Date()
        let clamped = reconciler.set(value, at: now)
        submit(clamped, at: now)
        scheduleRelease()
    }

    func step(_ steps: Int, echo: Double?, size: Double = HardwareVolumeStep.remote) {
        guard steps != 0, let base = value(echo: echo) else { return }
        set(HardwareVolumeStep.applying(steps, to: base, step: size))
    }

    func end() {
        guard reconciler.isAdjusting else { return }
        willChange()
        reconciler.end(at: Date())
        flushNow()
        scheduleRelease()
    }

    func reset() {
        trailingTask?.cancel()
        trailingTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        willChange()
        reconciler.reset()
        throttle.forget()
    }

    private func submit(_ value: Double, at now: Date) {
        switch throttle.submit(value, at: now) {
        case .send(let level):
            send(level)
        case .wait(let delay):
            trailingTask?.cancel()
            trailingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.flushNow()
            }
        case .skip:
            break
        }
    }

    private func flushNow() {
        trailingTask?.cancel()
        trailingTask = nil
        if let level = throttle.flush(at: Date()) { send(level) }
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        guard let delay = reconciler.releaseDelay(at: Date()) else { return }
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.releaseTask = nil
            self.willChange()
        }
    }
}
