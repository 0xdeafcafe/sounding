import SwiftUI

struct SCContentStyle: Sendable {
    var cornerControl: CGFloat
    var cornerCard: CGFloat
    var cornerPanel: CGFloat
    var cornerHero: CGFloat

    var spaceHair: CGFloat
    var spaceTight: CGFloat
    var spaceSnug: CGFloat
    var spaceBase: CGFloat
    var spaceRoomy: CGFloat
    var spaceSection: CGFloat
    var spaceGutter: CGFloat

    var fontEyebrow: Font
    var fontTitle: Font
    var fontHeadline: Font
    var fontSubheadline: Font
    var fontBody: Font
    var fontBodyEmphasis: Font
    var fontCaption: Font
    var fontCaptionEmphasis: Font

    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var bgRaised: Color
    var bgOverlay: Color
    var separator: Color
    var accent: Color
    var accentOn: Color
    var accentMuted: Color
    var warning: Color
    var warningOn: Color
    var destructive: Color
    var destructiveOn: Color
    var success: Color
    var successOn: Color

    var rowArtworkSize: CGFloat

    var artistCircleDiameter: CGFloat

    var iconStrokeWidth: CGFloat

    var artworkCorner: CGFloat { cornerControl }

    var progressBarHeight: CGFloat { max(2, (spaceTight * 0.5).rounded()) }

    static let tv = SCContentStyle(
        cornerControl: 14, cornerCard: 18, cornerPanel: 32, cornerHero: 44,
        spaceHair: 4, spaceTight: 8, spaceSnug: 16, spaceBase: 24,
        spaceRoomy: 32, spaceSection: 48, spaceGutter: 40,
        fontEyebrow: .system(size: 28, weight: .heavy),
        fontTitle: .system(size: 48, weight: .heavy),
        fontHeadline: .system(size: 38, weight: .bold),
        fontSubheadline: .system(size: 31, weight: .semibold),
        fontBody: .system(size: 29, weight: .regular),
        fontBodyEmphasis: .system(size: 29, weight: .semibold),
        fontCaption: .system(size: 28, weight: .regular),
        fontCaptionEmphasis: .system(size: 28, weight: .semibold),
        textPrimary: .white,
        textSecondary: .white.opacity(0.68),
        textTertiary: .white.opacity(0.58),
        bgRaised: Color(white: 0.192),
        bgOverlay: Color(white: 0.255),
        separator: .white.opacity(0.14),
        accent: Color(red: 1.00, green: 0.42, blue: 0.10),
        accentOn: Color(red: 0.10, green: 0.04, blue: 0.00),
        accentMuted: Color(red: 1.00, green: 0.42, blue: 0.10).opacity(0.20),
        warning: Color(red: 1.00, green: 0.69, blue: 0.13),
        warningOn: Color(red: 0.10, green: 0.06, blue: 0.00),
        destructive: Color(red: 1.00, green: 0.31, blue: 0.27),
        destructiveOn: Color(red: 0.10, green: 0.00, blue: 0.00),
        success: Color(red: 0.20, green: 0.78, blue: 0.35),
        successOn: Color(red: 0.00, green: 0.10, blue: 0.02),
        rowArtworkSize: 84,
        artistCircleDiameter: 260,
        iconStrokeWidth: 3.5
    )

    private static func phoneFont(_ style: Font.TextStyle, size: CGFloat, weight: Font.Weight) -> Font {
        #if os(iOS)
        .system(style, weight: weight)
        #else
        .system(size: size, weight: weight)
        #endif
    }

    static let phone = SCContentStyle(
        cornerControl: 10, cornerCard: 13, cornerPanel: 23, cornerHero: 28,
        spaceHair: 4, spaceTight: 8, spaceSnug: 12, spaceBase: 16,
        spaceRoomy: 20, spaceSection: 32, spaceGutter: 20,
        fontEyebrow: phoneFont(.caption, size: 12, weight: .semibold),
        fontTitle: phoneFont(.title2, size: 22, weight: .bold),
        fontHeadline: phoneFont(.headline, size: 16, weight: .semibold),
        fontSubheadline: phoneFont(.subheadline, size: 14, weight: .regular),
        fontBody: phoneFont(.body, size: 15, weight: .regular),
        fontBodyEmphasis: phoneFont(.body, size: 15, weight: .semibold),
        fontCaption: phoneFont(.caption, size: 12, weight: .regular),
        fontCaptionEmphasis: phoneFont(.caption, size: 12, weight: .semibold),
        textPrimary: .primary,
        textSecondary: .secondary,
        textTertiary: Color.primary.opacity(0.6),
        bgRaised: Color.primary.opacity(0.05),
        bgOverlay: Color.primary.opacity(0.09),
        separator: Color.primary.opacity(0.14),
        accent: Color(red: 1.00, green: 0.42, blue: 0.10),
        accentOn: Color(red: 0.10, green: 0.04, blue: 0.00),
        accentMuted: Color(red: 1.00, green: 0.42, blue: 0.10).opacity(0.20),
        warning: Color(red: 1.00, green: 0.69, blue: 0.13),
        warningOn: Color(red: 0.10, green: 0.06, blue: 0.00),
        destructive: Color(red: 1.00, green: 0.31, blue: 0.27),
        destructiveOn: Color(red: 0.10, green: 0.00, blue: 0.00),
        success: Color(red: 0.20, green: 0.78, blue: 0.35),
        successOn: Color(red: 0.00, green: 0.10, blue: 0.02),
        rowArtworkSize: 48,
        artistCircleDiameter: 157,
        iconStrokeWidth: 2.0
    )

    static var phoneSectionHeader: SCContentStyle {
        var style = SCContentStyle.phone
        style.fontTitle = phoneFont(.title3, size: 17, weight: .bold)
        return style
    }

    static let mac = SCContentStyle(
        cornerControl: 8, cornerCard: 12, cornerPanel: 16, cornerHero: 20,
        spaceHair: 4, spaceTight: 6, spaceSnug: 10, spaceBase: 14,
        spaceRoomy: 18, spaceSection: 28, spaceGutter: 16,
        fontEyebrow: .system(size: 11, weight: .semibold),
        fontTitle: .system(size: 20, weight: .bold),
        fontHeadline: .system(size: 15, weight: .semibold),
        fontSubheadline: .system(size: 13, weight: .medium),
        fontBody: .system(size: 13, weight: .regular),
        fontBodyEmphasis: .system(size: 13, weight: .semibold),
        fontCaption: .system(size: 11, weight: .regular),
        fontCaptionEmphasis: .system(size: 11, weight: .semibold),
        textPrimary: .primary,
        textSecondary: .secondary,
        textTertiary: Color.primary.opacity(0.6),
        bgRaised: Color.primary.opacity(0.06),
        bgOverlay: Color.primary.opacity(0.10),
        separator: Color.primary.opacity(0.14),
        accent: Color(red: 1.00, green: 0.42, blue: 0.10),
        accentOn: Color(red: 0.10, green: 0.04, blue: 0.00),
        accentMuted: Color(red: 1.00, green: 0.42, blue: 0.10).opacity(0.20),
        warning: Color(red: 1.00, green: 0.69, blue: 0.13),
        warningOn: Color(red: 0.10, green: 0.06, blue: 0.00),
        destructive: Color(red: 1.00, green: 0.31, blue: 0.27),
        destructiveOn: Color(red: 0.10, green: 0.00, blue: 0.00),
        success: Color(red: 0.20, green: 0.78, blue: 0.35),
        successOn: Color(red: 0.00, green: 0.10, blue: 0.02),
        rowArtworkSize: 40,
        artistCircleDiameter: 130,
        iconStrokeWidth: 1.5
    )

    static let watch = SCContentStyle(
        cornerControl: 8, cornerCard: 11, cornerPanel: 18, cornerHero: 22,
        spaceHair: 2, spaceTight: 5, spaceSnug: 8, spaceBase: 11,
        spaceRoomy: 14, spaceSection: 20, spaceGutter: 10,
        fontEyebrow: .system(size: 11, weight: .semibold),
        fontTitle: .system(size: 17, weight: .bold),
        fontHeadline: .system(size: 15, weight: .semibold),
        fontSubheadline: .system(size: 13, weight: .medium),
        fontBody: .system(size: 14, weight: .regular),
        fontBodyEmphasis: .system(size: 14, weight: .semibold),
        fontCaption: .system(size: 12, weight: .regular),
        fontCaptionEmphasis: .system(size: 12, weight: .semibold),
        textPrimary: .white,
        textSecondary: .white.opacity(0.68),
        textTertiary: .white.opacity(0.58),
        bgRaised: Color(red: 0.098, green: 0.098, blue: 0.106),
        bgOverlay: Color(red: 0.180, green: 0.180, blue: 0.188),
        separator: .white.opacity(0.16),
        accent: Color(red: 1.00, green: 0.42, blue: 0.10),
        accentOn: Color(red: 0.10, green: 0.04, blue: 0.00),
        accentMuted: Color(red: 1.00, green: 0.42, blue: 0.10).opacity(0.20),
        warning: Color(red: 1.00, green: 0.69, blue: 0.13),
        warningOn: Color(red: 0.10, green: 0.06, blue: 0.00),
        destructive: Color(red: 1.00, green: 0.31, blue: 0.27),
        destructiveOn: Color(red: 0.10, green: 0.00, blue: 0.00),
        success: Color(red: 0.20, green: 0.78, blue: 0.35),
        successOn: Color(red: 0.00, green: 0.10, blue: 0.02),
        rowArtworkSize: 32,
        artistCircleDiameter: 84,
        iconStrokeWidth: 1.6
    )

    static var decksConsole: SCContentStyle {
        var style = SCContentStyle.mac
        style.cornerControl = 0
        style.cornerCard = 2
        style.cornerPanel = 4
        style.cornerHero = 4
        style.spaceTight = 4
        style.spaceSnug = 6
        style.spaceBase = 10
        style.textPrimary = .white
        style.textSecondary = .white.opacity(0.70)
        style.textTertiary = .white.opacity(0.58)
        style.bgRaised = Color(white: 0.10)
        style.bgOverlay = Color(white: 0.16)
        style.separator = .white.opacity(0.22)
        style.rowArtworkSize = 32
        style.iconStrokeWidth = 2.0
        return style
    }
}

enum SCContentMotion {
    static let press = Animation.spring(response: 0.30, dampingFraction: 0.82)
    static let focus = Animation.spring(response: 0.32, dampingFraction: 0.70)
    static let settle = Animation.spring(response: 0.50, dampingFraction: 0.80)
    static let ambient = Animation.easeInOut(duration: 0.6)
    static let gentle = Animation.easeInOut(duration: 0.25)
}

struct SearchVibe: Identifiable, Sendable {
    let id: String
    let title: String
    let query: String
    let symbol: String
    let accentHue: Double
    let secondaryHue: Double
    let phoneHeight: CGFloat

    var accent: Color {
        Color(hue: accentHue, saturation: 0.82, brightness: 0.94)
    }

    var secondary: Color {
        Color(hue: secondaryHue, saturation: 0.68, brightness: 0.90)
    }

    static let all: [SearchVibe] = [
        .init(id: "hip-hop", title: "Hip Hop & Rap", query: "Hip Hop Rap", symbol: "music.microphone", accentHue: 0.78, secondaryHue: 0.69, phoneHeight: 184),
        .init(id: "electronic", title: "Electronic", query: "Electronic", symbol: "slider.horizontal.3", accentHue: 0.94, secondaryHue: 0.79, phoneHeight: 276),
        .init(id: "pop", title: "Pop", query: "Pop", symbol: "star.fill", accentHue: 0.13, secondaryHue: 0.07, phoneHeight: 252),
        .init(id: "rnb", title: "R&B", query: "R&B", symbol: "music.note", accentHue: 0.51, secondaryHue: 0.55, phoneHeight: 112),
        .init(id: "chill", title: "Chill", query: "Chill", symbol: "cloud.moon.fill", accentHue: 0.52, secondaryHue: 0.47, phoneHeight: 112),
        .init(id: "party", title: "Party", query: "Party", symbol: "party.popper.fill", accentHue: 0.06, secondaryHue: 0.96, phoneHeight: 212),
        .init(id: "workout", title: "Workout", query: "Workout", symbol: "figure.run", accentHue: 0.36, secondaryHue: 0.45, phoneHeight: 184),
        .init(id: "techno", title: "Techno", query: "Techno", symbol: "waveform.path.ecg", accentHue: 0.92, secondaryHue: 0.79, phoneHeight: 184),
    ]
}

struct SearchVibeArtwork: View {
    let vibe: SearchVibe
    var cornerRadius: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    private var tint: SoundingArtRGB { SoundingArtRGB.genreTint(vibe.id) }

    private var motif: SoundingArtMotif? {
        let motifs: [SoundingArtMotif] = [.jack, .equaliser, .rings, .cone, .waves, .vinyl, .crossfader]
        return SearchVibe.all.firstIndex { $0.id == vibe.id }.map { motifs[$0 % motifs.count] }
    }

    private var ground: Color {
        Color(cgColor: SoundingArtTheme.ground(colorScheme == .dark ? .dark : .light, tint: tint).cgColor)
    }

    var body: some View {
        SoundingArtworkView(seed: GeneratedArtworkIdentity.hash("vibe:" + vibe.id), subject: .genre, tint: tint, motif: motif)
            #if os(tvOS)
            .overlay(alignment: .topLeading) {
                LinearGradient(
                    stops: [.init(color: ground, location: 0), .init(color: ground.opacity(0.85), location: 0.45), .init(color: ground.opacity(0), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 64)
                .frame(maxWidth: .infinity)
            }
            #endif
            .overlay(alignment: .topLeading) { titleOverlay }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private extension SearchVibeArtwork {
    @ViewBuilder
    var titleOverlay: some View {
        #if os(tvOS)
        Text(vibe.title)
            .font(.headline.weight(.bold))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.86))
            .lineLimit(2)
            .padding(14)
        #else
        Text(vibe.title)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
        #endif
    }
}
