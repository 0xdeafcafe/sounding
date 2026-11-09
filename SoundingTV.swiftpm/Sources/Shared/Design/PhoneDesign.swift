import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    #if os(iOS)
    static let scBgBase = Color(uiColor: .systemBackground)
    static let scBgRaised = Color(uiColor: .secondarySystemBackground)
    static let scBgOverlay = Color(uiColor: .tertiarySystemBackground)
    static let scSeparator = Color(uiColor: .separator)

    static let scTextPrimary = Color(uiColor: .label)
    static let scTextSecondary = Color(uiColor: .secondaryLabel)
    static let scTextTertiary = Color(uiColor: .tertiaryLabel)
    #else
    static let scBgBase = Color.primary.opacity(0.04)
    static let scBgRaised = Color.primary.opacity(0.07)
    static let scBgOverlay = Color.primary.opacity(0.11)
    static let scSeparator = Color.primary.opacity(0.14)
    static let scTextPrimary = Color.primary
    static let scTextSecondary = Color.secondary
    static let scTextTertiary = Color.primary.opacity(0.46)
    #endif


    static let scDestructive = Color(red: 1.00, green: 0.31, blue: 0.27)
    static let scDestructiveOn = Color(red: 0.10, green: 0.00, blue: 0.00)

    static let scSuccess = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let scSuccessOn = Color(red: 0.00, green: 0.10, blue: 0.02)

    static let scWarning = Color(red: 1.00, green: 0.69, blue: 0.13)
    static let scWarningOn = Color(red: 0.10, green: 0.06, blue: 0.00)

    static let scBackgroundGradient = LinearGradient(
        colors: [scBgBase, scBgRaised],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let scAmbientFallback = scBgRaised
}

enum Space {
    static let hair: CGFloat = 4
    static let tight: CGFloat = 8
    static let snug: CGFloat = 12
    static let base: CGFloat = 16
    static let roomy: CGFloat = 20
    static let section: CGFloat = 32
    static let gutter: CGFloat = 20
    static let page: CGFloat = 24
}

enum Spacing {
    static let xs: CGFloat = Space.hair
    static let sm: CGFloat = Space.tight
    static let md: CGFloat = 14
    static let lg: CGFloat = Space.roomy
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 40
}

enum Corner {
    static let thumb: CGFloat = 5
    static let control: CGFloat = 10
    static let card: CGFloat = 13
    static let panel: CGFloat = 23
    static let hero: CGFloat = 28
}

enum Radius {
    static let sm: CGFloat = Corner.control
    static let md: CGFloat = Corner.card
    static let lg: CGFloat = Corner.panel
    static let xl: CGFloat = Corner.hero
}

extension Font {
    #if os(iOS)
    static let scDisplay  = Font.system(.largeTitle, weight: .bold)
    static let scTitle    = Font.system(.title2, weight: .bold)
    static let scSection  = Font.headline
    static let scTitle2   = Font.system(.title3, weight: .bold)
    static let scHeadline = Font.headline
    static let scBody     = Font.body
    static let scSubhead  = Font.subheadline
    static let scCaption  = Font.system(.caption, weight: .semibold)
    static let scNumeric  = Font.caption.monospacedDigit()
    #else
    static let scDisplay  = Font.system(size: 34, weight: .heavy)
    static let scTitle    = Font.system(size: 22, weight: .bold)
    static let scSection  = Font.system(size: 17, weight: .bold)
    static let scTitle2   = Font.system(size: 19, weight: .bold)
    static let scHeadline = Font.system(size: 16, weight: .semibold)
    static let scBody     = Font.system(size: 15, weight: .regular)
    static let scSubhead  = Font.system(size: 14, weight: .medium)
    static let scCaption  = Font.system(size: 12, weight: .semibold)
    static let scNumeric  = Font.system(size: 12, weight: .medium)
    #endif
}

enum Motion {
    static let press = Animation.spring(response: 0.30, dampingFraction: 0.82)
    static let focus = Animation.spring(response: 0.32, dampingFraction: 0.70)
    static let settle = Animation.spring(response: 0.50, dampingFraction: 0.80)
    static let ambient = Animation.easeInOut(duration: 0.6)
}

extension Animation {
    static func scMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    @ViewBuilder
    func scMotion<V: Equatable>(_ animation: Animation?, reduceMotion: Bool, value: V) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
}

struct ScScreenHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.snug) {
            Text(title)
                .font(.scDisplay)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.tight)
            trailing()
        }
    }
}

extension ScScreenHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

struct ScMediaRow<Artwork: View, Trailing: View>: View {
    static var artworkSize: CGFloat { 48 }

    var title: String
    var subtitle: String
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Space.snug) {
            artwork()
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scBody)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                Text(subtitle)
                    .font(.scSubhead)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
            }

            Spacer(minLength: Space.tight)
            trailing()
        }
        .padding(.vertical, Space.tight)
    }
}

extension ScMediaRow where Trailing == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder artwork: @escaping () -> Artwork) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.trailing = { EmptyView() }
    }
}

extension View {
}

private struct ScTransientBannerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.scSubhead)
            .foregroundStyle(Color.scTextPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassEffect(
                .regular.tint(Color.scBgBase.opacity(0.78)),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.scSeparator, lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
    }
}

extension View {
    func scTransientBanner() -> some View {
        modifier(ScTransientBannerModifier())
    }
}
