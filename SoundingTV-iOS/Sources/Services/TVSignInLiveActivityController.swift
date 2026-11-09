import ActivityKit
import Combine
import Foundation

@MainActor
final class TVSignInLiveActivityController {
    static let shared = TVSignInLiveActivityController()

    typealias Attributes = TVSignInActivityAttributes
    typealias Phase = TVSignInActivityAttributes.Phase

    static let lingers: TimeInterval = 4

    private var activityID: String?
    private var phase: Phase?
    private var sessionId: String?
    private var subscription: AnyCancellable?

    private init() {}

    static func phase(for state: LinkClient.State) -> Phase {
        switch state {
        case .idle, .discovering, .connecting: return .connecting
        case .sending: return .waitingForSoundCloud
        case .completed: return .done
        case .failed, .rejected: return .failed
        }
    }

    func begin(tvName: String, kind: DeviceClass) {
        Task { await start(tvName: tvName, kind: kind, phase: .connecting) }
    }

    func track(sessionId: String) {
        guard activityID != nil || phase != nil else { return }
        self.sessionId = sessionId
        subscription = LinkClient.transfers
            .filter { $0.sessionId == sessionId }
            .map { Self.phase(for: $0.state) }
            .removeDuplicates()
            .sink { [weak self] phase in self?.move(to: phase) }
    }

    func cancel() {
        guard sessionId == nil else { return }
        subscription = nil
        phase = nil
        guard let id = activityID else { return }
        activityID = nil
        Task { await Self.end(id: id, phase: nil, after: 0) }
    }

    func abandon() {
        guard let phase, !phase.isFinished else { return }
        move(to: .failed)
    }

    private func start(tvName: String, kind: DeviceClass, phase: Phase) async {
        await Self.endAll()
        subscription = nil
        sessionId = nil
        self.phase = phase
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activityID = try Activity<Attributes>.request(
                attributes: Attributes(tvName: tvName, symbolName: kind.symbolName),
                content: ActivityContent(state: .init(phase: phase), staleDate: .now.addingTimeInterval(600)),
                pushType: nil
            ).id
        } catch {
            Log.link.info("[SignInActivity] not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func move(to next: Phase) {
        guard phase != next, !(phase?.isFinished ?? false) else { return }
        phase = next
        guard let id = activityID else { return }
        if next.isFinished {
            activityID = nil
            subscription = nil
            sessionId = nil
            Task { await Self.end(id: id, phase: next, after: Self.lingers) }
        } else {
            Task { await Self.update(id: id, phase: next) }
        }
    }

    private nonisolated static func update(id: String, phase: Phase) async {
        guard let target = Activity<Attributes>.activities.first(where: { $0.id == id }) else { return }
        await target.update(ActivityContent(state: .init(phase: phase), staleDate: .now.addingTimeInterval(600)))
    }

    private nonisolated static func end(id: String, phase: Phase?, after delay: TimeInterval) async {
        guard let target = Activity<Attributes>.activities.first(where: { $0.id == id }) else { return }
        let content = phase.map { ActivityContent(state: Attributes.ContentState(phase: $0), staleDate: nil) }
        await target.end(content, dismissalPolicy: delay > 0 ? .after(.now.addingTimeInterval(delay)) : .immediate)
    }

    private nonisolated static func endAll() async {
        for existing in Activity<Attributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    #if DEBUG
    func runFixture(_ raw: String) async {
        guard let phase = Phase(rawValue: raw) else { return }
        await start(tvName: "Living Room", kind: .tv, phase: phase)
    }
    #endif
}
