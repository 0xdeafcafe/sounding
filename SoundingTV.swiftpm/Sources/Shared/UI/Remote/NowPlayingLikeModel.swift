import Foundation
import Observation
import SwiftUI

@MainActor
protocol NowPlayingLikeService {
    func setLiked(_ liked: Bool, trackId: String, resolved: Track?) async throws
    func indexedLike(trackId: String) async -> Bool
}

@MainActor
struct SoundCloudLikeService: NowPlayingLikeService {
    func setLiked(_ liked: Bool, trackId: String, resolved: Track?) async throws {
        let track: Track
        if let resolved, resolved.id == trackId {
            track = resolved
        } else {
            track = try await SoundCloudAPI.shared.getTrack(id: trackId)
        }
        try await LikeRequest.sendOnce(liked, track: track)
    }

    func indexedLike(trackId: String) async -> Bool {
        await LibraryCache.shared.containsLike(id: trackId)
    }
}

enum LikeRetryPolicy {
    static let maximumWait: TimeInterval = 600
    static let maximumAttempts = 3
    static let fallbackWait: TimeInterval = 60

    static func resumeDate(after error: any Error, now: Date, stoppedUntil: Date?) -> Date? {
        let until: Date
        if let api = error as? APIError {
            switch api {
            case .rateLimited(let resetAt):
                until = resetAt ?? stoppedUntil ?? now.addingTimeInterval(fallbackWait)
            case .temporarilyBlocked(let blocked, let statusCode):
                guard statusCode == 429 else { return nil }
                until = blocked
            default:
                return nil
            }
        } else if let gate = error as? SoundCloudGatewayError {
            switch gate {
            case .backgroundPaused(let paused):
                until = paused
            case .endpointCoolingDown(_, let cooling):
                until = cooling
            default:
                return nil
            }
        } else {
            return nil
        }
        guard until.timeIntervalSince(now) <= maximumWait else { return nil }
        return max(until, now)
    }

    static func isRateLimit(_ error: any Error) -> Bool {
        if let api = error as? APIError {
            switch api {
            case .rateLimited, .temporarilyBlocked: return true
            default: return false
            }
        }
        if let gate = error as? SoundCloudGatewayError {
            switch gate {
            case .backgroundPaused, .endpointCoolingDown: return true
            default: return false
            }
        }
        return false
    }

    static func message(for error: any Error, stoppedUntil: Date?) -> String {
        if isRateLimit(error) {
            if let stoppedUntil {
                return "SoundCloud is limiting requests. Try again after \(stoppedUntil.formatted(date: .omitted, time: .shortened))."
            }
            return "SoundCloud is limiting requests. Try again in a few minutes."
        }
        if let api = error as? APIError {
            switch api {
            case .unauthorized: return "Sign in to SoundCloud again to change your Likes."
            case .forbidden: return "SoundCloud didn’t allow this change."
            case .notFound: return "This track isn’t on SoundCloud any more."
            default: break
            }
        }
        if error is URLError { return "You’re offline. Try again when you’re connected." }
        return "SoundCloud didn’t save the change. Try again."
    }

    @MainActor
    static func currentStop() -> Date? {
        if case .waiting(_, let until) = SoundCloudGateway.shared.trafficSafetyState() { return until }
        return nil
    }
}

@MainActor
enum LikeRequest {
    static func sendOnce(_ liked: Bool, track: Track) async throws {
        do {
            if liked {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
        } catch APIError.serverError(404) where !liked {
            return
        }
    }

    static func send(_ liked: Bool, track: Track) async throws {
        var attempts = 0
        while true {
            do {
                try await sendOnce(liked, track: track)
                return
            } catch {
                attempts += 1
                guard attempts < LikeRetryPolicy.maximumAttempts,
                      let resume = LikeRetryPolicy.resumeDate(after: error, now: Date(), stoppedUntil: LikeRetryPolicy.currentStop()) else {
                    NowPlayingLikeModel.shared.report(error, liked: liked)
                    throw error
                }
                try? await Task.sleep(for: .seconds(max(0, resume.timeIntervalSinceNow)))
                if Task.isCancelled { throw error }
            }
        }
    }
}

struct NowPlayingLikeFailure: Identifiable, Equatable {
    let id = UUID()
    let liked: Bool
    let message: String

    var title: String { liked ? "Couldn’t Add to Likes" : "Couldn’t Remove from Likes" }
}

@MainActor
@Observable
final class NowPlayingLikeModel {
    static let shared = NowPlayingLikeModel()

    private(set) var liked: [String: Bool] = [:]
    private(set) var failure: NowPlayingLikeFailure?
    @ObservationIgnored private var confirmed: [String: Bool] = [:]
    @ObservationIgnored private var tracks: [String: Track] = [:]
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let service: any NowPlayingLikeService
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let pause: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let stoppedUntil: @MainActor () -> Date?

    init(
        service: any NowPlayingLikeService = SoundCloudLikeService(),
        settleDelay: Duration = .milliseconds(350),
        now: @escaping @MainActor () -> Date = { Date() },
        pause: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        },
        stoppedUntil: @escaping @MainActor () -> Date? = { LikeRetryPolicy.currentStop() }
    ) {
        self.service = service
        self.settleDelay = settleDelay
        self.now = now
        self.pause = pause
        self.stoppedUntil = stoppedUntil
    }

    func isLiked(_ trackId: String, resolved: Track?) -> Bool {
        if let value = liked[trackId] { return value }
        guard let resolved, resolved.id == trackId else { return false }
        return resolved.userFavorite
    }

    func isSyncing(_ trackId: String) -> Bool {
        workers[trackId] != nil
    }

    func refresh(trackId: String?, resolved: Track?) {
        guard let trackId, !isOwnedLocally(trackId) else { return }
        let base = resolved?.id == trackId ? (resolved?.userFavorite ?? false) : false
        refreshes[trackId]?.cancel()
        refreshes[trackId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let indexed = await self.service.indexedLike(trackId: trackId)
            guard !Task.isCancelled else { return }
            self.refreshes[trackId] = nil
            guard !self.isOwnedLocally(trackId) else { return }
            self.liked[trackId] = base || indexed
        }
    }

    func toggle(trackId: String, resolved: Track?) {
        let current = isLiked(trackId, resolved: resolved)
        if confirmed[trackId] == nil { confirmed[trackId] = current }
        if let resolved, resolved.id == trackId { tracks[trackId] = resolved }
        refreshes.removeValue(forKey: trackId)?.cancel()
        liked[trackId] = !current
        guard workers[trackId] == nil else { return }
        workers[trackId] = Task { @MainActor [weak self] in
            await self?.sync(trackId)
        }
    }

    func waitUntilSettled(_ trackId: String) async {
        while let worker = workers[trackId] {
            await worker.value
        }
    }

    func dismissFailure() {
        failure = nil
    }

    func report(_ error: any Error, liked wanted: Bool) {
        let stop = stoppedUntil()
        if LikeRetryPolicy.isRateLimit(error), stop != nil { return }
        failure = NowPlayingLikeFailure(liked: wanted, message: LikeRetryPolicy.message(for: error, stoppedUntil: stop))
    }

    private func isOwnedLocally(_ trackId: String) -> Bool {
        confirmed[trackId] != nil || workers[trackId] != nil
    }

    private func sync(_ trackId: String) async {
        defer { workers[trackId] = nil }
        var attempts = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: settleDelay)
            guard let wanted = liked[trackId], let known = confirmed[trackId], wanted != known else { return }
            do {
                try await service.setLiked(wanted, trackId: trackId, resolved: tracks[trackId])
                confirmed[trackId] = wanted
                attempts = 0
            } catch {
                attempts += 1
                if attempts < LikeRetryPolicy.maximumAttempts,
                   let resume = LikeRetryPolicy.resumeDate(after: error, now: now(), stoppedUntil: stoppedUntil()) {
                    await pause(resume.timeIntervalSince(now()))
                    continue
                }
                liked[trackId] = confirmed[trackId]
                report(error, liked: wanted)
                return
            }
        }
    }
}

struct NowPlayingLikeFailureAlert: ViewModifier {
    private let likes = NowPlayingLikeModel.shared

    func body(content: Content) -> some View {
        content.alert(
            likes.failure?.title ?? "",
            isPresented: Binding(
                get: { likes.failure != nil },
                set: { if !$0 { likes.dismissFailure() } }
            ),
            presenting: likes.failure
        ) { _ in
            Button("OK", role: .cancel) { likes.dismissFailure() }
        } message: { failure in
            Text(failure.message)
        }
    }
}

extension View {
    func likeFailureAlert() -> some View {
        modifier(NowPlayingLikeFailureAlert())
    }
}
