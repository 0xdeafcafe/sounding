import SwiftUI

enum NPPanelKind: String, CaseIterable, Hashable {
    case upNext
    case comments
    case tracklist
    case output
    case more
    case cues
    case sleepTimer

    static let tabs: [NPPanelKind] = [.upNext, .comments, .tracklist]

    var title: String {
        switch self {
        case .upNext: return "Up Next"
        case .comments: return "Comments"
        case .tracklist: return "Tracklist"
        case .output: return "Output"
        case .more: return "More"
        case .cues: return "Cue Points"
        case .sleepTimer: return "Sleep Timer"
        }
    }

    var isTab: Bool { Self.tabs.contains(self) }
}

enum NPFocus: Hashable {
    case prev
    case play
    case next
    case like
    case comments
    case upNext
    case lyrics
    case details
    case tracklist
    case output
    case more
    case wave
    case tab(NPPanelKind)
    case row(String)
    case pill(String)
    case idle
}

enum NPInkLevel {
    case primary
    case secondary
    case tertiary
}

struct NPInk: ViewModifier {
    let level: NPInkLevel
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        if isFocused {
            switch level {
            case .primary: return Color.scChromeFocusOn
            case .secondary: return Color.black.opacity(0.62)
            case .tertiary: return Color.black.opacity(0.46)
            }
        }
        switch level {
        case .primary: return .white
        case .secondary: return Color.white.opacity(0.66)
        case .tertiary: return Color.white.opacity(0.44)
        }
    }
}

extension View {
    func npInk(_ level: NPInkLevel = .primary) -> some View {
        modifier(NPInk(level: level))
    }
}

private struct NPFocusSheen<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false)
    }
}

struct NPCircleStyle: ButtonStyle {
    let diameter: CGFloat
    let label: String
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, diameter: diameter, label: label, isOn: isOn)
    }

    private struct Styled: View {
        let configuration: Configuration
        let diameter: CGFloat
        let label: String
        let isOn: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.white)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle()
                        .fill(Color.scChromeFocus)
                        .opacity(isFocused ? 1 : 0)
                }
                .overlay { if isFocused { NPFocusSheen(shape: Circle()) } }
                .liquidGlass(in: Circle(), tint: isOn ? Color.white.opacity(0.3) : nil)
                .contentShape(Circle())
                .overlay(alignment: .top) {
                    if !label.isEmpty {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                            .fixedSize()
                            .offset(y: diameter + 18)
                            .opacity(isFocused ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .scaleEffect(isFocused ? 1.1 : 1)
                .offset(y: isFocused ? -3 : 0)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 22, y: 12)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct NPRowStyle: ButtonStyle {
    var corner: CGFloat = 22
    var scale: CGFloat = 1.03

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, corner: corner, scale: scale)
    }

    private struct Styled: View {
        let configuration: Configuration
        let corner: CGFloat
        let scale: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            configuration.label
                .background { shape.fill(isFocused ? Color.scChromeFocus : Color.clear) }
                .contentShape(shape)
                .scaleEffect(isFocused ? scale : 1)
                .shadow(color: isFocused ? Color.black.opacity(0.45) : .clear, radius: 22, y: 12)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct NPPillStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSelected: isSelected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    Capsule()
                        .fill(Color.scChromeFocus)
                        .opacity(isFocused ? 1 : 0)
                }
                .liquidGlass(in: Capsule(), tint: isSelected ? Color.white.opacity(0.3) : nil)
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 16, y: 8)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct NPIconButton: View {
    let symbol: String
    let label: String
    let id: NPFocus
    var focus: FocusState<NPFocus?>.Binding
    var diameter: CGFloat = 76
    var iconSize: CGFloat = 34
    var isOn = false
    var accessibilityTitle: String?
    var accessibilityValue = ""
    var identifier: String?
    var swapsSymbol = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didActivate = false

    var body: some View {
        Button {
            didActivate.toggle()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .contentTransition(swapsSymbol && !reduceMotion ? .symbolEffect(.replace) : .identity)
                .symbolEffect(.bounce, value: reduceMotion ? false : didActivate)
        }
        .buttonStyle(NPCircleStyle(diameter: diameter, label: label, isOn: isOn))
        .focused(focus, equals: id)
        .accessibilityLabel(accessibilityTitle ?? label)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(identifier ?? "")
    }
}

enum NPButtonSlots {
    @MainActor
    static func showsTracklist(for track: Track?, store: SetlistIntelligenceStore) -> Bool {
        guard let track else { return false }
        guard track.supportsSoundCloudActions else { return true }
        return !(store.tracklist(for: track.id)?.isEmpty ?? true)
    }
}
