import SwiftUI

struct WatchArtwork: View {
    let url: URL?
    var size: CGFloat = 34
    var corner: CGFloat = 7
    var identity: String? = nil

    var body: some View {
        SCArtworkResolver(url: url, variant: .standard) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(
                    identity: identity.flatMap { $0.isEmpty ? nil : $0 } ?? url?.absoluteString ?? "Sounding",
                    subject: corner * 2 >= size ? .person : .track,
                    colorScheme: .dark
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct WatchTrackRow: View {
    let title: String
    let subtitle: String
    var artIdentity: String? = nil
    var artworkURL: URL?
    var duration: TimeInterval? = nil
    var isPlaying = false
    var isDownloaded = false
    var isCircular = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var spokenLabel: String {
        var parts = [title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let duration { parts.append(duration.watchSpokenDuration) }
        if isDownloaded { parts.append("Downloaded") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            WatchArtwork(url: artworkURL, size: 40, corner: isCircular ? 20 : 8, identity: artIdentity ?? title)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(isPlaying ? .semibold : .regular))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }

            Spacer(minLength: 0)

            if isPlaying {
                Image(systemName: differentiateWithoutColor ? "speaker.wave.2.circle.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(isPlaying ? "Now Playing" : "")
    }
}

struct WatchPlayShuffleButtons: View {
    let subject: String
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                buttons
            }
        }
        .font(.footnote.weight(.semibold))
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: play) {
            Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.glassProminent)
        .accessibilityHint("Plays \(subject) from the start")

        Button(action: shuffle) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .buttonStyle(.glass)
        .accessibilityHint("Plays \(subject) in random order")
    }
}

struct WatchLoadingState: View {
    var title: LocalizedStringKey = "Loading"

    var body: some View {
        ContentUnavailableView {
            ProgressView()
        } description: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

struct WatchErrorState: View {
    var title: LocalizedStringKey = "Couldn’t Load"
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.slash")
        } description: {
            if let message { Text(message) }
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.glass)
            }
        }
    }
}

struct WatchTrackQueueActions: ViewModifier {
    let trackId: String
    @EnvironmentObject private var link: WatchLinkClient

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                Button {
                    link.enqueue(trackId: trackId, action: .playNext)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            .accessibilityAction(named: Text("Play Next")) {
                link.enqueue(trackId: trackId, action: .playNext)
            }
            .accessibilityAction(named: Text("Add to Queue")) {
                link.enqueue(trackId: trackId, action: .addToEnd)
            }
    }
}

struct WatchNavigationTint: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if contrast == .increased || reduceTransparency {
            content.containerBackground(Color.black, for: .navigation)
        } else {
            content.containerBackground(Color.accentColor.gradient.opacity(0.28), for: .navigation)
        }
    }
}

extension ScrollViewProxy {
    @MainActor
    func scrollToPreviewTarget() async {
        guard let target = WatchUIPreview.value(for: "-SoundingWatchUIScrollTo") else { return }
        try? await Task.sleep(for: .milliseconds(600))
        if let index = Int(target) {
            scrollTo(index, anchor: .top)
        } else {
            scrollTo(target, anchor: .top)
        }
    }
}

extension View {
    func watchQueueActions(trackId: String) -> some View {
        modifier(WatchTrackQueueActions(trackId: trackId))
    }

    func watchNavigationTint() -> some View {
        modifier(WatchNavigationTint())
    }
}

extension TimeInterval {
    var watchClockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var watchSpokenDuration: String {
        guard isFinite, self >= 0 else { return "0 seconds" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: self.rounded()) ?? watchClockString
    }
}

extension Int64 {
    var watchByteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

// MARK: - Now Playing palette

struct WatchPalette: Equatable, Sendable {
    var base: Color
    var c1: Color
    var c2: Color
    var c3: Color
    var tint: Color
    var glass: Color

    static let fallback = WatchPalette(
        base: Color(red: 0.07, green: 0.08, blue: 0.12),
        c1: Color(red: 0.26, green: 0.33, blue: 0.50),
        c2: Color(red: 0.44, green: 0.38, blue: 0.56),
        c3: Color(red: 0.14, green: 0.20, blue: 0.32),
        tint: Color(red: 0.78, green: 0.84, blue: 0.96),
        glass: Color(red: 0.25, green: 0.30, blue: 0.42)
    )

    private struct HSB {
        var h: Double
        var s: Double
        var b: Double

        init(h: Double, s: Double, b: Double) {
            self.h = h
            self.s = s
            self.b = b
        }

        init(r: Double, g: Double, b: Double) {
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            var hue = 0.0
            if delta > 0.0001 {
                if maxC == r {
                    hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == g {
                    hue = (b - r) / delta + 2
                } else {
                    hue = (r - g) / delta + 4
                }
                hue /= 6
                if hue < 0 { hue += 1 }
            }
            self.h = hue
            self.s = maxC > 0 ? delta / maxC : 0
            self.b = maxC
        }

        var color: Color {
            Color(hue: h, saturation: min(max(s, 0), 1), brightness: min(max(b, 0), 1))
        }

        var vibrancy: Double { s * s.squareRoot() * b }
    }

    nonisolated static func extract(from image: CGImage) -> WatchPalette? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var samples: [HSB] = []
        samples.reserveCapacity(side * side)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            sumR += r
            sumG += g
            sumB += b
            samples.append(HSB(r: r, g: g, b: b))
        }
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        let mean = HSB(r: sumR / count, g: sumG / count, b: sumB / count)

        let ranked = samples.sorted { $0.vibrancy > $1.vibrancy }
        let primary = ranked.first ?? mean
        let secondary = ranked.first { hueDistance($0.h, primary.h) > 0.08 && $0.vibrancy > 0.05 }
            ?? HSB(h: (primary.h + 0.09).truncatingRemainder(dividingBy: 1), s: primary.s * 0.8, b: min(1, primary.b + 0.25))
        let isGrey = primary.s < 0.12

        let base = HSB(h: mean.h, s: isGrey ? mean.s : min(0.7, mean.s * 1.2 + 0.1), b: 0.13)
        let c1 = HSB(h: primary.h, s: isGrey ? primary.s : min(1, primary.s * 1.15), b: max(0.5, primary.b))
        let c2 = HSB(h: secondary.h, s: isGrey ? secondary.s : min(1, secondary.s * 1.1), b: max(0.55, secondary.b))
        let c3 = HSB(h: mean.h, s: min(0.8, mean.s * 1.3), b: 0.38)
        let tint = HSB(h: primary.h, s: isGrey ? 0.08 : 0.34, b: 0.96)
        let glass = HSB(h: primary.h, s: isGrey ? 0.1 : 0.45, b: 0.42)

        return WatchPalette(
            base: base.color,
            c1: c1.color,
            c2: c2.color,
            c3: c3.color,
            tint: tint.color,
            glass: glass.color
        )
    }

    private nonisolated static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}

@MainActor
final class WatchNowPlayingTheme: ObservableObject {
    static let shared = WatchNowPlayingTheme()

    @Published private(set) var palette: WatchPalette = .fallback

    private var cache: [URL: WatchPalette] = [:]
    private var requestedURL: URL?

    func update(for url: URL?) {
        requestedURL = url
        guard let url else {
            palette = .fallback
            return
        }
        if let cached = cache[url] {
            palette = cached
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let image = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail) else { return }
            let extracted = await Task.detached(priority: .utility) { WatchPalette.extract(from: image) }.value
            guard let self, let extracted, self.requestedURL == url else { return }
            self.cache[url] = extracted
            self.palette = extracted
        }
    }
}

struct WatchNowPlayingBackdrop: View {
    let palette: WatchPalette
    let artworkURL: URL?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if reduceTransparency || contrast == .increased {
                Color.black
            } else {
                palette.base

                GeometryReader { proxy in
                    let size = max(proxy.size.width, proxy.size.height)
                    ZStack {
                        if let artworkURL {
                            SCArtworkResolver(url: artworkURL, variant: .thumbnail) { image in
                                if let image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: proxy.size.width, height: proxy.size.height)
                                        .clipped()
                                        .scaleEffect(1.5)
                                        .blur(radius: 22)
                                        .opacity(0.5)
                                } else {
                                    Color.clear
                                }
                            }
                        }
                        blob(palette.c1, diameter: size * 0.95, opacity: 0.42)
                            .position(x: size * 0.12, y: size * 0.1)
                        blob(palette.c2, diameter: size * 0.95, opacity: 0.26)
                            .position(x: proxy.size.width, y: proxy.size.height)
                        blob(palette.c3, diameter: size * 0.7, opacity: 0.4)
                            .position(x: proxy.size.width * 0.45, y: proxy.size.height * 0.7)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }

                LinearGradient(
                    colors: [.black.opacity(0.35), .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func blob(_ color: Color, diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
    }
}

struct WatchNowPlayingScreen: ViewModifier {
    @ObservedObject private var theme = WatchNowPlayingTheme.shared
    @ObservedObject private var playback = WatchPlayback.shared
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle {
                Text(title)
                    .foregroundStyle(theme.palette.tint)
            }
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.palette.tint)
            .preferredColorScheme(.dark)
            .containerBackground(for: .navigation) {
                WatchNowPlayingBackdrop(palette: theme.palette, artworkURL: playback.nowPlaying.artworkURL)
            }
    }
}

struct WatchNowPlayingRow<Leading: View>: View {
    let title: String
    var subtitle: String = ""
    var isCurrent = false
    @ViewBuilder let leading: () -> Leading

    @ObservedObject private var theme = WatchNowPlayingTheme.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 9) {
            leading()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? theme.palette.tint : .primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct WatchRoundIcon: View {
    let systemImage: String
    var tinted = false

    @ObservedObject private var theme = WatchNowPlayingTheme.shared

    var body: some View {
        Circle()
            .fill(.white.opacity(0.15))
            .overlay {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tinted ? theme.palette.tint : .primary)
            }
            .accessibilityHidden(true)
    }
}

struct WatchNowPlayingRowBackground: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content.listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(isCurrent ? 0.15 : 0.09))
        )
    }
}

extension View {
    func watchNowPlayingScreen(_ title: String) -> some View {
        modifier(WatchNowPlayingScreen(title: title))
    }

    func watchNowPlayingRowBackground(isCurrent: Bool = false) -> some View {
        modifier(WatchNowPlayingRowBackground(isCurrent: isCurrent))
    }
}
