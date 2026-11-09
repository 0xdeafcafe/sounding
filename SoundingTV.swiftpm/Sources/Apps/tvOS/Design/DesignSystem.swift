import SwiftUI
import UIKit

extension Color {

    static let scBgBase = Color.black
    static let scBgRaised = Color(white: 0.192)
    static let scBgOverlay = Color(white: 0.255)
    static let scSeparator = Color.white.opacity(0.14)

    static let scTextPrimary = Color.white
    static let scTextSecondary = contrastAware(standard: 0.68, increased: 0.82)
    static let scTextTertiary = contrastAware(standard: 0.46, increased: 0.66)

    static let scGlassFill = Color(white: 0.16)

    static func contrastAware(standard: CGFloat, increased: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(white: 1, alpha: traits.accessibilityContrast == .high ? increased : standard)
        })
    }

    static func whiteInk(_ opacity: CGFloat, increased: CGFloat? = nil) -> Color {
        contrastAware(standard: opacity, increased: increased ?? min(1, opacity + 0.2))
    }


    static let scDestructive = Color(red: 1.00, green: 0.31, blue: 0.27)
    static let scDestructiveOn = Color(red: 0.10, green: 0.00, blue: 0.00)

    static let scSuccess = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let scSuccessOn = Color(red: 0.00, green: 0.10, blue: 0.02)

    static let scWarning = Color(red: 1.00, green: 0.69, blue: 0.13)
    static let scWarningOn = Color(red: 0.10, green: 0.06, blue: 0.00)

    static let scFocusShadow = Color.black.opacity(0.45)

    static let scChromeFocus = Color(white: 0.94)
    static let scChromeFocusOn = Color(white: 0.05)

    static let scBackground = scBgBase
    static let scError = scDestructive

}

extension ShapeStyle where Self == Color {
    static func whiteInk(_ opacity: CGFloat, increased: CGFloat? = nil) -> Color {
        Color.whiteInk(opacity, increased: increased)
    }
}

extension Font {
    static let tvDisplay     = Font.system(size: 76, weight: .black,    design: .default)
    static let tvLargeTitle  = Font.system(size: 58, weight: .heavy,    design: .default)
    static let tvTitle       = Font.system(size: 48, weight: .heavy,    design: .default)
    static let tvHeadline    = Font.system(size: 38, weight: .bold,     design: .default)
    static let tvSection     = Font.system(size: 32, weight: .heavy,    design: .default)
    static let tvSubheadline = Font.system(size: 31, weight: .semibold, design: .default)
    static let tvBody        = Font.system(size: 29, weight: .regular,  design: .default)
    static let tvBodyEmph    = Font.system(size: 29, weight: .semibold, design: .default)
    static let tvCallout     = Font.system(size: 28, weight: .regular,  design: .default)
    static let tvCalloutEmph = Font.system(size: 28, weight: .semibold, design: .default)
    static let tvCaption     = Font.system(size: 28, weight: .regular,  design: .default)
    static let tvCaptionEmph = Font.system(size: 28, weight: .semibold, design: .default)
    static let tvEyebrow     = Font.system(size: 28, weight: .heavy,    design: .default)
    static let tvMini        = Font.system(size: 28, weight: .medium,   design: .default)
}

enum Space {
    static let hair: CGFloat = 4
    static let tight: CGFloat = 8
    static let snug: CGFloat = 16
    static let base: CGFloat = 24
    static let roomy: CGFloat = 32
    static let section: CGFloat = 48
    static let gutter: CGFloat = 40
    static let page: CGFloat = 80
}

enum Spacing {
    static let xs:   CGFloat = Space.tight
    static let sm:   CGFloat = 12
    static let md:   CGFloat = Space.snug
    static let lg:   CGFloat = Space.base
    static let xl:   CGFloat = Space.roomy
    static let xxl:  CGFloat = Space.section
    static let xxxl: CGFloat = 64
    static let screen: CGFloat = Space.page
}

enum Corner {
    static let thumb: CGFloat = 9
    static let control: CGFloat = 14
    static let card: CGFloat = 18
    static let panel: CGFloat = 32
    static let hero: CGFloat = 44
}

enum CornerRadius {
    static let sm:  CGFloat = Corner.thumb
    static let md:  CGFloat = Corner.control
    static let lg:  CGFloat = Corner.card
    static let xl:  CGFloat = Corner.panel
    static let xxl: CGFloat = Corner.hero
}

enum Motion {
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let focus = Animation.spring(response: 0.34, dampingFraction: 0.62)
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.72)
    static let ambient = Animation.easeInOut(duration: 0.55)
}

extension Animation {
    static let quickSpring = Motion.press
    static let glassMorph = Motion.settle
    static let smoothEase = Animation.easeInOut(duration: 0.30)
}

enum Control {
    static let circle: CGFloat = 64
    static let circleIcon: CGFloat = 28
}

enum Focus {

    enum SizeClass: Equatable, Sendable {
        case tile
        case card
        case hero

        var scale: CGFloat {
            switch self {
            case .tile: return 1.15
            case .card: return 1.08
            case .hero: return 1.05
            }
        }

        static func measured(_ size: CGSize) -> SizeClass {
            let longest = max(size.width, size.height)
            if longest <= 460 { return .tile }
            if longest <= 700 { return .card }
            return .hero
        }
    }

    static let scale: CGFloat = SizeClass.card.scale

    static let shadowRadius: CGFloat = 24
    static let shadowY: CGFloat = 12
}

private struct SCFocusEffect<S: InsettableShape>: ViewModifier {
    let isFocused: Bool
    let shape: S
    let reduceMotion: Bool
    let sizeClass: Focus.SizeClass?

    @State private var measured: Focus.SizeClass = .card

    private var scale: CGFloat { (sizeClass ?? measured).scale }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newValue in
                measured = Focus.SizeClass.measured(newValue)
            }
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isFocused ? scale : 1.0)
            .shadow(
                color: isFocused ? .scFocusShadow : .clear,
                radius: isFocused ? Focus.shadowRadius : 0,
                y: isFocused ? Focus.shadowY : 0
            )
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
    }
}

extension View {
    func scFocus<S: InsettableShape>(
        _ isFocused: Bool,
        in shape: S,
        reduceMotion: Bool = false,
        sizeClass: Focus.SizeClass? = nil
    ) -> some View {
        modifier(SCFocusEffect(
            isFocused: isFocused,
            shape: shape,
            reduceMotion: reduceMotion,
            sizeClass: sizeClass
        ))
    }

    func scFocus(
        _ isFocused: Bool,
        cornerRadius: CGFloat = Corner.card,
        reduceMotion: Bool = false,
        sizeClass: Focus.SizeClass? = nil
    ) -> some View {
        scFocus(
            isFocused,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            reduceMotion: reduceMotion,
            sizeClass: sizeClass
        )
    }

    @ViewBuilder
    func focusSection(when condition: Bool) -> some View {
        if condition { self.focusSection() } else { self }
    }
}

struct SCCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Corner.control
    var sizeClass: Focus.SizeClass?

    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(
            configuration: configuration,
            cornerRadius: cornerRadius,
            sizeClass: sizeClass
        )
    }

    private struct FocusedLabel: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let sizeClass: Focus.SizeClass?
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scFocus(
                    isFocused,
                    cornerRadius: cornerRadius,
                    reduceMotion: reduceMotion,
                    sizeClass: sizeClass
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

struct SCShapeButtonStyle<S: InsettableShape>: ButtonStyle {
    let shape: S
    var sizeClass: Focus.SizeClass?

    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(configuration: configuration, shape: shape, sizeClass: sizeClass)
    }

    private struct FocusedLabel: View {
        let configuration: Configuration
        let shape: S
        let sizeClass: Focus.SizeClass?
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scFocus(isFocused, in: shape, reduceMotion: reduceMotion, sizeClass: sizeClass)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

struct SCPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    @ViewBuilder
    func scMotion<V: Equatable>(_ animation: Animation?, reduceMotion: Bool, value: V) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
