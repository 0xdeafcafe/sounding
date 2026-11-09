import Foundation
import Intents

final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    static let resumeIdentifier = "resume"

    enum Outcome: Sendable {
        case resolved(MediaResolution)
        case resume
        case signedOut
        case notFound
        case notEntitled
        case failed
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        if let items = intent.mediaItems, !items.isEmpty {
            return INPlayMediaMediaItemResolutionResult.successes(with: items)
        }
        let request = MediaRequest(search: intent.mediaSearch, shuffle: intent.playShuffled ?? false)
        switch await Self.resolve(request) {
        case .resolved(let resolution):
            return [.success(with: Self.mediaItem(for: resolution))]
        case .resume:
            return [.success(with: INMediaItem(identifier: Self.resumeIdentifier, title: nil, type: .music, artwork: nil))]
        case .signedOut:
            return [.unsupported(forReason: .loginRequired)]
        case .notEntitled:
            return [.unsupported(forReason: .subscriptionRequired)]
        case .notFound, .failed:
            return [.unsupported()]
        }
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let identifier = intent.mediaItems?.first?.identifier ?? Self.resumeIdentifier
        let shuffle = intent.playShuffled ?? false
        switch await Self.perform(identifier: identifier, shuffle: shuffle) {
        case .resolved, .resume:
            return INPlayMediaIntentResponse(code: .success, userActivity: nil)
        case .signedOut:
            return INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)
        case .notEntitled:
            return INPlayMediaIntentResponse(code: .failureRestrictedContent, userActivity: nil)
        case .notFound:
            return INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil)
        case .failed:
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
    }

    static func mediaItem(for resolution: MediaResolution) -> INMediaItem {
        var identifier = resolution.target.identifier
        if resolution.shuffle { identifier += "#shuffle" }
        return INMediaItem(
            identifier: identifier,
            title: resolution.title.isEmpty ? nil : resolution.title,
            type: resolution.mediaItemType,
            artwork: nil,
            artist: resolution.subtitle.isEmpty ? nil : resolution.subtitle
        )
    }

    @MainActor
    private static func resolve(_ request: MediaRequest?) async -> Outcome {
        guard let request else { return .resume }
        guard SoundCloudAPI.credentials?.accessToken != nil else { return .signedOut }
        do {
            return .resolved(try await MediaRequestResolver().resolve(request))
        } catch {
            return outcome(for: error)
        }
    }

    @MainActor
    private static func perform(identifier: String, shuffle: Bool) async -> Outcome {
        do {
            if identifier == resumeIdentifier {
                try await PlaybackControlBridge.setPlaying(true)
                return .resume
            }
            let shuffled = shuffle || identifier.hasSuffix("#shuffle")
            let raw = identifier.hasSuffix("#shuffle") ? String(identifier.dropLast("#shuffle".count)) : identifier
            guard let target = MediaTarget(identifier: raw) else { return .notFound }
            let resolution = MediaResolution(target: target, title: "", source: .search, shuffle: shuffled)
            try await IntentPlayback.play(resolution)
            return .resolved(resolution)
        } catch {
            return outcome(for: error)
        }
    }

    private static func outcome(for error: Error) -> Outcome {
        switch error {
        case PlaybackIntentError.signedOut: return .signedOut
        case PlaybackIntentError.notEntitled: return .notEntitled
        case PlaybackIntentError.notFound, is MediaRequestError: return .notFound
        default: return .failed
        }
    }
}
