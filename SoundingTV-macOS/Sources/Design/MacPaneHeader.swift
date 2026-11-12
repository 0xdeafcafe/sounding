import SwiftUI

struct MacHoverLift: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? 0.04 : 0)
            .saturation(isHovering ? 1.04 : 1.0)
            .animation(reduceMotion ? nil : SCContentMotion.focus, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct MacHoverRowHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .animation(reduceMotion ? nil : SCContentMotion.focus, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct MacAdaptiveGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.2), lineWidth: 1))
        } else if let tint {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

struct MacKeyboardActivatable: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable(interactions: .activate)
            .onKeyPress(.return) {
                action()
                return .handled
            }
            .onKeyPress(.space) {
                action()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

extension View {
    func macHoverLift() -> some View { modifier(MacHoverLift()) }

    func macHoverRowHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(MacHoverRowHighlight(cornerRadius: cornerRadius))
    }

    func macAdaptiveGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(MacAdaptiveGlass(shape: shape, tint: tint))
    }

    func macKeyboardActivatable(_ action: @escaping () -> Void) -> some View {
        modifier(MacKeyboardActivatable(action: action))
    }
}

enum MacRowSelectionStyle {
    case sidebar
    case content

    func fill(_ scheme: ColorScheme) -> Color {
        switch self {
        case .sidebar: return Color.primary.opacity(scheme == .dark ? 0.14 : 0.08)
        case .content: return .scAccent
        }
    }

    var ink: Color? {
        switch self {
        case .sidebar: return nil
        case .content: return .scAccentOn
        }
    }

    var outerInset: CGFloat {
        switch self {
        case .sidebar: return 10
        case .content: return 6
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .sidebar: return 3
        case .content: return 4
        }
    }
}

extension EnvironmentValues {
    @Entry var macRowSelectionInk: Color?
}

struct MacSidebarRowChrome: ViewModifier {
    var style: MacRowSelectionStyle = .sidebar

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 1, leading: style.outerInset, bottom: 1, trailing: style.outerInset))
    }
}

struct MacSelectableRow<Value: Hashable>: ViewModifier {
    let value: Value
    @Binding var selection: Value?
    let style: MacRowSelectionStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isSelected = selection == value
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button {
            selection = value
        } label: {
            content
                .environment(\.macRowSelectionInk, isSelected ? style.ink : nil)
                .foregroundStyle(isSelected ? (style.ink ?? Color.primary) : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, style.verticalPadding)
                .background(shape.fill(isSelected ? style.fill(colorScheme) : Color.clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: style.outerInset, bottom: 1, trailing: style.outerInset))
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MacListKeyboardSelection<Value: Hashable>: ViewModifier {
    let ids: [Value]
    @Binding var selection: Value?
    var onSubmit: ((Value) -> Void)?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            .onMoveCommand { direction in
                guard !ids.isEmpty else { return }
                let current = selection.flatMap { ids.firstIndex(of: $0) }
                switch direction {
                case .down:
                    selection = ids[min((current ?? -1) + 1, ids.count - 1)]
                case .up:
                    selection = ids[max((current ?? ids.count) - 1, 0)]
                default:
                    break
                }
            }
            .onKeyPress(.return) {
                guard let onSubmit, let selection else { return .ignored }
                onSubmit(selection)
                return .handled
            }
    }
}

struct MacSidebarLabel: View {
    let title: String
    let systemImage: String
    var badge = 0
    @Environment(\.macRowSelectionInk) private var selectionInk

    init(_ title: String, systemImage: String, badge: Int = 0) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .symbolVariant(.none)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selectionInk ?? Color.scAccent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if badge > 0 {
                Text(badge, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(MacSecondaryStyle())
            }
        }
    }
}

extension View {
    func macSelectableRow<Value: Hashable>(
        _ value: Value,
        selection: Binding<Value?>,
        style: MacRowSelectionStyle = .sidebar
    ) -> some View {
        modifier(MacSelectableRow(value: value, selection: selection, style: style))
    }

    func macSidebarRowChrome(style: MacRowSelectionStyle = .sidebar) -> some View {
        modifier(MacSidebarRowChrome(style: style))
    }

    func macListKeyboardSelection<Value: Hashable>(
        ids: [Value],
        selection: Binding<Value?>,
        onSubmit: ((Value) -> Void)? = nil
    ) -> some View {
        modifier(MacListKeyboardSelection(ids: ids, selection: selection, onSubmit: onSubmit))
    }
}

extension ColorSchemeContrast {
    func macInk(_ base: Double, increased: Double) -> Color {
        .white.opacity(self == .increased ? increased : base)
    }
}

struct MacLoadingView: View {
    var title: LocalizedStringKey?

    init(_ title: LocalizedStringKey? = nil) {
        self.title = title
    }

    var body: some View {
        Group {
            if let title {
                ProgressView(title)
            } else {
                ProgressView()
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MacViewportScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    var extendsUnderToolbar = false
    var hidesContentUnderToolbar = true
    @ViewBuilder var content: () -> Content

    @State private var viewport: CGFloat = 0
    @State private var toolbarInset: CGFloat = 0
    @State private var frameTop: CGFloat = 0
    #if DEBUG
    @State private var debugPosition = ScrollPosition()
    @State private var debugContentInset: CGFloat = 0
    #endif

    var body: some View {
        scroller
        #if DEBUG
            .scrollPosition($debugPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in debugContentInset = inset }
            .task {
                guard let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SCROLL"], let y = Double(raw), y > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
                debugPosition.scrollTo(y: y - debugContentInset)
            }
        #endif
    }

    private var scroller: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content()
                .frame(minHeight: viewport, alignment: .top)
                .environment(\.macToolbarInset, toolbarInset)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
        } action: { _, newValue in
            viewport = newValue
        }
        .ignoresSafeArea(.container, edges: extendsUnderToolbar ? .top : [])
        .mask(alignment: .top) {
            if hidesContentUnderToolbar, toolbarInset > 0 {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.edgeFade)
                    Color.black
                }
                .padding(.top, max(0, toolbarInset - frameTop) - Self.edgeFade)
            } else {
                Color.black
            }
        }
        .background {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarInset = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { frameTop = $0 }
        }
    }

    private static var edgeFade: CGFloat { 10 }
}

private struct MacToolbarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var macToolbarInset: CGFloat {
        get { self[MacToolbarInsetKey.self] }
        set { self[MacToolbarInsetKey.self] = newValue }
    }
}

private struct MacFadesUnderToolbar: ViewModifier {
    var distance: CGFloat
    var extra: CGFloat
    @Environment(\.macToolbarInset) private var toolbarInset

    func body(content: Content) -> some View {
        content.visualEffect { [toolbarInset, distance, extra] effect, proxy in
            let top = proxy.frame(in: .global).minY - toolbarInset - extra
            return effect.opacity(Double(min(1, max(0, top / distance))))
        }
    }
}

extension View {
    func macFadesUnderToolbar(over distance: CGFloat = 28, below extra: CGFloat = 0) -> some View {
        modifier(MacFadesUnderToolbar(distance: distance, extra: extra))
    }
}

extension View {
    func macFillsPane() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum MacCardArtworkShape {
    case rounded
    case circle
}

private struct MacCardHover<Menu: View>: ViewModifier {
    let shape: MacCardArtworkShape
    let artworkSide: CGFloat?
    let playLabel: String
    let play: (() -> Void)?
    let artworkURL: URL?
    let prewarm: (() -> Void)?
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @State private var coverAnchor = MacNowPlayingView.WeakViewBox()
    @State private var isForced = false
    @FocusState private var cardFocused: Bool
    @FocusState private var playFocused: Bool
    @FocusState private var moreFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsControls: Bool {
        isHovering || isForced || cardFocused || playFocused || moreFocused
    }

    private var artworkShape: AnyShape {
        switch shape {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: SCContentStyle.mac.artworkCorner, style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }

    func body(content: Content) -> some View {
        content
            .focused($cardFocused)
            .background(alignment: .top) { shadowLayer }
            .background(alignment: .top) {
                artworkFrame(Color.clear.background(MacViewAnchor { coverAnchor.view = $0 }))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) { controls }
            .scaleEffect(showsControls && !reduceMotion ? 1.02 : 1)
            .animation(reduceMotion ? nil : SCContentMotion.focus, value: showsControls)
            .onHover { hovering in
                isHovering = hovering
                if hovering { prewarm?() }
            }
            .contextMenu { menu() }
            .onAppear { claimDebugHover() }
    }

    @ViewBuilder
    private func artworkFrame<V: View>(_ view: V) -> some View {
        if let artworkSide {
            view.frame(width: artworkSide, height: artworkSide)
        } else {
            view.aspectRatio(1, contentMode: .fit)
        }
    }

    private var shadowLayer: some View {
        artworkFrame(artworkShape.fill(Color.black))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 6)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var controls: some View {
        artworkFrame(
            ZStack(alignment: .bottom) {
                artworkShape
                    .fill(Color.black.opacity(0.28))
                    .allowsHitTesting(false)
                HStack(alignment: .bottom) {
                    if let play {
                        Button {
                            startFromCover(play)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .macAdaptiveGlass(in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focused($playFocused)
                        .help(playLabel)
                        .accessibilityLabel(playLabel)
                    }
                    Spacer(minLength: 0)
                    SwiftUI.Menu {
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .macAdaptiveGlass(in: Circle())
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .focused($moreFocused)
                    .fixedSize()
                    .help("More")
                    .accessibilityLabel("More")
                }
                .padding(shape == .circle ? 18 : 8)
            }
            .clipShape(artworkShape)
        )
        .opacity(showsControls ? 1 : 0)
        .allowsHitTesting(showsControls)
    }

    private func startFromCover(_ play: () -> Void) {
        let image = artworkURL.flatMap { ArtworkCache.shared.bestCachedImage(for: $0, variant: .standard) }
        MacNowPlayingPresentation.shared.prepareCoverMorph(from: coverAnchor.view, image: image)
        NowPlayingReveal.shared.revealWhenStarted(from: "mac.cover")
        play()
    }

    private func claimDebugHover() {
        #if DEBUG
        isForced = MacCardHoverDebug.forcesAll
        #endif
    }
}

#if DEBUG
private enum MacCardHoverDebug {
    static let forcesAll = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_FORCE_HOVER"] == "1"
}
#endif

extension View {
    func macCardHover<Menu: View>(
        shape: MacCardArtworkShape = .rounded,
        artworkSide: CGFloat? = nil,
        playLabel: String = "Play",
        artworkURL: URL? = nil,
        prewarm: (() -> Void)? = nil,
        play: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> Menu
    ) -> some View {
        modifier(MacCardHover(
            shape: shape,
            artworkSide: artworkSide,
            playLabel: playLabel,
            play: play,
            artworkURL: artworkURL,
            prewarm: prewarm,
            menu: menu
        ))
    }
}

private struct MacScrolledAwayReader: ViewModifier {
    @Binding var isScrolledAway: Bool
    @Environment(\.macToolbarInset) private var toolbarInset

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Bool.self) { [toolbarInset] proxy in
            let frame = proxy.frame(in: .global)
            return toolbarInset > 0 && frame.height > 0 && frame.maxY <= toolbarInset
        } action: { isScrolledAway = $0 }
    }
}

extension View {
    func macReportsScrolledAway(_ isScrolledAway: Binding<Bool>) -> some View {
        modifier(MacScrolledAwayReader(isScrolledAway: isScrolledAway))
    }
}
