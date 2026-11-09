import SwiftUI

struct WatchContinueFromSection: View {
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        if let offer = link.continueOffer, !link.nowPlaying.isPlaying, !isStale(offer) {
            Section {
                WatchContinueFromCard(offer: offer)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func isStale(_ offer: WatchContinueOffer) -> Bool {
        Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(offer.updatedAtMillis) / 1000)) > 12 * 60 * 60
    }
}

struct WatchContinueFromCard: View {
    let offer: WatchContinueOffer

    @EnvironmentObject private var link: WatchLinkClient
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caption: String {
        "\(offer.isPlaying ? "Playing on" : "From") \(offer.deviceName)"
    }

    private var detail: String {
        let clock = offer.positionSeconds.watchClockString
        return offer.artist.isEmpty ? clock : "\(offer.artist) · \(clock)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WatchArtwork(url: offer.artworkURL, size: 46, corner: 10, identity: offer.title)
                VStack(alignment: .leading, spacing: 1) {
                    Label(caption, systemImage: offer.deviceClass.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(offer.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let progress = offer.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Button {
                    link.continueFromOffer(offer)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(!link.isReachable)
                .accessibilityHint("Continues \(offer.title) on this iPhone")

                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        link.dismissOffer(offer)
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Not Now")
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
