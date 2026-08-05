import SwiftUI
import Foundation
import CoreImage
import UIKit
import MediaPlayer

private extension Animation {
    static let scWhimsy = Animation.spring(response: 0.42, dampingFraction: 0.68)
}

private struct SquishButtonStyle: ButtonStyle {
    var reduceMotion: Bool
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .animation(
                .scMotion(SCContentMotion.press, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct TransportBarView: View {
    @Binding var isExpanded: Bool
    let heroID: String
    let heroNamespace: Namespace.ID

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var palette = NowPlayingPalette.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement

    private var effectivePlacement: TabViewBottomAccessoryPlacement? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_ACCESSORY"] == "inline" {
            return .inline
        }
        #endif
        return accessoryPlacement
    }

    @State private var clock = PlaybackClock()
    @State private var transportTick = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var skipOffset: CGFloat = 0
    @State private var skipRegionWidth: CGFloat = 320
    @State private var incomingSkipPreview: PhonePlaybackCoordinator.SkipPreview?
    @State private var incomingSkipEdge: Edge?
    @State private var skipSettling = false
    @State private var skipResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = coordinator.nowPlaying {
                Group {
                    if effectivePlacement == .inline {
                        miniBarInline(snapshot)
                    } else {
                        miniBarExpanded(snapshot)
                    }
                }
                .padding(.horizontal, effectivePlacement == .inline ? Space.snug : Space.tight)
                .padding(.vertical, effectivePlacement == .inline ? Space.hair : Space.snug)
                .background(legibilityScrim)
                .overlay {
                    miniBarShape
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
            }
        }
        .onAppear { syncClock(coordinator.nowPlaying) }
        .onChange(of: coordinator.nowPlaying) { _, newValue in syncClock(newValue) }
        .onChange(of: coordinator.nowPlaying?.artworkURL, initial: true) { _, urlString in
            let url = urlString.flatMap(URL.init)
            palette.update(for: url, reduceMotion: reduceMotion)
            ArtworkColors.shared.update(for: url)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_NOW_PLAYING_EXPANDED"] == "1" else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            isExpanded = true
        }
        #endif
    }

    private func syncClock(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot else { return }
        clock = PlaybackClock(snapshot: snapshot)
    }

    @ViewBuilder
    private var legibilityScrim: some View {
        if reduceTransparency {
            miniBarShape.fill(Color(white: 0.08))
        } else {
            miniBarShape
                .fill(.ultraThinMaterial)
                .overlay(miniBarShape.fill(Color.black.opacity(0.18)))
        }
    }

    private var miniBarShape: Capsule {
        Capsule()
    }

    private func miniBarExpanded(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: Space.tight) {
            identityCarousel(snapshot)

            Spacer(minLength: Space.hair)

            miniTransportButtons(snapshot)
        }
        .overlay(alignment: .bottom) {
            progressTrack(snapshot)
                .padding(.horizontal, Space.hair)
                .offset(y: Space.hair)
        }
        .contentShape(miniBarShape)
        .simultaneousGesture(skipGesture)
    }

    private func identityCarousel(_ snapshot: NowPlayingSnapshot) -> some View {
        ZStack(alignment: .leading) {
            Button {
                withAnimation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion)) { isExpanded = true }
            } label: {
                identityContent(
                    title: snapshot.displayTitle,
                    artist: snapshot.displayArtist,
                    artworkURL: snapshot.artworkURL,
                    companionGlyph: snapshot.source.companionClass?.symbolName
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: heroID, in: heroNamespace)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: snapshot))
            .accessibilityHint("Opens the full-screen player")
            .offset(x: skipOffset)
            .opacity(1 - skipTransitionProgress * 0.72)

            if let preview = incomingSkipPreview, let edge = incomingSkipEdge {
                identityContent(
                    title: preview.title,
                    artist: preview.artist,
                    artworkURL: preview.artworkURL,
                    companionGlyph: snapshot.source.companionClass?.symbolName
                )
                .offset(x: skipOffset + (edge == .trailing ? skipRegionWidth : -skipRegionWidth))
                .opacity(0.28 + skipTransitionProgress * 0.72)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            skipRegionWidth = max(1, width)
        }
        .onChange(of: snapshot.trackId) { _, _ in completeSkip() }
    }

    private var skipTransitionProgress: CGFloat {
        min(1, abs(skipOffset) / max(skipRegionWidth, 1))
    }

    private func identityContent(
        title: String, artist: String, artworkURL: String?, companionGlyph: String?
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            miniArtwork(artworkURL, artist: artist, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let companionGlyph {
                        Image(systemName: companionGlyph)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Text(title)
                        .font(.scHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
                Text(artist)
                    .font(.scSubhead)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
        }
        .animation(.scMotion(SCContentMotion.gentle, reduceMotion: reduceMotion), value: title)
        .animation(.scMotion(SCContentMotion.gentle, reduceMotion: reduceMotion), value: artist)
    }

    private var skipGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !skipSettling else { return }
                let dx = value.translation.width
                let preview = dx < 0 ? coordinator.nextSkipPreview : coordinator.previousSkipPreview
                if let preview {
                    skipOffset = dx
                    incomingSkipPreview = preview
                    incomingSkipEdge = dx < 0 ? .trailing : .leading
                } else {
                    skipOffset = dx / 3
                    incomingSkipPreview = nil
                    incomingSkipEdge = nil
                }
            }
            .onEnded { value in
                guard !skipSettling else { return }
                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                let threshold = max(42, skipRegionWidth * 0.2)
                if min(dx, projected) <= -threshold, coordinator.nextSkipPreview != nil {
                    commitSkip(edge: .trailing) { coordinator.next() }
                } else if max(dx, projected) >= threshold, coordinator.previousSkipPreview != nil {
                    commitSkip(edge: .leading) { coordinator.previous() }
                } else {
                    withAnimation(reduceMotion ? nil : SCContentMotion.press) { skipOffset = 0 }
                    skipResetTask?.cancel()
                    skipResetTask = Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        guard !Task.isCancelled else { return }
                        incomingSkipPreview = nil
                        incomingSkipEdge = nil
                    }
                }
            }
    }

    private func commitSkip(edge: Edge, verb: () -> Void) {
        skipSettling = true
        let target: CGFloat = edge == .trailing ? -skipRegionWidth : skipRegionWidth
        if reduceMotion {
            skipOffset = target
        } else {
            withAnimation(SCContentMotion.settle) { skipOffset = target }
        }
        verb()
        transportTick.toggle()
        skipResetTask?.cancel()
        skipResetTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            completeSkip()
        }
    }

    private func completeSkip() {
        skipResetTask?.cancel()
        skipResetTask = nil
        guard skipOffset != 0 || incomingSkipPreview != nil || skipSettling else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            skipOffset = 0
            incomingSkipPreview = nil
            incomingSkipEdge = nil
            skipSettling = false
        }
    }

    private func miniBarInline(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                withAnimation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion)) { isExpanded = true }
            } label: {
                HStack(spacing: Spacing.sm) {
                    miniArtwork(snapshot.artworkURL, artist: snapshot.displayArtist, size: 32)

                    HStack(spacing: 5) {
                        if let companionGlyph = snapshot.source.companionClass?.symbolName {
                            Image(systemName: companionGlyph)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Text(snapshot.displayTitle)
                            .font(.scSubhead)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: heroID, in: heroNamespace)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: snapshot))
            .accessibilityHint("Opens the full-screen player")

            Spacer(minLength: Spacing.sm)

            miniPlayButton(snapshot)
        }
    }

    private func miniPlayButton(_ snapshot: NowPlayingSnapshot) -> some View {
        Button {
            coordinator.togglePlayPause()
        } label: {
            playPauseGlyph(snapshot, iconSize: 13)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .animation(.scMotion(SCContentMotion.press, reduceMotion: reduceMotion), value: snapshot.isPlaying)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(snapshot.isLoading ? "Loading" : (snapshot.isPlaying ? "Pause" : "Play"))
        .sensoryFeedback(.impact(weight: .medium), trigger: snapshot.isPlaying)
    }

    private func accessibilityLabel(for snapshot: NowPlayingSnapshot) -> String {
        let base = "Now Playing, \(snapshot.displayTitle) by \(snapshot.displayArtist)"
        guard let companionClass = snapshot.source.companionClass else { return base }
        return base + ", on \(companionClass.displayName)"
    }

    private func miniTransportButtons(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: Space.tight) {
            Button {
                coordinator.togglePlayPause()
            } label: {
                playPauseGlyph(snapshot, iconSize: 22)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    .animation(.scMotion(SCContentMotion.press, reduceMotion: reduceMotion), value: snapshot.isPlaying)
            }
            .accessibilityLabel(snapshot.isLoading ? "Loading" : (snapshot.isPlaying ? "Pause" : "Play"))

            Button {
                coordinator.next()
                transportTick.toggle()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 46, height: 52)
            }
            .accessibilityLabel("Next Track")
        }
        .foregroundStyle(.primary)
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .sensoryFeedback(.impact(weight: .light), trigger: transportTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: snapshot.isPlaying)
    }

    private func progressTrack(_ snapshot: NowPlayingSnapshot) -> some View {
        let duration = max(snapshot.duration, 1)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let shown = clock.estimate(isPlaying: snapshot.isPlaying, duration: duration, at: context.date)
            GeometryReader { proxy in
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(palette.current.accent.gradient)
                            .frame(width: proxy.size.width * min(1, max(0, shown / duration)))
                            .animation(.scMotion(.linear(duration: 1), reduceMotion: reduceMotion), value: shown)
                    }
            }
            .frame(height: 3)
        }
        .accessibilityHidden(true)
    }

    private func miniArtwork(_ urlString: String?, artist: String?, size: CGFloat = 44) -> some View {
        AsyncImage(url: Self.thumbnailURL(urlString)) { phase in
            if case .success(let image) = phase {
                // SoundCloud artwork is not guaranteed to be square. Fitting it
                // preserves the whole cover instead of silently cropping it.
                image.resizable().scaledToFit()
            } else {
                GeneratedArtworkCard(
                    identity: artist ?? "Now Playing",
                    mode: .blob,
                    style: .phone,
                    isAnimated: false
                )
            }
        }
        .frame(width: size, height: size)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
        .kyleCrowned(user: nil, context: artist)
    }

    @ViewBuilder
    private func playPauseGlyph(_ snapshot: NowPlayingSnapshot, iconSize: CGFloat) -> some View {
        if reduceMotion {
            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: snapshot.isPlaying)
        }
    }

    fileprivate static func thumbnailURL(_ urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return url.soundCloudArtworkVariant("t200x200")
    }
}

private struct PlaybackClock: Equatable {
    private(set) var anchorPosition: Double = 0
    private(set) var anchorDate: Date = .now

    init() {}

    init(snapshot: NowPlayingSnapshot) {
        anchorPosition = snapshot.position
        anchorDate = .now
    }

    func estimate(isPlaying: Bool, duration: Double, at date: Date) -> Double {
        isPlaying ? min(duration, anchorPosition + date.timeIntervalSince(anchorDate)) : anchorPosition
    }
}

private func scFormatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours > 0 else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

@MainActor
final class LikedTracksProbe: ObservableObject {
    static let shared = LikedTracksProbe()

    @Published private(set) var knownLikedIds: Set<String> = []

    private var fetchTask: Task<Void, Never>?
    private var lastFetch: Date?
    private let refreshInterval: TimeInterval = 5 * 60
    private let pageLimit = 200

    private init() {}

    func markLiked(_ id: String, liked: Bool) {
        if liked { knownLikedIds.insert(id) } else { knownLikedIds.remove(id) }
    }

    func refreshIfStale() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < refreshInterval { return }
        guard fetchTask == nil else { return }
        fetchTask = Task { @MainActor [weak self] in
            defer { self?.fetchTask = nil }
            guard let page = try? await SoundCloudAPI.shared.getLikedTracks(limit: self?.pageLimit ?? 200) else { return }
            guard let self else { return }
            self.lastFetch = Date()
            self.knownLikedIds.formUnion(page.collection.map(\.item.id))
        }
    }
}

@MainActor
final class NowPlayingPalette: ObservableObject {
    static let shared = NowPlayingPalette()

    struct MeshPalette: Equatable {
        let colors: [Color]
        let accent: Color

        static let fallback = MeshPalette(
            colors: Array(repeating: Color.scAmbientFallback, count: 9),
            accent: .scAccent
        )
    }

    @Published private(set) var current: MeshPalette = .fallback

    private var cache: [URL: MeshPalette] = [:]
    private var currentURL: URL?
    private var task: Task<Void, Never>?

    private init() {}

    func lockAccount() {
        task?.cancel()
        task = nil
        currentURL = nil
        cache.removeAll()
        current = .fallback
    }

    func update(for url: URL?, reduceMotion: Bool) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()

        guard let url else {
            withAnimation(.scMotion(SCContentMotion.ambient, reduceMotion: reduceMotion)) { self.current = .fallback }
            return
        }

        if let cached = cache[url] {
            withAnimation(.scMotion(SCContentMotion.ambient, reduceMotion: reduceMotion)) { self.current = cached }
            return
        }

        task = Task { [weak self] in
            guard let extracted = await Self.extract(from: url) else { return }
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.cache[url] = extracted
            withAnimation(.scMotion(SCContentMotion.ambient, reduceMotion: reduceMotion)) { self.current = extracted }
        }
    }

    nonisolated private static func extract(from url: URL) async -> MeshPalette? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let cg = image.cgImage else { return nil }

        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        let context = CIContext(options: [.workingColorSpace: NSNull()])

        let cols = 3, rows = 3
        var samples: [Color] = []
        var raws: [Color] = []
        samples.reserveCapacity(cols * rows)
        raws.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let rect = CGRect(
                    x: extent.minX + extent.width  * CGFloat(col) / CGFloat(cols),
                    y: extent.minY + extent.height * CGFloat(row) / CGFloat(rows),
                    width: extent.width / CGFloat(cols),
                    height: extent.height / CGFloat(rows)
                )
                let raw = averageColor(of: ci, in: rect, context: context) ?? .scAmbientFallback
                raws.append(raw)
                samples.append(Color(rgb: SCAmbient.background(from: SCAmbient.components(raw))))
            }
        }

        let vivid = raws.max(by: { saturation(of: $0) < saturation(of: $1) }) ?? .scAccent
        let base = samples[samples.count / 2]
        return MeshPalette(
            colors: samples,
            accent: SCAmbient.accent(from: vivid, on: base)
        )
    }

    nonisolated private static func averageColor(of image: CIImage, in rect: CGRect, context: CIContext) -> Color? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Color(
            red:   Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue:  Double(bitmap[2]) / 255
        )
    }

    nonisolated private static func saturation(of color: Color) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }

}

extension View {
    func nowPlayingCover(
        isPresented: Binding<Bool>,
        heroID: String,
        namespace: Namespace.ID
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            NowPlayingSheet(heroID: heroID, namespace: namespace)
        }
    }
}

private struct ZoomIfMotionAllowed: ViewModifier {
    let reduceMotion: Bool
    let heroID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: heroID, in: namespace))
        }
    }
}

struct NowPlayingSheet: View {
    let heroID: String
    let namespace: Namespace.ID

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var palette = NowPlayingPalette.shared
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.soundingReducedResourceUsage) private var reducedResourceUsage

    @State private var clock = PlaybackClock()
    @State private var dragPositionSeconds: Double?
    @StateObject private var waveformStore = PhoneWaveformStore()
    @StateObject private var cueBoard = CueBoard()
    @State private var showingCues = false
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @State private var showingSetlist = false
    @ObservedObject private var likedProbe = LikedTracksProbe.shared
    @State private var pendingFavoriteTrackId: String?
    @State private var skipFeedbackTick = false
    @State private var lowerPanel: NowPlayingLowerPanel = .comments
    @State private var artworkDragOffset: CGFloat = 0
    @State private var incomingArtworkPreview: PhonePlaybackCoordinator.SkipPreview?
    @State private var incomingArtworkEdge: Edge?
    @State private var artworkSkipSettling = false
    @State private var artworkResetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    meshBackground
                    if let snapshot = coordinator.nowPlaying {
                        ScrollViewReader { scrollProxy in
                            ScrollView(.vertical) {
                                VStack(spacing: 0) {
                                    playerHeader
                                        .id(NowPlayingSection.player)
                                    Spacer(minLength: Space.tight)
                                    artwork(
                                        snapshot,
                                        size: min(
                                            min(
                                                proxy.size.width - PhoneNowPlaying.pageInset * 2,
                                                proxy.size.height * 0.38
                                            ),
                                            360
                                        )
                                    )
                                    .contentShape(Rectangle())
                                    .accessibilityAction(named: "Previous Track") {
                                        coordinator.previous()
                                        skipFeedbackTick.toggle()
                                    }
                                    .accessibilityAction(named: "Next Track") {
                                        coordinator.next()
                                        skipFeedbackTick.toggle()
                                    }
                                    Spacer(minLength: Space.roomy)
                                    titleArtist(snapshot, scrollProxy: scrollProxy)
                                    scrubber(snapshot)
                                        .padding(.top, Space.snug)
                                    transportButtons(snapshot)
                                        .padding(.top, Space.hair)
                                    Spacer(minLength: 2)
                                    bottomUtilityRow(snapshot, scrollProxy: scrollProxy)
                                    belowFoldSections(snapshot, scrollProxy: scrollProxy)
                                }
                                .frame(minHeight: proxy.size.height, alignment: .top)
                                .padding(.horizontal, PhoneNowPlaying.pageInset)
                                .padding(.bottom, Spacing.sm)
                            }
                            .scrollIndicators(.hidden)
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollClipDisabled()
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .modifier(ZoomIfMotionAllowed(reduceMotion: reduceMotion, heroID: heroID, namespace: namespace))
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard value.translation.height > 90, abs(value.translation.width) < 140 else { return }
                    dismiss()
                }
        )
        .accessibilityAction(.escape) { dismiss() }
        .sensoryFeedback(.selection, trigger: skipFeedbackTick)
        .onAppear {
            if let snapshot = coordinator.nowPlaying { clock = PlaybackClock(snapshot: snapshot) }
        }
        .onChange(of: coordinator.nowPlaying) { _, newValue in
            guard let newValue else {
                dismiss()
                return
            }
            clock = PlaybackClock(snapshot: newValue)
            if !artworkSkipSettling { completeArtworkSkip() }
        }
        .onChange(of: coordinator.nowPlaying?.trackId, initial: true) { _, trackId in
            waveformStore.ensureLoaded(trackId: trackId)
        }
        .onChange(of: coordinator.nowPlaying?.trackId, initial: true) { _, _ in
            likedProbe.refreshIfStale()
        }
        .onChange(of: pulseFeedKey, initial: true) { _, _ in
            MusicPulse.shared.ingest(
                trackId: coordinator.nowPlaying?.trackId,
                samples: waveformStore.waveform.samples ?? [],
                duration: coordinator.nowPlaying?.duration ?? 0
            )
        }
        .onChange(of: setlistSeedKey, initial: true) { _, _ in
            guard let track = waveformStore.resolvedTrack else { return }
            setlistStore.seed(track: track, comments: waveformStore.comments)
        }
        .onChange(of: coordinator.nowPlaying, initial: true) { _, snapshot in
            guard let snapshot else { return }
            MusicPulse.shared.anchor(position: snapshot.position, isPlaying: snapshot.isPlaying)
        }
        .onChange(of: pulseFeedKey, initial: true) { _, _ in
            cueBoard.ensureLoaded(
                trackId: coordinator.nowPlaying?.trackId,
                duration: coordinator.nowPlaying?.duration ?? 0,
                waveform: waveformStore.waveform.samples.map { Waveform(samples: $0) }
            )
        }
        .sheet(isPresented: $showingCues) {
            if let snapshot = coordinator.nowPlaying, let trackId = snapshot.trackId {
                TrackMapSheet(
                    trackTitle: snapshot.displayTitle,
                    trackId: trackId,
                    currentPosition: snapshot.position,
                    duration: snapshot.duration,
                    envelope: waveformStore.waveform.samples ?? [],
                    board: cueBoard,
                    accent: palette.current.accent,
                    onSeek: { coordinator.seek(to: $0) }
                )
            }
        }
        .sheet(isPresented: $showingSetlist) {
            if let track = waveformStore.resolvedTrack, let snapshot = coordinator.nowPlaying {
                SetlistEditorView(
                    track: track,
                    currentPosition: dragPositionSeconds ?? snapshot.position,
                    comments: waveformStore.comments,
                    localFileURL: PlayerService.shared.localAudioURL(for: track),
                    onSeek: { coordinator.seek(to: $0) },
                    onDownload: { _ = DownloadManager.shared.download(track) },
                    onPlaySearchResult: { result in
                        Task { await coordinator.playHere(result, in: [result]) }
                    }
                )
            }
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_CUES"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            showingCues = true
        }
        #endif
    }

    private var pulseFeedKey: String {
        "\(coordinator.nowPlaying?.trackId ?? "-")#\(waveformStore.waveform.samples?.count ?? 0)"
    }

    private var setlistSeedKey: String {
        "\(waveformStore.resolvedTrack?.id ?? "-")#\(waveformStore.comments.count)"
    }

    private func belowFoldSections(_ snapshot: NowPlayingSnapshot, scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Picker("Now Playing Details", selection: $lowerPanel) {
                ForEach(NowPlayingLowerPanel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Switches between track comments and the active queue")

            switch lowerPanel {
            case .comments:
                NowPlayingCommentsSection(
                    store: waveformStore,
                    accent: palette.current.accent,
                    trackId: snapshot.trackId,
                    onSeek: { time in
                        coordinator.seek(to: time)
                        scrollTo(.player, with: scrollProxy)
                    }
                )
                .id(NowPlayingSection.comments)

                if let track = waveformStore.resolvedTrack {
                    NowPlayingBehindTrackCard(track: track, accent: palette.current.accent)
                        .id(NowPlayingSection.behind)
                }

            case .upNext:
                if coordinator.upNextEntries.isEmpty {
                    ContentUnavailableView(
                        "Queue Is Clear",
                        systemImage: "text.line.last.and.arrowtriangle.forward",
                        description: Text("Add another track and it will appear here.")
                    )
                    .id(NowPlayingSection.upNext)
                } else {
                    NowPlayingUpNextSection(
                        entries: coordinator.upNextEntries,
                        accent: palette.current.accent
                    )
                    .id(NowPlayingSection.upNext)
                }
            }
        }
        .padding(.top, Space.section)
        .padding(.bottom, Space.roomy)
    }

    private func scrollTo(_ section: NowPlayingSection, with proxy: ScrollViewProxy) {
        withAnimation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion)) {
            proxy.scrollTo(section, anchor: .top)
        }
    }

    private var ambientSeed: AmbientArtworkSeed {
        let current = artworkColors.current
        return AmbientArtworkSeed(
            artwork: current.artwork,
            colors: [current.primary, current.secondary, current.average, current.accent],
            accent: current.accent,
            scrim: current.backdropScrim(layerOpacity: 0.5, additiveHeadroom: 1.1)
        )
    }

    private var meshBackground: some View {
        AmbientArtworkBackdrop(
            seed: ambientSeed,
            isAnimated: !reduceMotion && !reducedResourceUsage,
            intensity: 0.7
        )
            .ignoresSafeArea()
            .backgroundExtensionEffect()
    }

    private var playerHeader: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion, scale: 0.92))
            .accessibilityLabel("Close Now Playing")
            .accessibilityHint("Returns to the previous screen")

            Spacer()
        }
        .padding(.top, Space.tight)
    }

    private func bottomUtilityRow(_ snapshot: NowPlayingSnapshot, scrollProxy _: ScrollViewProxy) -> some View {
        HStack(spacing: Space.snug) {
            favoriteButton(trackId: snapshot.trackId)
            moreButton(snapshot)

            utilityIconButton("timeline.selection", label: trackMapAccessibilityLabel) {
                showingCues = true
            }

            if waveformStore.resolvedTrack != nil {
                utilityIconButton("list.bullet.rectangle", label: "Setlist") {
                    showingSetlist = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .animation(.scMotion(.scWhimsy, reduceMotion: reduceMotion), value: snapshot.source)
    }

    private func utilityIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    private var trackMapAccessibilityLabel: String {
        let count = cueBoard.sheet.userCues.count
        guard count > 0 else { return "Cue Points" }
        return count == 1 ? "Cue Points, 1 marked" : "Cue Points, \(count) marked"
    }

    private var showsOutputPicker: Bool {
        coordinator.isAppleTVAvailable || coordinator.isPlayingOnAppleTV
    }

    private func artwork(_ snapshot: NowPlayingSnapshot, size: CGFloat) -> some View {
        ZStack {
            artworkBody(snapshot, size: size, glow: 0.56)
                .id(snapshot.trackId ?? "\(snapshot.displayTitle)#\(snapshot.displayArtist)")
                .offset(x: artworkDragOffset)

            if let preview = incomingArtworkPreview, let edge = incomingArtworkEdge {
                artworkBody(preview, size: size)
                    .offset(
                        x: artworkDragOffset
                            + (edge == .trailing ? size + Space.roomy : -(size + Space.roomy))
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .gesture(artworkSkipGesture(size: size))
        .accessibilityHidden(true)
    }

    private func artworkBody(_ snapshot: NowPlayingSnapshot, size: CGFloat, glow: Double) -> some View {
        artworkBody(
            artworkURL: snapshot.artworkURL,
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            size: size,
            glow: glow
        )
    }

    private func artworkBody(_ preview: PhonePlaybackCoordinator.SkipPreview, size: CGFloat) -> some View {
        artworkBody(
            artworkURL: preview.artworkURL,
            title: preview.title,
            artist: preview.artist,
            size: size,
            glow: 0.24
        )
    }

    private func artworkBody(
        artworkURL: String?, title: String, artist: String, size: CGFloat, glow: Double
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(palette.current.accent.opacity(glow))
                .frame(width: size * 0.86, height: size * 0.86)
                .blur(radius: 42)
                .offset(y: size * 0.08)

            AsyncImage(url: Self.heroURL(artworkURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    GeneratedArtworkCard(
                        identity: "\(title)|\(artist)",
                        mode: .blob,
                        style: .phone,
                        isAnimated: !reducedResourceUsage
                    )
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            .kyleCrowned(user: nil, context: artist)
            .overlay(
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 26, y: 14)
        }
    }

    private func artworkSkipGesture(size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !artworkSkipSettling else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.08 else { return }

                let preview = dx < 0 ? coordinator.nextSkipPreview : coordinator.previousSkipPreview
                incomingArtworkPreview = preview
                incomingArtworkEdge = dx < 0 ? .trailing : .leading
                artworkDragOffset = preview == nil ? dx / 4 : dx
            }
            .onEnded { value in
                guard !artworkSkipSettling else { return }
                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.08 else {
                    cancelArtworkSkip()
                    return
                }

                let threshold = max(54, size * 0.18)
                if min(dx, projected) <= -threshold, coordinator.nextSkipPreview != nil {
                    commitArtworkSkip(edge: .trailing, size: size)
                } else if max(dx, projected) >= threshold, coordinator.previousSkipPreview != nil {
                    commitArtworkSkip(edge: .leading, size: size)
                } else {
                    cancelArtworkSkip()
                }
            }
    }

    private func commitArtworkSkip(edge: Edge, size: CGFloat) {
        artworkSkipSettling = true
        artworkResetTask?.cancel()
        let target = edge == .trailing ? -(size + Space.roomy) : size + Space.roomy
        withAnimation(reduceMotion ? nil : SCContentMotion.settle) {
            artworkDragOffset = target
        }
        artworkResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 170))
            guard !Task.isCancelled else { return }
            edge == .trailing ? coordinator.next() : coordinator.previous()
            skipFeedbackTick.toggle()
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
            guard !Task.isCancelled else { return }
            completeArtworkSkip()
        }
    }

    private func cancelArtworkSkip() {
        withAnimation(reduceMotion ? nil : SCContentMotion.press) {
            artworkDragOffset = 0
        }
        artworkResetTask?.cancel()
        artworkResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 260))
            guard !Task.isCancelled else { return }
            incomingArtworkPreview = nil
            incomingArtworkEdge = nil
        }
    }

    private func completeArtworkSkip() {
        artworkResetTask?.cancel()
        artworkResetTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            artworkDragOffset = 0
            incomingArtworkPreview = nil
            incomingArtworkEdge = nil
            artworkSkipSettling = false
        }
    }

    private static func heroURL(_ urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return url.soundCloudArtworkVariant("t500x500")
    }

    private func titleArtist(_ snapshot: NowPlayingSnapshot, scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard waveformStore.resolvedTrack != nil else { return }
                scrollTo(.behind, with: scrollProxy)
            } label: {
                Text(snapshot.displayTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let artistURL = waveformStore.resolvedTrack?.user.permalinkURL {
                Link(destination: artistURL) {
                    artistName(snapshot.displayArtist)
                }
            } else {
                artistName(snapshot.displayArtist)
            }

            if let companionClass = snapshot.source.companionClass {
                Label(companionClass.displayName, systemImage: companionClass.symbolName)
                    .font(.scCaption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 2)
            }

            if let track = waveformStore.resolvedTrack {
                if DeckIdentityResolver.isLikelyMix(track) || setlistStore.setlist(for: track.id) != nil {
                    OnDecksIndicator(
                        identity: setlistStore.setlist(for: track.id)?.segment(at: dragPositionSeconds ?? snapshot.position),
                        isScanning: setlistStore.scanningTrackIds.contains(track.id),
                        action: { showingSetlist = true }
                    )
                    .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
    }

    private func artistName(_ name: String) -> some View {
        Text(name)
            .font(.callout.weight(.medium))
            .foregroundStyle(palette.current.accent.opacity(0.9))
            .lineLimit(1)
    }

    private func vanityMetrics(_ track: Track) -> some View {
        HStack(spacing: 14) {
            if let playbackCount = track.playbackCount {
                Label(playbackCount.formatted(.number.notation(.compactName)), systemImage: "play.fill")
            }
            Label(track.likeCount.formatted(.number.notation(.compactName)), systemImage: "heart.fill")
            Label(track.repostCount.formatted(.number.notation(.compactName)), systemImage: "arrow.2.squarepath")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func favoriteButton(trackId: String?) -> some View {
        if let trackId {
            let isLiked = likedProbe.knownLikedIds.contains(trackId)
            Button {
                toggleFavorite(trackId: trackId)
            } label: {
            Image(systemName: isLiked ? "star.fill" : "star")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isLiked ? Color.scAccent : .white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(isLiked ? "Remove from Likes" : "Add to Likes")
            .sensoryFeedback(.impact(weight: .light), trigger: isLiked)
        }
    }

    private func toggleFavorite(trackId: String) {
        guard pendingFavoriteTrackId != trackId else { return }
        pendingFavoriteTrackId = trackId
        let wasLiked = likedProbe.knownLikedIds.contains(trackId)
        likedProbe.markLiked(trackId, liked: !wasLiked)

        Task {
            defer { pendingFavoriteTrackId = nil }
            let track: Track?
            if waveformStore.resolvedTrack?.id == trackId {
                track = waveformStore.resolvedTrack
            } else {
                track = try? await SoundCloudAPI.shared.getTrack(id: trackId)
            }
            guard let track else {
                revertFavorite(trackId: trackId, to: wasLiked)
                return
            }
            do {
                if wasLiked {
                    try await SoundCloudAPI.shared.unlikeTrack(track)
                } else {
                    try await SoundCloudAPI.shared.likeTrack(track)
                }
            } catch {
                revertFavorite(trackId: trackId, to: wasLiked)
            }
        }
    }

    private func revertFavorite(trackId: String, to wasLiked: Bool) {
        likedProbe.markLiked(trackId, liked: wasLiked)
    }

    private func moreButton(_ snapshot: NowPlayingSnapshot) -> some View {
        Menu {
            if showsOutputPicker {
                Section("Play On") {
                    Picker(
                        "Output",
                        selection: Binding(
                            get: { coordinator.activeSource },
                            set: { target in Task { await coordinator.moveSession(to: target) } }
                        )
                    ) {
                        Label(PlaybackOutput.thisDevice.displayName, systemImage: PlaybackOutput.thisDevice.symbolName)
                            .tag(PlaybackOutput.thisDevice)
                        ForEach(PlaybackOutput.deviceClassesWithCompanionServerToday, id: \.self) { deviceClass in
                            let output = PlaybackOutput.companion(deviceClass)
                            Label(output.displayName, systemImage: output.symbolName).tag(output)
                        }
                    }
                }
            }

            if let url = waveformStore.resolvedTrack?.permalinkURL {
                if showsOutputPicker { Divider() }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
            } else {
                Text("Track details unavailable")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("More")
    }

    private func scrubber(_ snapshot: NowPlayingSnapshot) -> some View {
        let duration = max(snapshot.duration, 1)

        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let liveEstimate = clock.estimate(isPlaying: snapshot.isPlaying, duration: duration, at: context.date)
            let shown = dragPositionSeconds ?? liveEstimate

            VStack(spacing: Spacing.xs) {
                PhoneWaveformScrubber(
                    duration: duration,
                    shown: shown,
                    isPlaying: snapshot.isPlaying,
                    store: waveformStore,
                    accent: palette.current.accent,
                    reduceMotion: reduceMotion,
                    onDrag: { dragPositionSeconds = $0 },
                    onCommit: { target in
                        coordinator.seek(to: target)
                        dragPositionSeconds = nil
                    },
                    onSeekToComment: { coordinator.seek(to: $0) },
                    trackId: snapshot.trackId,
                    cueBoard: cueBoard,
                    onSeekToCue: { coordinator.seek(to: $0) }
                )

                HStack {
                    Text(scFormatTime(shown))
                    Spacer()
                    Text("-" + scFormatTime(max(0, duration - shown)))
                }
                .font(.system(size: 12,
                              weight: dragPositionSeconds == nil ? .medium : .semibold)
                    .monospacedDigit())
                .foregroundStyle(.white.opacity(dragPositionSeconds == nil ? 0.7 : 0.95))
                .animation(.scMotion(SCContentMotion.gentle, reduceMotion: reduceMotion), value: dragPositionSeconds == nil)
            }
        }
    }

    private func transportButtons(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 32) {
                Button {
                    coordinator.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("Previous Track")

                Button {
                    coordinator.togglePlayPause()
                } label: {
                    Group {
                        if reduceMotion {
                            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: snapshot.isPlaying)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .animation(.scMotion(SCContentMotion.press, reduceMotion: reduceMotion), value: snapshot.isPlaying)
                }
                .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion, scale: 0.93))
                .accessibilityLabel(snapshot.isLoading ? "Loading" : (snapshot.isPlaying ? "Pause" : "Play"))

                Button {
                    coordinator.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel("Next Track")
        }
        .animation(.scMotion(SCContentMotion.ambient, reduceMotion: reduceMotion), value: palette.current)
        .sensoryFeedback(.impact(weight: .medium), trigger: snapshot.isPlaying)
    }

}

enum PhoneWaveformState: Equatable {
    case idle
    case loading
    case ready(samples: [Float])
    case unavailable(String)

    var samples: [Float]? {
        if case .ready(let samples) = self { return samples }
        return nil
    }
}

enum PhoneCommentsState: Equatable {
    case idle
    case loading
    case loaded
    case failed
    case signedOut
}

@MainActor
final class PhoneWaveformStore: ObservableObject {
    @Published private(set) var waveform: PhoneWaveformState = .idle
    @Published private(set) var commentsState: PhoneCommentsState = .idle
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var resolvedTrack: Track?

    private var loadedTrackId: String?
    private var task: Task<Void, Never>?

    private static var commentsCache: [String: (state: PhoneCommentsState, comments: [Comment])] = [:]
    private static var trackCache: [String: Track] = [:]

    func ensureLoaded(trackId: String?) {
        guard let trackId else {
            reset()
            return
        }
        guard trackId != loadedTrackId else { return }
        loadedTrackId = trackId
        task?.cancel()

        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_WAVEFORM"],
           let url = URL(string: override) {
            waveform = .loading
            commentsState = .loaded
            task = Task { [weak self] in
                let resolved = await Self.fetchDebugWaveform(from: url)
                guard let self, !Task.isCancelled, self.loadedTrackId == trackId else { return }
                self.waveform = resolved
            }
            return
        }
        #endif

        let cachedTrack = Self.trackCache[trackId]
        let waveformCached = Self.phoneWaveformIfCached(WaveformService.shared.state(for: trackId))
        let commentsCached = Self.commentsCache[trackId]
        waveform = waveformCached ?? .loading
        commentsState = commentsCached?.state ?? .loading
        comments = commentsCached?.comments ?? []
        resolvedTrack = cachedTrack

        guard waveformCached == nil || commentsCached == nil else { return }

        guard SoundCloudCredentialSource.shared.accessToken != nil else {
            if waveformCached == nil {
                waveform = .unavailable("")
            }
            if commentsCached == nil {
                commentsState = .signedOut
            }
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            async let commentsDone: Void = self.loadComments(trackId: trackId, alreadyCached: commentsCached != nil)
            async let waveformDone: Void = self.loadWaveform(trackId: trackId, cachedTrack: cachedTrack, alreadyCached: waveformCached != nil)
            _ = await (commentsDone, waveformDone)
        }
    }

    private func loadComments(trackId: String, alreadyCached: Bool) async {
        guard !alreadyCached else { return }
        do {
            let page = try await SoundCloudAPI.shared.getComments(trackId: trackId)
            guard !Task.isCancelled, loadedTrackId == trackId else { return }
            comments = page.collection
            commentsState = .loaded
        } catch {
            guard !Task.isCancelled, loadedTrackId == trackId else { return }
            commentsState = .failed
        }
        Self.commentsCache[trackId] = (commentsState, comments)
    }

    private func loadWaveform(trackId: String, cachedTrack: Track?, alreadyCached: Bool) async {
        guard !alreadyCached else { return }
        let track: Track?
        if let cachedTrack {
            track = cachedTrack
        } else {
            track = try? await SoundCloudAPI.shared.getTrack(id: trackId)
        }
        guard let track else {
            guard !Task.isCancelled, loadedTrackId == trackId else { return }
            waveform = .unavailable("Waveform unavailable")
            return
        }
        guard !Task.isCancelled, loadedTrackId == trackId else { return }
        resolvedTrack = track
        Self.trackCache[trackId] = track

        let result = await WaveformService.shared.waveform(for: track)
        guard !Task.isCancelled, loadedTrackId == trackId else { return }
        waveform = Self.phoneState(from: result)
    }

    private static func phoneWaveformIfCached(_ state: WaveformState) -> PhoneWaveformState? {
        switch state {
        case .pending, .loading:
            return nil
        case .ready(let waveform):
            return .ready(samples: waveform.samples)
        case .failed(let error):
            return error.isPermanent ? .unavailable(error.errorDescription ?? "Waveform unavailable") : nil
        }
    }

    private static func phoneState(from result: Result<Waveform, WaveformError>) -> PhoneWaveformState {
        switch result {
        case .success(let waveform):
            return .ready(samples: waveform.samples)
        case .failure(let error):
            return .unavailable(error.errorDescription ?? "Waveform unavailable")
        }
    }

    func retry(trackId: String?) {
        guard let trackId else { return }
        loadedTrackId = nil
        WaveformService.shared.invalidate(trackId: trackId)
        Self.commentsCache[trackId] = nil
        ensureLoaded(trackId: trackId)
    }

    private func reset() {
        task?.cancel()
        task = nil
        loadedTrackId = nil
        waveform = .idle
        commentsState = .idle
        comments = []
        resolvedTrack = nil
    }

    var timedComments: [Comment] {
        comments
            .filter { $0.timeInTrack != nil }
            .sorted { ($0.timeInTrack ?? 0) < ($1.timeInTrack ?? 0) }
    }

    #if DEBUG

    private struct DebugWaveformDocument: Decodable {
        let height: Int?
        let samples: [Int]
    }

    nonisolated private static func fetchDebugWaveform(from url: URL) async -> PhoneWaveformState {
        if ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) {
            return .unavailable("Waveform is image-only")
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return .unavailable("Waveform unavailable")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .unavailable("Waveform unavailable")
        }
        guard let document = try? JSONDecoder().decode(DebugWaveformDocument.self, from: data),
              !document.samples.isEmpty else {
            return .unavailable("Waveform couldn't be read")
        }
        return .ready(samples: Waveform(rawSamples: document.samples, height: document.height).samples)
    }
    #endif
}

private struct PhoneWaveformScrubber: View {
    let duration: TimeInterval
    let shown: TimeInterval
    let isPlaying: Bool
    @ObservedObject var store: PhoneWaveformStore
    let accent: Color
    let reduceMotion: Bool
    let onDrag: (TimeInterval) -> Void
    let onCommit: (TimeInterval) -> Void
    let onSeekToComment: (TimeInterval) -> Void
    let trackId: String?
    @ObservedObject var cueBoard: CueBoard
    let onSeekToCue: (TimeInterval) -> Void

    @Environment(\.soundingReducedResourceUsage) private var reducedResourceUsage

    @State private var bars: [Float] = []
    @State private var clusters: [SCCommentCluster] = []
    @State private var isDragging = false
    @State private var markerHaptic = 0
    @State private var lastScrubTarget: TimeInterval?
    @State private var dragBasePosition: TimeInterval = 0
    @State private var dragStartX: CGFloat = 0
    @State private var dragRate: Double = 1.0
    @State private var scrubRateLabel: String = ""
    @State private var scrubZoneTick = 0

    // The waveform is the primary seek control, not a decorative progress
    // strip. Give it enough vertical resolution to read musical shape and to
    // make precise scrubbing comfortable on larger iPhones and iPad.
    private static let laneHeight: CGFloat = 118
    private static let railMetrics = SCCommentRailMetrics.phoneRail
    private static let bubbleHeight: CGFloat = 62

    private static let barPitch: CGFloat = 3
    private static let barGap: CGFloat = 1.5

    private struct BarsKey: Equatable {
        let waveform: PhoneWaveformState
        let widthBucket: Int
    }
    private struct ClustersKey: Equatable {
        let commentCount: Int
        let widthBucket: Int
    }

    private var displayedProgress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, shown / duration))
    }

    private var vividAccent: Color {
        SCAmbient.accent(
            from: accent,
            on: Color(rgb: SCAmbient.composite(
                SCAmbient.RGB(r: 1, g: 1, b: 1),
                alpha: 0.30,
                over: SCAmbient.components(.scAmbientFallback)
            ))
        )
    }

    private var railStyle: SCContentStyle {
        var style = SCContentStyle.phone
        style.accent = vividAccent
        return style
    }

    private var laneStyle: SCWaveformStyle {
        var style = SCWaveformStyle.phone
        style.barPitch = Self.barPitch
        style.barGap = Self.barGap
        style.barCornerRadius = Self.barPitch / 2
        let fill = vividAccent
        style.playedShellColors = [fill]
        style.playedSheen = [fill.opacity(0.92), fill, fill.opacity(0.78)]
        style.glowColor = fill
        if isDragging {
            style.unplayedSheen = [.white.opacity(0.38), .white.opacity(0.13)]
        }
        return style
    }

    private var placeholderKind: SCWaveformPlaceholder {
        switch store.waveform {
        case .idle, .loading:     return .loading
        case .ready(let samples): return samples.isEmpty ? .unavailable : .loading
        case .unavailable:        return .unavailable
        }
    }

    private var activeCluster: SCCommentCluster? {
        SCCommentTimeline.active(in: clusters, at: shown)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PulseTimeline(
                        isActive: isPlaying && !reducedResourceUsage && !bars.isEmpty,
                        reduceMotion: reduceMotion
                    ) { pulse in
                        SCWaveformRenderer(
                            envelope: bars,
                            duration: duration,
                            progress: displayedProgress,
                            playheadEmphasis: Double(pulse.impact),
                            pulseEnergy: Double(pulse.energy),
                            placeholder: placeholderKind,
                            identity: trackId,
                            motionSuppressed: reducedResourceUsage,
                            style: laneStyle
                        )
                        .frame(width: width, height: activeLaneHeight)
                    }
                }
                .frame(width: width, height: activeLaneHeight)
                .overlay(alignment: .top) { scrubRateBadge(width: width) }
                .overlay(alignment: .bottom) { waveformNotice(width: width) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragBasePosition = fraction(for: value.startLocation.x, width: width) * duration
                                dragStartX = value.startLocation.x
                                dragRate = 1.0
                                scrubRateLabel = ""
                            }
                            let (rate, label) = Self.scrubRate(
                                forVerticalOffset: value.location.y - value.startLocation.y
                            )
                            if label != scrubRateLabel {
                                let boundary = scrubTarget(for: value, width: width, rate: dragRate, duration: duration)
                                dragBasePosition = boundary
                                dragStartX = value.location.x
                                dragRate = rate
                                scrubRateLabel = label
                                scrubZoneTick += 1
                            } else {
                                dragRate = rate
                            }
                            let target = scrubTarget(for: value, width: width, rate: dragRate, duration: duration)
                            // Haptic tick each time the drag crosses a comment marker (§4.1).
                            if crossedCommentMarker(from: lastScrubTarget ?? target, to: target) {
                                markerHaptic += 1
                            }
                            lastScrubTarget = target
                            onDrag(target)
                        }
                        .onEnded { value in
                            isDragging = false
                            scrubRateLabel = ""
                            lastScrubTarget = nil
                            onCommit(scrubTarget(for: value, width: width, rate: dragRate, duration: duration))
                        }
                )

                if showsCommentRail {
                    markerRail(width: width)
                }
                if showsCueRail {
                    cueMarkerRail(width: width)
                }
                if showsCommentRail {
                    commentBubble(width: width)
                }
            }
            .task(id: BarsKey(waveform: store.waveform, widthBucket: Int(width / 4))) {
                recomputeBars(width: width)
            }
            .task(id: ClustersKey(commentCount: store.timedComments.count, widthBucket: Int(width / 4))) {
                recomputeClusters(width: width)
            }
        }
        .frame(height: timelineHeight)
        .scrollClipDisabled()
        .animation(.scMotion(SCContentMotion.press, reduceMotion: reduceMotion), value: isDragging)
        .sensoryFeedback(.selection, trigger: isDragging)
        .sensoryFeedback(.selection, trigger: scrubZoneTick)
        .sensoryFeedback(.impact(weight: .light), trigger: markerHaptic)
    }

    private var showsCommentRail: Bool { !clusters.isEmpty }

    private var showsCueRail: Bool { !cueBoard.sheet.entries.isEmpty }

    private var activeLaneHeight: CGFloat {
        bars.isEmpty && Self.notice(for: store.waveform) != nil ? 58 : Self.laneHeight
    }

    private var timelineHeight: CGFloat {
        activeLaneHeight
            + (showsCommentRail ? Self.railMetrics.railHeight : 0)
            + (showsCueRail ? PhoneNowPlaying.cueRail : 0)
            + (showsCommentRail ? Self.bubbleHeight : 0)
    }

    private func crossedCommentMarker(from: TimeInterval, to: TimeInterval) -> Bool {
        guard from != to else { return false }
        let lower = min(from, to)
        let upper = max(from, to)
        return clusters.contains { $0.time > lower && $0.time <= upper }
    }

    @ViewBuilder
    private func waveformNotice(width: CGFloat) -> some View {
        if bars.isEmpty, let notice = Self.notice(for: store.waveform) {
            Text(notice)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: width, alignment: .center)
        }
    }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        Double(min(1, max(0, x / max(width, 1))))
    }

    private func scrubTarget(
        for value: DragGesture.Value, width: CGFloat, rate: Double, duration: TimeInterval
    ) -> TimeInterval {
        guard width > 0 else { return dragBasePosition }
        let dx = value.location.x - dragStartX
        let candidate = dragBasePosition + Double(dx / width) * duration * rate
        return min(duration, max(0, candidate))
    }

    private static func scrubRate(forVerticalOffset dy: CGFloat) -> (rate: Double, label: String) {
        let distance = abs(dy)
        if distance > 148 { return (0.06, "Fine Scrubbing") }
        if distance > 100 { return (0.25, "Quarter-Speed") }
        if distance > 52 { return (0.5, "Half-Speed") }
        return (1.0, "")
    }

    private func recomputeBars(width: CGFloat) {
        guard let samples = store.waveform.samples, !samples.isEmpty, width > 0 else {
            bars = []
            return
        }
        let totalPitch = Self.barPitch + Self.barGap
        let count = max(1, Int(width / totalPitch))
        bars = Waveform(samples: samples).displayBars(count: count)
    }

    private func recomputeClusters(width: CGFloat) {
        clusters = SCCommentTimeline.clusters(
            from: CommentThreadBuilder.build(store.comments).timed,
            duration: duration,
            width: width,
            metrics: Self.railMetrics
        )
    }

    // §4.1 bubble: below the rail, glass (chrome over content), width
    // min(300, width − 48), accent 0.16 tint, connector tick up at its marker.
    @ViewBuilder
    private func commentBubble(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let cluster = activeCluster {
                let bubbleWidth = min(300, width - 48)
                let markerX = CGFloat(cluster.fraction(in: duration)) * width
                let centerX = min(max(markerX, bubbleWidth / 2), max(bubbleWidth / 2, width - bubbleWidth / 2))
                let tickX = markerX - (centerX - bubbleWidth / 2)

                SCCommentBubble(
                    cluster: cluster,
                    style: railStyle,
                    tickOffset: tickX
                )
                .frame(width: bubbleWidth)
                .offset(x: centerX - bubbleWidth / 2)
                .id(cluster.id)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.9, anchor: .top).combined(with: .opacity)
                )
            }
        }
        .frame(width: width, height: Self.bubbleHeight, alignment: .topLeading)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: activeCluster?.id)
        .allowsHitTesting(false)
    }

    private static func notice(for state: PhoneWaveformState) -> String? {
        switch state {
        case .idle, .loading:       return nil
        case .ready(let samples):   return samples.isEmpty ? "Waveform is empty" : nil
        case .unavailable(let why):
            let notice = why.trimmingCharacters(in: .whitespacesAndNewlines)
            return notice.isEmpty ? nil : notice
        }
    }

    @ViewBuilder
    private func markerRail(width: CGFloat) -> some View {
        SCCommentRail(
            clusters: clusters,
            duration: duration,
            playhead: shown,
            activeClusterID: activeCluster?.id,
            style: railStyle,
            reduceMotion: reduceMotion,
            railMetrics: Self.railMetrics,
            onSelect: { cluster in
                markerHaptic += 1
                onSeekToComment(cluster.time)
            }
        )
        .frame(width: width, height: Self.railMetrics.railHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func cueMarkerRail(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: PhoneNowPlaying.cueRail)

            ForEach(cueBoard.sheet.entries) { entry in
                CueMarkerChip(
                    entry: entry,
                    x: xPosition(for: entry.positionSeconds, width: width),
                    width: width,
                    duration: duration,
                    onSeek: { time in
                        markerHaptic += 1
                        onSeekToCue(time)
                    },
                    onReposition: { newSeconds in
                        guard case .user(let cue) = entry else { return }
                        Task { await cueBoard.reposition(cue, toMillis: CueTime.millis(fromSeconds: newSeconds)) }
                    }
                )
            }
        }
        .frame(width: width, height: PhoneNowPlaying.cueRail, alignment: .topLeading)
    }

    @ViewBuilder
    private func scrubRateBadge(width: CGFloat) -> some View {
        if !scrubRateLabel.isEmpty {
            Text(scrubRateLabel.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(vividAccent))
                .frame(width: width, alignment: .center)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                .animation(.scMotion(SCContentMotion.focus, reduceMotion: reduceMotion), value: scrubRateLabel)
                .allowsHitTesting(false)
        }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / duration))) * width
    }
}

private struct CueMarkerChip: View {
    let entry: ResolvedCue
    let x: CGFloat
    let width: CGFloat
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onReposition: (TimeInterval) -> Void

    @GestureState private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    private var canDrag: Bool { !entry.isSuggestion }

    var body: some View {
        Group {
            if entry.isSuggestion {
                Circle()
                    .strokeBorder(entry.color.color.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(entry.color.color)
                    .frame(width: 12, height: 12)
            }
        }
        .scaleEffect(isDragging ? 1.5 : 1)
        .frame(width: 32, height: PhoneNowPlaying.cueRail)
        .contentShape(Rectangle())
        .offset(x: x + (canDrag ? dragTranslation : 0) - 16, y: 0)
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($dragTranslation) { value, state, _ in
                    guard canDrag else { return }
                    state = value.translation.width
                }
                .onChanged { _ in
                    guard canDrag else { return }
                    isDragging = true
                }
                .onEnded { value in
                    guard canDrag else { return }
                    isDragging = false
                    let newX = x + value.translation.width
                    onReposition(Double(min(1, max(0, newX / max(width, 1)))) * duration)
                }
        )
        .onTapGesture { onSeek(entry.positionSeconds) }
        .animation(SCContentMotion.focus, value: isDragging)
        .accessibilityLabel(entry.isSuggestion ? "Suggested cue at \(scFormatTime(entry.positionSeconds))" : "Cue at \(scFormatTime(entry.positionSeconds))")
    }
}

private struct TransportBarPreview: View {
    @Namespace private var namespace

    var body: some View {
        TransportBarView(
            isExpanded: .constant(false),
            heroID: "preview.transportHero",
            heroNamespace: namespace
        )
        .environmentObject(PhonePlaybackCoordinator(client: CompanionClient()))
        .padding()
        .background(Color.scBackgroundGradient)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    TransportBarPreview()
}
