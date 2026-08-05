import SwiftUI

struct SCArtwork: View {
    let image: Image?
    let identity: String
    var isAvailable: Bool = true
    var style: SCContentStyle = .tv
    var cornerRadius: CGFloat?
    /// Dense lists should opt out: generated mesh artwork owns an ambient
    /// animation task and is far too expensive when dozens of rows are alive.
    var usesGeneratedFallback = true

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if usesGeneratedFallback {
                GeneratedArtworkCard(identity: identity, mode: .blob, style: style)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.075))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: style.iconStrokeWidth * 6, weight: .medium))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                    }
            }

            if !isAvailable {
                Color.black.opacity(0.55)
                Image(systemName: "slash.circle")
                    .font(.system(size: style.iconStrokeWidth * 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? style.artworkCorner, style: .continuous))
        .accessibilityHidden(image == nil && isAvailable)
        .accessibilityLabel(isAvailable ? "" : "Unavailable")
    }
}

struct SCSectionHeader: View {
    var eyebrow: String?
    var title: String
    var showChevron: Bool = false
    var titleLineLimit: Int? = 1
    var action: (() -> Void)?
    var style: SCContentStyle = .tv

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: style.spaceHair) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(style.fontEyebrow)
                    .foregroundStyle(style.textSecondary)
                    .kerning(1.6)
            }
            HStack(spacing: style.spaceHair) {
                Text(title)
                    .font(style.fontTitle)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(titleLineLimit)
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(style.fontTitle)
                        .imageScale(.small)
                        .foregroundStyle(style.textSecondary)
                }
            }
        }
    }
}

struct SCTrackRow<Trailing: View>: View {
    let title: String
    let subtitle: String

    var eyebrow: String?

    var eyebrowIcon: String?

    let artworkImage: Image?
    var isAvailable: Bool = true
    var badges: SCAnalysisBadgeRow?
    var crownUser: User?
    var crownContext: String?
    var style: SCContentStyle = .tv
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: style.spaceSnug) {
            SCArtwork(image: artworkImage, identity: title, isAvailable: isAvailable, style: style)
                .frame(width: style.rowArtworkSize, height: style.rowArtworkSize)
                .kyleCrowned(user: crownUser, context: crownContext)

            VStack(alignment: .leading, spacing: style.spaceHair / 2) {
                if let eyebrow {
                    Group {
                        if let eyebrowIcon {
                            Label(eyebrow, systemImage: eyebrowIcon)
                        } else {
                            Text(eyebrow)
                        }
                    }
                    .font(style.fontCaption)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
                }
                Text(title)
                    .font(style.fontBody)
                    .foregroundStyle(isAvailable ? style.textPrimary : style.textTertiary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(style.fontSubheadline)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
                if let badges {
                    badges
                        .padding(.top, style.spaceHair / 2)
                }
            }

            Spacer(minLength: style.spaceTight)
            trailing()
        }
        .padding(.vertical, style.spaceTight)
        .opacity(isAvailable ? 1 : 0.72)
    }
}

extension SCTrackRow where Trailing == EmptyView {
    init(
        title: String, subtitle: String,
        eyebrow: String? = nil, eyebrowIcon: String? = nil,
        artworkImage: Image?,
        isAvailable: Bool = true, badges: SCAnalysisBadgeRow? = nil,
        crownUser: User? = nil, crownContext: String? = nil,
        style: SCContentStyle = .tv
    ) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
        self.eyebrowIcon = eyebrowIcon
        self.artworkImage = artworkImage
        self.isAvailable = isAvailable
        self.badges = badges
        self.crownUser = crownUser
        self.crownContext = crownContext
        self.style = style
        self.trailing = { EmptyView() }
    }
}

struct SCMediaCard: View {
    let title: String
    let subtitle: String?
    let artworkImage: Image?
    var isAvailable: Bool = true
    var crownUser: User?
    var crownContext: String?
    var style: SCContentStyle = .tv
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceTight) {
            SCArtwork(image: artworkImage, identity: title, isAvailable: isAvailable, style: style)
                .aspectRatio(1, contentMode: .fit)
                .kyleCrowned(user: crownUser, context: crownContext)
                .overlay(alignment: .bottom) {
                    if let resume = Self.resolvedProgress(progress) {
                        SCProgressBar(progress: resume, style: style)
                            .padding(.horizontal, style.spaceTight)
                            .padding(.bottom, style.spaceTight)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(isAvailable ? style.textPrimary : style.textTertiary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(isAvailable ? 1 : 0.72)
    }

    static func resolvedProgress(_ raw: Double?) -> Double? {
        guard let raw, raw > 0.005, raw < 0.995 else { return nil }
        return min(max(raw, 0), 1)
    }
}

struct SCProgressBar: View {
    let progress: Double
    var style: SCContentStyle = .tv

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.45))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(style.progressBarHeight, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: style.progressBarHeight)
        .accessibilityHidden(true)
    }
}

struct SCArtistCard: View {
    let name: String
    var subtitle: String?
    let avatarImage: Image?
    var identity: String?
    var hasUnread: Bool = false
    var diameter: CGFloat?
    var crownUser: User?
    var crownContext: String?
    var style: SCContentStyle = .tv

    var resolvedDiameter: CGFloat { diameter ?? style.artistCircleDiameter }

    private static let unreadArcInset: CGFloat = 0.14645

    private var unreadDiameter: CGFloat { max(8, (resolvedDiameter * 0.10).rounded()) }

    var body: some View {
        VStack(alignment: .center, spacing: style.spaceTight) {
            SCArtwork(image: avatarImage, identity: identity ?? name, style: style)
                .frame(width: resolvedDiameter, height: resolvedDiameter)
                .clipShape(Circle())
                .kyleCrowned(user: crownUser, context: crownContext)
                .overlay(alignment: .topTrailing) {
                    if hasUnread { unreadDot }
                }

            VStack(alignment: .center, spacing: 2) {
                Text(name)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                if let subtitle {
                    Text(subtitle)
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: resolvedDiameter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasUnread ? "\(name), new music" : name)
    }

    private var unreadDot: some View {
        Circle()
            .fill(style.accent)
            .overlay {
                Circle().strokeBorder(.black.opacity(0.30), lineWidth: max(1, style.iconStrokeWidth * 0.5))
            }
            .frame(width: unreadDiameter, height: unreadDiameter)
            .padding(max(0, resolvedDiameter * Self.unreadArcInset - unreadDiameter / 2))
            .accessibilityHidden(true)
    }
}

struct SCArtistCardFocusShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let edge = max(0, min(rect.width, rect.height) - insetAmount * 2)
        let origin = CGPoint(x: rect.midX - edge / 2, y: rect.minY + insetAmount)
        return Circle().path(in: CGRect(origin: origin, size: CGSize(width: edge, height: edge)))
    }

    func inset(by amount: CGFloat) -> Self {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

struct SCHeroCard: View {
    var eyebrow: String?
    let title: String
    var description: String?
    var backgroundImage: Image?
    var style: SCContentStyle = .tv
    var isAvailable: Bool = true
    var identity: String?
    var cornerRadius: CGFloat?
    var crownUser: User?
    var crownContext: String?

    private var resolvedCorner: CGFloat { cornerRadius ?? style.cornerHero }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backgroundImage {
                    Color.clear
                        .overlay {
                            ZStack {
                                backgroundImage
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                if !isAvailable {
                                    Color.black.opacity(0.55)
                                    Image(systemName: "slash.circle")
                                        .font(.system(size: style.iconStrokeWidth * 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        .clipped()
                } else {
                    SCArtwork(
                        image: nil,
                        identity: identity ?? title,
                        isAvailable: isAvailable,
                        style: style,
                        cornerRadius: resolvedCorner
                    )
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: style.spaceHair) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(style.fontCaptionEmphasis)
                        .foregroundStyle(.white.opacity(0.85))
                        .kerning(1.2)
                        .lineLimit(1)
                }
                Text(title)
                    .font(style.fontHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let description {
                    Text(description)
                        .font(style.fontCaption)
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(2)
                }
            }
            .padding(style.spaceBase)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: resolvedCorner, style: .continuous))
        .kyleCrowned(user: crownUser, context: crownContext)
    }
}

struct SCEmptyState: View {
    enum Kind {
        case empty
        case error
    }

    var kind: Kind = .empty
    var icon: String = "music.note"
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var style: SCContentStyle = .tv

    var body: some View {
        VStack(spacing: style.spaceSnug) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : icon)
                .font(.system(size: style.iconStrokeWidth * 20, weight: .semibold))
                .foregroundStyle(kind == .error ? style.destructive : style.textTertiary)

            Text(title)
                .font(style.fontHeadline)
                .foregroundStyle(style.textPrimary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(style.fontBody)
                    .foregroundStyle(style.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(style.fontBodyEmphasis)
                        .foregroundStyle(style.accentOn)
                        .padding(.horizontal, style.spaceBase)
                        .padding(.vertical, style.spaceTight)
                        .background(Capsule(style: .continuous).fill(style.accent))
                }
                .buttonStyle(.plain)
                .padding(.top, style.spaceHair)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(style.spaceRoomy)
    }
}
