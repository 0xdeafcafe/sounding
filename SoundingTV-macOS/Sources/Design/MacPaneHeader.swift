import SwiftUI

struct MacPaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let showsInlineActions: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsInlineActions = true
        self.trailing = trailing
    }

    @ViewBuilder
    var body: some View {
        if showsInlineActions {
            HStack(spacing: SCContentStyle.mac.spaceSnug) {
                Spacer(minLength: 0)
                trailing()
                    .controlSize(.small)
            }
            .padding(.horizontal, SCContentStyle.mac.spaceGutter)
            .padding(.top, SCContentStyle.mac.spaceTight)
            .padding(.bottom, SCContentStyle.mac.spaceHair)
            .frame(minHeight: 44)
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
        } else {
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
                .navigationTitle(title)
                .navigationSubtitle(subtitle ?? "")
        }
    }
}

extension MacPaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.showsInlineActions = false
        self.trailing = { EmptyView() }
    }
}

/// A deliberately quiet title for dense, table-like panes.  Music uses the
/// toolbar for this kind of context rather than spending a full content band
/// on a second large heading.
struct MacToolbarTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

struct MacHoverLift: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? 0.04 : 0)
            .saturation(isHovering ? 1.04 : 1.0)
            .animation(SCContentMotion.focus, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct MacHoverRowHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .animation(SCContentMotion.focus, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func macHoverLift() -> some View { modifier(MacHoverLift()) }

    func macHoverRowHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(MacHoverRowHighlight(cornerRadius: cornerRadius))
    }
}
