import SwiftUI

struct Eyebrow: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            #if os(tvOS)
            .font(.tvEyebrow)
            #else
            .font(.caption.bold())
            #endif
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    @ViewBuilder
    func remoteFocusTarget(_ isTarget: Bool = true) -> some View {
        #if os(tvOS)
        focusable(isTarget).focusEffectDisabled()
        #else
        self
        #endif
    }
}
