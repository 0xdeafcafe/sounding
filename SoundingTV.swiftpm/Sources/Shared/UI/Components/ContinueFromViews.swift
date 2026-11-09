import SwiftUI

struct ContinueFromHero: View {
    var metrics: CollectionHeroMetrics
    var horizontalPadding: CGFloat = 0

    @ObservedObject private var model = ContinueFrom.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let offer = model.offer {
            ContinueFromHeroContent(offer: offer, metrics: metrics, horizontalPadding: horizontalPadding)
                .id(offer.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14)))
        }
    }
}

private struct ContinueFromHeroContent: View {
    let offer: ContinueFrom.Offer
    let metrics: CollectionHeroMetrics
    let horizontalPadding: CGFloat

    @ObservedObject private var model = ContinueFrom.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var arrived = false

    private var isStacked: Bool { metrics.layout == .stacked }

    private var title: String {
        let trimmed = offer.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? offer.deviceName : trimmed
    }

    private var artist: String? {
        let trimmed = offer.session.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        layout
            .padding(.horizontal, horizontalPadding)
            .padding(.top, isStacked ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: isStacked ? .center : .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.accept(offer, expand: true) }
            .collectionArtworkBackdrop(
                url: offer.session.artworkURL,
                identity: offer.session.trackID,
                headroom: metrics.backdropHeadroom,
                fade: max(metrics.backdropFade, 72)
            )
            .collectionAccent(from: offer.session.artworkURL)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Paused") { model.accept(offer, expand: true) }
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45)) { arrived = true }
            }
    }

    @ViewBuilder
    private var layout: some View {
        if isStacked {
            VStack(spacing: 18) {
                artwork
                details(alignment: .center)
            }
        } else {
            HStack(alignment: .center, spacing: 28) {
                artwork
                details(alignment: .leading)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    private var artwork: some View {
        CollectionHeroArtwork(
            url: offer.session.artworkURL,
            identity: offer.session.trackID,
            side: metrics.artworkSide,
            corner: metrics.artworkCorner
        )
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 14) {
            VStack(alignment: alignment, spacing: 4) {
                Label {
                    Text("Continue from \(offer.deviceName)")
                } icon: {
                    Image(systemName: offer.session.deviceClass.symbolName)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(title)
                    .font(isStacked ? .title2.bold() : .title.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                if let artist {
                    Text(artist)
                        .font(isStacked ? .body : .title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(textAlignment)
                        .lineLimit(1)
                }
            }
            progress
            buttons
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let fraction = offer.progress {
            HStack(spacing: 8) {
                Text(ContinueSessions.clock(offer.position))
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Color.primary)
                Text(ContinueSessions.clock(offer.session.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: isStacked ? 300 : 360)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(ContinueSessions.clock(offer.position)) of \(ContinueSessions.clock(offer.session.duration))")
        }
    }

    private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return GlassEffectContainer {
            layout {
                ContinueFromPlayButton {
                    model.accept(offer, play: true)
                }
                .accessibilityHint("Takes over \(offer.deviceName)\u{2019}s session here")

                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.4)) { model.dismiss(offer) }
                } label: {
                    Text("Not Now")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
    }
}

private struct ContinueFromPlayButton: View {
    let action: () -> Void

    @Environment(\.collectionAccent) private var accent

    private var tinted: CollectionAccent? {
        guard let accent, !accent.isNeutral else { return nil }
        return accent
    }

    var body: some View {
        Button(action: action) {
            Label("Play", systemImage: "play.fill")
                .foregroundStyle(tinted?.onTint(for: .dark) ?? .black)
                .frame(minWidth: 88)
        }
        .buttonStyle(.glassProminent)
        .tint(tinted?.tint(for: .dark) ?? .white)
    }
}

struct ContinueFromHandoff: ViewModifier {
    @ObservedObject private var model = ContinueFrom.shared

    func body(content: Content) -> some View {
        content
            .userActivity(HandoffActivityType.playing, isActive: model.isAdvertising) { activity in
                model.configure(activity)
            }
            .onContinueUserActivity(HandoffActivityType.playing) { activity in
                model.continueActivity(activity)
            }
            .onContinueUserActivity(HandoffActivityType.nowPlaying) { activity in
                model.continueActivity(activity)
            }
    }
}
