import AppIntents
import Combine
import CoreSpotlight
import Foundation

extension Track: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .audio)
        set.title = title
        set.artist = user.displayName
        set.contentDescription = user.displayName
        set.duration = NSNumber(value: duration)
        set.thumbnailURL = largeArtworkURL ?? artworkURL
        set.contentURL = permalinkURL
        return set
    }
}

extension Playlist: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .audio)
        set.title = title
        set.artist = user.displayName
        set.contentDescription = "\(totalTrackCount) tracks by \(user.displayName)"
        set.thumbnailURL = largeArtworkURL ?? artworkURL
        set.contentURL = permalinkURL
        return set
    }
}

extension User: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .item)
        set.title = displayName
        if let city, !city.isEmpty {
            set.contentDescription = country.map { "\(city), \($0)" } ?? city
        }
        set.thumbnailURL = largeAvatarURL ?? avatarURL
        set.contentURL = permalinkURL
        return set
    }
}

private struct SearchableIndexHandle: @unchecked Sendable {
    private let index = CSSearchableIndex.default()

    func index(_ track: Track) async throws {
        try await index.indexAppEntities([track])
    }

    func deleteTrack(identifiedBy id: String) async throws {
        try await index.deleteAppEntities(identifiedBy: [id], ofType: Track.self)
    }
}

@MainActor
final class SpotlightIndexingService {
    static let shared = SpotlightIndexingService()

    private static let playDonationDelay: Duration = .seconds(8)

    private let index = SearchableIndexHandle()
    private var cancellables = Set<AnyCancellable>()
    private var playDonationTask: Task<Void, Never>?

    private init() {}

    func start(player: PlayerService) {
        player.$currentTrack
            .combineLatest(player.$isPlaying)
            .sink { [weak self] track, isPlaying in
                self?.scheduleDonation(for: track, isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .trackLikeChanged)
            .sink { [weak self] notification in
                self?.handleLikeChange(notification)
            }
            .store(in: &cancellables)
    }

    private func scheduleDonation(for track: Track?, isPlaying: Bool) {
        playDonationTask?.cancel()
        guard let track, isPlaying else { return }

        let trackId = track.id
        playDonationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.playDonationDelay)
            guard !Task.isCancelled, let self else { return }
            guard PlayerService.shared.currentTrack?.id == trackId,
                  PlayerService.shared.isPlaying else { return }
            await self.donate(track)
        }
    }

    private func handleLikeChange(_ notification: Notification) {
        guard let track = notification.userInfo?[SoundCloudAPI.likeNotificationTrackKey] as? Track,
              let liked = notification.userInfo?[SoundCloudAPI.likeNotificationLikedKey] as? Bool else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if liked {
                await self.donate(track)
            } else {
                try? await self.index.deleteTrack(identifiedBy: track.id)
            }
        }
    }

    private func donate(_ track: Track) async {
        do {
            try await index.index(track)
        } catch {
        }
    }
}
