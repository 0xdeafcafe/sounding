import SwiftUI

// Content model for the "Behind This Track" surface. Wraps the existing
// `Track` (plus the label name only available from `TrackAbout`) instead of
// duplicating its fields, so every platform renders the same content.
struct SCBehindTrackModel: Sendable {
    let track: Track
    let label: String?

    init(track: Track, label: String? = nil) {
        self.track = track
        self.label = label
    }

    init(track: Track, about: TrackAbout?) {
        self.init(track: track, label: about?.labelName)
    }

    var title: String { track.title }
    var artist: String { track.user.displayName }
    var description: String? { track.description }
    var plays: Int? { track.playbackCount }
    var likes: Int { track.likeCount }
    var reposts: Int { track.repostCount }
    var uploadedAt: Date { track.createdAt }
    var relativeUploadDate: String { SCStatFormat.relativeDate(uploadedAt) }
    var genre: String? { track.genre.map(GenrePresentation.displayName(for:)) }
    var tags: [String] { track.tags }
    var uploaderName: String { track.user.displayName }
    var uploaderAvatarURL: URL? { track.user.largeAvatarURL ?? track.user.avatarURL }
    var permalinkURL: URL { track.permalinkURL }
}

enum SCStatFormat {
    static func compactCount(_ count: Int) -> String {
        CompactCount.string(count)
    }

    static func relativeDate(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
