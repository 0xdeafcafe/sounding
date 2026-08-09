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
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    static func relativeDate(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// Section eyebrow ("BEHIND THIS TRACK") — heavy caption, tracked out, accent.
struct SCEyebrow: View {
    let text: String
    var tint: Color?
    var style: SCContentStyle

    init(_ text: String, tint: Color? = nil, style: SCContentStyle = .tv) {
        self.text = text
        self.tint = tint
        self.style = style
    }

    var body: some View {
        Text(text.uppercased())
            .font(style.fontEyebrow.weight(.heavy))
            .kerning(1.4)
            .foregroundStyle(tint ?? style.accent)
    }
}

// Plays / likes / reposts as three flat columns. Value heavy + monospaced,
// label uppercase at ~55% of the value size.
struct SCStatsStrip: View {
    let plays: Int?
    let likes: Int
    let reposts: Int
    var style: SCContentStyle

    init(plays: Int?, likes: Int, reposts: Int, style: SCContentStyle = .tv) {
        self.plays = plays
        self.likes = likes
        self.reposts = reposts
        self.style = style
    }

    init(model: SCBehindTrackModel, style: SCContentStyle = .tv) {
        self.init(plays: model.plays, likes: model.likes, reposts: model.reposts, style: style)
    }

    var body: some View {
        HStack(alignment: .top, spacing: style.spaceRoomy) {
            if let plays { column(value: plays, label: "Plays") }
            column(value: likes, label: "Likes")
            column(value: reposts, label: "Reposts")
        }
        .accessibilityElement(children: .combine)
    }

    private func column(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: style.spaceHair) {
            Text(SCStatFormat.compactCount(value))
                .font(style.fontTitle.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(style.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label.uppercased())
                .font(style.fontCaptionEmphasis)
                .foregroundStyle(style.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Genre/tag capsules — semibold caption on a flat white 0.08 fill. Content,
// not chrome: never glass. Pass `onTap` to make chips tappable (e.g. into Search).
struct SCChipRow: View {
    let chips: [String]
    var style: SCContentStyle
    var onTap: ((String) -> Void)?

    init(_ chips: [String], style: SCContentStyle = .tv, onTap: ((String) -> Void)? = nil) {
        self.chips = chips
        self.style = style
        self.onTap = onTap
    }

    // Genre first, then label, then tags — the "Behind This Track" ordering.
    init(model: SCBehindTrackModel, style: SCContentStyle = .tv, onTap: ((String) -> Void)? = nil) {
        var chips: [String] = []
        if let genre = model.genre { chips.append(genre) }
        if let label = model.label { chips.append(label) }
        chips.append(contentsOf: model.tags)
        self.init(chips, style: style, onTap: onTap)
    }

    var body: some View {
        // Tags are identifiers, so wrapping individual words inside cramped
        // capsules is worse than letting the row scroll horizontally.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: style.spaceTight) {
                ForEach(chips, id: \.self) { chip in
                    if let onTap {
                        Button { onTap(chip) } label: { chipLabel(chip) }
                            .buttonStyle(.plain)
                    } else {
                        chipLabel(chip)
                    }
                }
            }
            .padding(.vertical, 1)
            // Give the first and last chip enough scroll runway to clear the
            // card's rounded clipping edge instead of stopping half-visible.
            .padding(.horizontal, style.spaceSnug)
        }
        .accessibilityElement(children: .contain)
    }

    private func chipLabel(_ chip: String) -> some View {
        Text(chip)
            .font(style.fontCaptionEmphasis)
            .foregroundStyle(style.textPrimary.opacity(0.88))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, style.spaceSnug)
            .padding(.vertical, style.spaceTight)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.13))
            }
    }
}
