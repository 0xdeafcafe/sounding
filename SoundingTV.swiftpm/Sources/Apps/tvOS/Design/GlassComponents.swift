import SwiftUI

extension View {
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    func liquidGlass<S: Shape, ID: Hashable & Sendable>(
        in shape: S,
        id: ID,
        namespace: Namespace.ID,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
            .glassEffectID(id, in: namespace)
    }
}

private struct LiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.scGlassFill, in: shape)
                .background(tint ?? .clear, in: shape)
        } else {
            let effect: Glass = {
                var g: Glass = .regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            content.glassEffect(effect, in: shape)
        }
    }
}

struct TVPaging {
    var isLoading: Bool
    var failed: Bool
    var isPaused: Bool
    var loadMore: () -> Void
    var retry: () -> Void

    @MainActor
    init?<Item: Identifiable>(_ pager: Paginator<Item>) {
        guard pager.hasMore || pager.isLoadingMore || pager.didFailLoadingMore else { return nil }
        isLoading = pager.isLoadingMore
        failed = pager.didFailLoadingMore
        isPaused = pager.isPaused
        loadMore = { pager.requestMore() }
        retry = { Task { await pager.retry() } }
    }

    init(
        isLoading: Bool,
        failed: Bool,
        isPaused: Bool,
        loadMore: @escaping () -> Void,
        retry: @escaping () -> Void
    ) {
        self.isLoading = isLoading
        self.failed = failed
        self.isPaused = isPaused
        self.loadMore = loadMore
        self.retry = retry
    }

    static func combining(_ parts: [TVPaging?]) -> TVPaging? {
        let active = parts.compactMap { $0 }
        guard !active.isEmpty else { return nil }
        return TVPaging(
            isLoading: active.contains { $0.isLoading },
            failed: active.contains { $0.failed },
            isPaused: active.contains { $0.isPaused },
            loadMore: { active.forEach { $0.loadMore() } },
            retry: { active.filter(\.failed).forEach { $0.retry() } }
        )
    }
}

struct TVShelfFooter: View {
    let paging: TVPaging
    var height: CGFloat = 240

    var body: some View {
        TVPagedFooter(paging: paging)
            .frame(width: 360, height: height)
    }
}

struct TVPagedFooter: View {
    let paging: TVPaging

    var body: some View {
        PagedFooter(
            isLoading: paging.isLoading,
            failed: paging.failed,
            isPaused: paging.isPaused,
            retry: paging.retry,
            reachedEnd: paging.loadMore
        )
        .font(.tvCallout)
        .buttonStyle(TVRetryButtonStyle())
        .focusEffectDisabled()
    }
}

private struct TVRetryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(configuration: configuration)
    }

    private struct FocusedLabel: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.tvCalloutEmph)
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .padding(.horizontal, Space.base)
                .padding(.vertical, Space.snug)
                .background(
                    isFocused ? Color.scChromeFocus : Color.white.opacity(0.10),
                    in: Capsule(style: .continuous)
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

struct LoadingMoreRow: View {
    var body: some View {
        HStack(spacing: Space.snug) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Loading more…")
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
        }
        .padding(.vertical, Space.base)
        .padding(.horizontal, Space.roomy)
        .focusable(false)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPanel: View {
    enum Kind {
        case loading
        case empty
        case error
    }

    let kind: Kind
    var icon: String = "music.note"
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var minHeight: CGFloat = 520
    var actionFocus: FocusState<Bool>.Binding? = nil

    @FocusState private var panelFocused: Bool
    @FocusState private var buttonFocused: Bool

    private var hasAction: Bool { actionTitle != nil && action != nil }

    private var focusBinding: FocusState<Bool>.Binding { actionFocus ?? $buttonFocused }

    var body: some View {
        if hasAction {
            panel
                .accessibilityElement(children: .contain)
        } else {
            panel
                .focusable()
                .focused($panelFocused)
                .focusEffectDisabled()
                .accessibilityElement(children: .combine)
        }
    }

    private var panel: some View {
        Group {
            switch kind {
            case .loading:
                VStack(spacing: Space.snug) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            case .empty, .error:
                ContentUnavailableView {
                    Label(title, systemImage: kind == .error ? "exclamationmark.triangle" : icon)
                } description: {
                    if let message {
                        Text(message)
                    }
                } actions: {
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .focused(focusBinding)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

struct TVGlassPillStyle: ButtonStyle {
    var isProminent = false
    var diameter: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isProminent: isProminent, diameter: diameter)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isProminent: Bool
        let diameter: CGFloat?
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.collectionAccent) private var accent

        private var restingTint: Color? {
            guard isProminent else { return nil }
            return accent?.wash(for: .dark) ?? Color.white.opacity(0.22)
        }

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .background {
                    Capsule()
                        .fill(Color.scChromeFocus)
                        .opacity(isFocused ? 1 : 0)
                }
                .liquidGlass(in: Capsule(), tint: restingTint)
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct TVGlassPillLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.tvBodyEmph)
        .lineLimit(1)
        .padding(.horizontal, 44)
        .padding(.vertical, 18)
    }
}
