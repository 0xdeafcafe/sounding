import Foundation

@MainActor
protocol LightWriting: AnyObject {
    func write(_ changes: LightWriteChanges, to lightID: String) async throws
}

struct LightWritePolicy: Equatable, Sendable {
    var writesPerSecondPerLight: Double
    var writesPerSecondTotal: Double

    static let standard = LightWritePolicy(writesPerSecondPerLight: 1, writesPerSecondTotal: 8)

    var minimumInterval: TimeInterval { 1 / max(0.01, writesPerSecondPerLight) }
}

struct LightWrite: Equatable, Sendable {
    let lightID: String
    let state: LightState
    let changes: LightWriteChanges
    let sentAt: TimeInterval
}

struct LightRateLimiter: Sendable {
    let policy: LightWritePolicy
    private(set) var pending: [String: LightState] = [:]
    private(set) var acknowledged: [String: LightState] = [:]
    private(set) var inFlight: Set<String> = []
    private var lastSentAt: [String: TimeInterval] = [:]
    private var recentSends: [TimeInterval] = []
    var capabilities: [String: LightCapabilities] = [:]

    init(policy: LightWritePolicy) {
        self.policy = policy
    }

    mutating func submit(_ state: LightState, to lightID: String) {
        pending[lightID] = state
    }

    mutating func dueWrites(at now: TimeInterval) -> [LightWrite] {
        recentSends.removeAll { now - $0 >= 1 }
        var out: [LightWrite] = []
        for lightID in pending.keys.sorted() {
            guard let state = pending[lightID], !inFlight.contains(lightID) else { continue }
            if let last = lastSentAt[lightID], now - last < policy.minimumInterval - 0.0001 { continue }
            let changes = LightWriteChanges.between(
                acknowledged[lightID],
                state,
                capabilities: capabilities[lightID] ?? [.power, .brightness, .color]
            )
            if changes.isEmpty {
                pending[lightID] = nil
                continue
            }
            guard Double(recentSends.count) < policy.writesPerSecondTotal else { break }
            pending[lightID] = nil
            inFlight.insert(lightID)
            lastSentAt[lightID] = now
            recentSends.append(now)
            out.append(LightWrite(lightID: lightID, state: state, changes: changes, sentAt: now))
        }
        return out
    }

    mutating func complete(_ write: LightWrite, succeeded: Bool) {
        inFlight.remove(write.lightID)
        acknowledged[write.lightID] = succeeded ? write.state : nil
    }

    func nextWakeTime(after now: TimeInterval) -> TimeInterval? {
        var earliest: TimeInterval?
        for lightID in pending.keys where !inFlight.contains(lightID) {
            let ready = (lastSentAt[lightID] ?? -.infinity) + policy.minimumInterval
            let candidate = max(now, ready)
            earliest = min(earliest ?? candidate, candidate)
        }
        if let earliest, Double(recentSends.count) >= policy.writesPerSecondTotal, let oldest = recentSends.min() {
            return max(earliest, oldest + 1)
        }
        return earliest
    }

    mutating func forget(_ lightID: String) {
        pending[lightID] = nil
        acknowledged[lightID] = nil
        lastSentAt[lightID] = nil
    }

    mutating func clearPending() {
        pending.removeAll()
    }
}

@MainActor
final class LightWriteScheduler {
    private var limiter: LightRateLimiter
    private let backend: LightWriting
    private let now: () -> TimeInterval
    private let wakesItself: Bool
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    private var wakeTask: Task<Void, Never>?
    private(set) var latency: TimeInterval = 0.35
    private(set) var sent: [LightWrite] = []
    private(set) var failures = 0

    var policy: LightWritePolicy { limiter.policy }

    init(
        backend: LightWriting,
        policy: LightWritePolicy = .standard,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wakesItself: Bool = true
    ) {
        self.backend = backend
        self.limiter = LightRateLimiter(policy: policy)
        self.now = now
        self.wakesItself = wakesItself
    }

    func setCapabilities(_ capabilities: [String: LightCapabilities]) {
        limiter.capabilities = capabilities
    }

    func submit(_ state: LightState, to lightIDs: [String]) {
        for lightID in lightIDs { limiter.submit(state, to: lightID) }
        pump()
    }

    func forget(_ lightID: String) {
        limiter.forget(lightID)
    }

    func cancelPending() {
        limiter.clearPending()
        wakeTask?.cancel()
        wakeTask = nil
    }

    var pendingCount: Int { limiter.pending.count }

    @discardableResult
    func pump() -> [LightWrite] {
        let writes = limiter.dueWrites(at: now())
        for write in writes { dispatch(write) }
        sent.append(contentsOf: writes)
        if sent.count > 256 { sent.removeFirst(sent.count - 256) }
        scheduleWake()
        return writes
    }

    func settle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    private func dispatch(_ write: LightWrite) {
        let id = nextTaskID
        nextTaskID += 1
        let started = now()
        tasks[id] = Task { @MainActor [weak self, backend] in
            var succeeded = true
            do {
                try await backend.write(write.changes, to: write.lightID)
            } catch {
                succeeded = false
            }
            guard let self else { return }
            self.tasks[id] = nil
            self.limiter.complete(write, succeeded: succeeded)
            if succeeded {
                let measured = max(0, self.now() - started)
                self.latency = self.latency * 0.7 + measured * 0.3
            } else {
                self.failures += 1
            }
            if self.wakesItself { self.pump() }
        }
    }

    private func scheduleWake() {
        guard wakesItself else { return }
        wakeTask?.cancel()
        wakeTask = nil
        let current = now()
        guard let wake = limiter.nextWakeTime(after: current) else { return }
        let delay = max(0.01, wake - current)
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }
}
