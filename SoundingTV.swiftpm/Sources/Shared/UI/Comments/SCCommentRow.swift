import SwiftUI

struct SCCommentRow: View {
    let comment: Comment
    var isReply: Bool = false
    var isHighlighted: Bool = false
    var bodyLineLimit: Int?
    var style: SCContentStyle = .tv

    private var rootAvatarSize: CGFloat { (style.rowArtworkSize * 0.6).rounded() }
    private var replyAvatarSize: CGFloat { (style.rowArtworkSize * 0.45).rounded() }
    private var avatarSize: CGFloat { isReply ? replyAvatarSize : rootAvatarSize }

    var body: some View {
        HStack(alignment: .top, spacing: style.spaceSnug) {
            if isReply {
                Capsule(style: .continuous)
                    .fill(style.separator)
                    .frame(width: max(2, (style.iconStrokeWidth * 0.75).rounded()), height: avatarSize)
                    .padding(.leading, (rootAvatarSize / 2).rounded())
            }

            SCArtworkResolver(url: comment.user.avatarURL) { image in
                SCArtwork(image: image, identity: comment.user.id, style: style, subject: .person)
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: style.spaceHair / 2) {
                metaLine
                Text(comment.body)
                    .font(style.fontBody)
                    .foregroundStyle(isHighlighted ? style.textPrimary : style.textSecondary)
                    .lineLimit(bodyLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var metaLine: some View {
        HStack(spacing: style.spaceTight) {
            Text(comment.user.displayName)
                .font(style.fontCaptionEmphasis)
                .foregroundStyle(style.textPrimary)
                .lineLimit(1)

            if let time = comment.timeInTrack {
                Text(CommentFormat.clock(time))
                    .font(style.fontCaptionEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(style.accent)
            }

            if let age = CommentFormat.age(of: comment.createdAt) {
                Text(age)
                    .font(style.fontCaption)
                    .foregroundStyle(style.textTertiary)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [comment.user.displayName]
        if isReply { parts.append("reply") }
        if let time = comment.timeInTrack { parts.append("at \(CommentFormat.clock(time))") }
        parts.append(comment.body)
        return parts.joined(separator: ", ")
    }
}
