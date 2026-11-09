import SwiftUI

struct NPProgressArea<Waveform: View>: View {
    let isIdle: Bool
    let accent: Color
    var focus: FocusState<NPFocus?>.Binding
    let incoming: (AutoMixLiveState) -> Track?
    let onMixNow: () -> Void
    let onExtend: () -> Void
    @ViewBuilder var waveform: () -> Waveform

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = isIdle ? nil : AutoMixLive.shared.state
        let showsDecks = state.map(NPAutoMixRow.showsDecks) ?? false
        VStack(alignment: .leading, spacing: 0) {
            if let state {
                NPAutoMixRow(
                    state: state,
                    accent: accent,
                    incoming: incoming(state),
                    focus: focus,
                    onMixNow: onMixNow,
                    onExtend: onExtend
                )
                .padding(.bottom, showsDecks ? 0 : 28)
            } else if !isIdle, AutoMixFeedbackStore.shared.pending != nil {
                AutoMixRatingView()
                    .padding(.bottom, 28)
            }
            if !showsDecks {
                waveform()
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : Motion.settle, value: showsDecks)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : Motion.settle, value: state == nil)
    }
}

struct NPAutoMixRow: View {
    let state: AutoMixLiveState
    let accent: Color
    var incoming: Track?
    var focus: FocusState<NPFocus?>.Binding
    let onMixNow: () -> Void
    let onExtend: () -> Void

    static func showsDecks(_ state: AutoMixLiveState) -> Bool {
        state.stage == .mixing && state.outgoing != nil
    }

    private var tint: Color { accent.mix(with: .white, by: 0.35) }

    var body: some View {
        if Self.showsDecks(state) {
            AutoMixDecksView(state: state, scale: .tv, tint: tint)
                .foregroundStyle(.white)
                .transition(.opacity)
        } else {
            GlassEffectContainer(spacing: 12) {
                HStack(alignment: .center, spacing: 20) {
                    capsule
                    if state.stage == .upcoming {
                        pill("Mix Now", id: "automix.mixNow", isEnabled: state.canMixNow, action: onMixNow)
                        pill("Extend", id: "automix.extend", isEnabled: state.canExtend, action: onExtend)
                    }
                }
            }
            .focusSection()
            .transition(.opacity)
        }
    }

    private var capsule: some View {
        AutoMixNextMixCapsule(state: state, scale: .tv, tint: tint) {
            ArtworkImage(url: incoming?.artworkURL, variant: .thumbnail, identity: incoming?.id ?? state.incomingTrackId)
                .aspectRatio(1, contentMode: .fill)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: Capsule())
    }

    private func pill(_ title: String, id: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
        }
        .buttonStyle(TVGlassPillStyle())
        .focused(focus, equals: .pill(id))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityHint(id == "automix.extend" ? "Plays 8 more bars before the mix" : "Starts the mix on the next bar")
    }
}
