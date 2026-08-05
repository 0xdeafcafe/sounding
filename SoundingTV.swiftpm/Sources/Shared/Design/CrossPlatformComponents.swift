import SwiftUI

struct Eyebrow: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            #if os(tvOS)
            .font(.tvEyebrow)
            #else
            .font(.caption.bold())
            #endif
            .foregroundStyle(tint)
            .kerning(2.4)
    }
}

struct GlassChip<ID: Hashable & Sendable>: View {
    let icon: String
    let text: String
    let id: ID
    let namespace: Namespace.ID
    var tint: Color? = nil
    var animatesIcon: Bool = false
    var interactive: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if animatesIcon {
                Image(systemName: icon)
                    .symbolEffect(.variableColor.iterative)
            } else {
                Image(systemName: icon)
            }
            Text(text)
                #if os(tvOS)
                .font(.tvCaptionEmph)
                #else
                .font(.caption.bold())
                #endif
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        #if os(tvOS)
        .liquidGlass(in: Capsule(), id: id, namespace: namespace, tint: tint, interactive: interactive)
        #else
        .background(tint ?? Color.white.opacity(0.15), in: Capsule())
        #endif
    }
}
