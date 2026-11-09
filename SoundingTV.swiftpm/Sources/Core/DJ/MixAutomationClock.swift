import Foundation

@MainActor
final class MixAutomationClock {
    let isOffline: Bool
    private(set) var isPaused = false
    private var read: (() -> TimeInterval)?
    private var freeze: ((Bool) -> Void)?
    private var shift: ((TimeInterval) -> Void)?

    init(offline: Bool) {
        isOffline = offline
    }

    func attach(
        now: @escaping () -> TimeInterval,
        freeze: @escaping (Bool) -> Void,
        jump: @escaping (TimeInterval) -> Void
    ) {
        read = now
        self.freeze = freeze
        shift = jump
    }

    var now: TimeInterval { read?() ?? 0 }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        freeze?(true)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        freeze?(false)
    }

    func jump(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        shift?(seconds)
    }
}

@MainActor
final class MixScheduledAction {
    var task: Task<Void, Never>?
    private(set) var isCancelled = false
    private(set) var hasFired = false

    func cancel() {
        isCancelled = true
        task?.cancel()
        task = nil
    }

    func markFired() { hasFired = true }
}

@MainActor
final class MixActionGroup {
    private(set) var actions: [MixScheduledAction] = []
    var outgoing: MixEngine.Deck = .a
    var incoming: MixEngine.Deck = .b
    var window: TimeInterval = 0
    var entrySeconds: TimeInterval = 0
    var blendStartClock: TimeInterval?
    var timelineGroup: Int32?
    var timeline: MixTimeline?
    var isFinished = false
    var finish: (@MainActor () -> Void)?
    var cancelTimeline: (@MainActor (Int32) -> Void)?
    var resolveBlendStart: (@MainActor (Int32) -> TimeInterval?)?

    func add(_ action: MixScheduledAction) {
        actions.append(action)
    }

    func blendStart() -> TimeInterval? {
        if let blendStartClock { return blendStartClock }
        guard let group = timelineGroup, let resolved = resolveBlendStart?(group) else { return nil }
        blendStartClock = resolved
        return resolved
    }

    func cancel() {
        for action in actions { action.cancel() }
        actions.removeAll()
        if let group = timelineGroup, !isFinished {
            cancelTimeline?(group)
        }
    }

    func cancelTimelineEvents() {
        if let group = timelineGroup { cancelTimeline?(group) }
    }
}
