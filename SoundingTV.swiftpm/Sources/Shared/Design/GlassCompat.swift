import SwiftUI

struct SoundingGlass {
    var isClear = false
    var tintColor: Color?
    var isInteractive = false

    static let regular = SoundingGlass()
    static let clear = SoundingGlass(isClear: true)

    func tint(_ color: Color?) -> SoundingGlass {
        var copy = self
        copy.tintColor = color
        return copy
    }

    func interactive(_ isEnabled: Bool = true) -> SoundingGlass {
        var copy = self
        copy.isInteractive = isEnabled
        return copy
    }

    @available(iOS 26, macOS 26, tvOS 26, watchOS 26, *)
    var glass: Glass {
        (isClear ? Glass.clear : Glass.regular).tint(tintColor).interactive(isInteractive)
    }
}

extension View {
    @ViewBuilder
    func soundingGlass<S: Shape>(_ glass: SoundingGlass = .regular, in shape: S) -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, *) {
            glassEffect(glass.glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(glass.isClear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                    if let tint = glass.tintColor {
                        shape.fill(tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func soundingGlass(_ glass: SoundingGlass = .regular) -> some View {
        soundingGlass(glass, in: Capsule())
    }

    @ViewBuilder
    func soundingGlassButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func soundingGlassProminentButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func soundingGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

struct SoundingGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
