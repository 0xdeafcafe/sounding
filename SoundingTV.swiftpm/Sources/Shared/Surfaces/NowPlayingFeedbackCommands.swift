import Foundation
import MediaPlayer
import Observation

struct NowPlayingFeedbackSubject: Equatable {
    let trackID: String
    let track: Track?
    let canLike: Bool
}

@MainActor
final class NowPlayingFeedbackCommands {
    static let shared = NowPlayingFeedbackCommands()

    private let likes = NowPlayingLikeModel.shared
    private var targets: [(MPRemoteCommand, Any)] = []
    private var subject: @MainActor () -> NowPlayingFeedbackSubject? = { nil }
    private var skip: @MainActor () -> Void = {}
    private var refreshedTrackID: String?
    private var isObservingLikes = false

    var isEnabled: Bool { !targets.isEmpty }

    func enable(subject: @escaping @MainActor () -> NowPlayingFeedbackSubject?, skip: @escaping @MainActor () -> Void) {
        self.subject = subject
        self.skip = skip
        guard targets.isEmpty else {
            refresh()
            return
        }
        let center = MPRemoteCommandCenter.shared()
        center.likeCommand.localizedTitle = "Add to Likes"
        center.likeCommand.localizedShortTitle = "Like"
        center.dislikeCommand.localizedTitle = "Not for Me"
        center.dislikeCommand.localizedShortTitle = "Not for Me"
        targets.append((center.likeCommand, center.likeCommand.addTarget { event in
            let negative = (event as? MPFeedbackCommandEvent)?.isNegative ?? false
            Task { @MainActor in NowPlayingFeedbackCommands.shared.setLiked(!negative) }
            return .success
        }))
        targets.append((center.dislikeCommand, center.dislikeCommand.addTarget { event in
            let negative = (event as? MPFeedbackCommandEvent)?.isNegative ?? false
            Task { @MainActor in NowPlayingFeedbackCommands.shared.dislike(undo: negative) }
            return .success
        }))
        observeLikes()
        refresh()
    }

    func disable() {
        guard !targets.isEmpty else { return }
        for (command, token) in targets {
            command.removeTarget(token)
            if let feedback = command as? MPFeedbackCommand { feedback.isActive = false }
            command.isEnabled = false
        }
        targets.removeAll()
        subject = { nil }
        skip = {}
        refreshedTrackID = nil
    }

    func refresh() {
        guard isEnabled else { return }
        let center = MPRemoteCommandCenter.shared()
        let current = subject()
        if let current, current.trackID != refreshedTrackID, current.canLike {
            likes.refresh(trackId: current.trackID, resolved: current.track)
        }
        refreshedTrackID = current?.trackID
        let canLike = current?.canLike ?? false
        let liked = current.map { likes.isLiked($0.trackID, resolved: $0.track) } ?? false
        if center.likeCommand.isEnabled != canLike { center.likeCommand.isEnabled = canLike }
        if center.likeCommand.isActive != (canLike && liked) { center.likeCommand.isActive = canLike && liked }
        let canDislike = current != nil
        if center.dislikeCommand.isEnabled != canDislike { center.dislikeCommand.isEnabled = canDislike }
        if center.dislikeCommand.isActive { center.dislikeCommand.isActive = false }
    }

    private func setLiked(_ wanted: Bool) {
        guard let current = subject(), current.canLike else { return }
        if likes.isLiked(current.trackID, resolved: current.track) != wanted {
            likes.toggle(trackId: current.trackID, resolved: current.track)
        }
        refresh()
    }

    private func dislike(undo: Bool) {
        guard !undo, let current = subject() else { return }
        if current.canLike, likes.isLiked(current.trackID, resolved: current.track) {
            likes.toggle(trackId: current.trackID, resolved: current.track)
        }
        skip()
    }

    private func observeLikes() {
        guard !isObservingLikes else { return }
        isObservingLikes = true
        withObservationTracking {
            _ = likes.liked
        } onChange: {
            Task { @MainActor in
                let commands = NowPlayingFeedbackCommands.shared
                commands.isObservingLikes = false
                guard commands.isEnabled else { return }
                commands.refresh()
                commands.observeLikes()
            }
        }
    }
}
