import SwiftUI
import Foundation
import CoreImage
import UIKit
import MediaPlayer

private struct MiniBarSurfaceModifier: ViewModifier {
    let isInline: Bool
    let isScrubbing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isScrubbing && !isInline {
            content.glassEffect(.regular, in: .rect(cornerRadius: PhoneRadius.card, style: .continuous))
        } else {
            content
        }
    }
}

@MainActor
private enum MiniBarAppearance {
    static func systemScheme(fallback: ColorScheme) -> ColorScheme {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        switch scene?.traitCollection.userInterfaceStyle {
        case .dark: return .dark
        case .light: return .light
        default: return fallback
        }
    }
}

private enum MiniBarSpan: Int, Comparable {
    case compact
    case wide
    case roomy

    private static let wideWidth: CGFloat = 520
    private static let roomyWidth: CGFloat = 640
    private static let slack: CGFloat = 24

    static func < (lhs: MiniBarSpan, rhs: MiniBarSpan) -> Bool { lhs.rawValue < rhs.rawValue }

    func settled(for width: CGFloat) -> MiniBarSpan {
        let raw: MiniBarSpan = width >= Self.roomyWidth ? .roomy : (width >= Self.wideWidth ? .wide : .compact)
        guard raw < self else { return raw }
        let floor = self == .roomy ? Self.roomyWidth : Self.wideWidth
        return width >= floor - Self.slack ? self : raw
    }
}

private struct MiniBarHeroSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let isActive: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}

struct TransportBarView: View {
    @Binding var isExpanded: Bool
    let heroID: String
    let heroNamespace: Namespace.ID

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var palette = NowPlayingPalette.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var listenTogether = ListenTogether.shared
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var continueFrom = ContinueFrom.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    @State private var miniWaveformStore = PhoneWaveformStore()
    @State private var miniScrubActive = false
    @State private var miniScrubPosition: TimeInterval?
    @State private var miniBarWidth: CGFloat = 720
    @State private var miniBarSpan: MiniBarSpan = .roomy
    @State private var scrubFeedbackTick = false
    @State private var offerArrived = false
    @State private var transportTick = false
    private let likes = NowPlayingLikeModel.shared
    @State private var outputFailure: String?
    @State private var showingConnect = false
    @State private var showingAutoMixStart = false
    @State private var popoverArtist: User?
    @Environment(\.presentArtist) private var presentArtist

    private var effectivePlacement: TabViewBottomAccessoryPlacement? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_ACCESSORY"] == "inline" {
            return .inline
        }
        #endif
        return accessoryPlacement
    }

    private var isInline: Bool { effectivePlacement == .inline }

    private var isWide: Bool {
        PadLayout.isPad && !isInline && (horizontalSizeClass == .regular || miniBarSpan >= .wide)
    }

    private var showsModeButtons: Bool {
        miniBarSpan == .roomy && dynamicTypeSize < .xLarge
    }

    private var barColorScheme: ColorScheme {
        guard PadLayout.isPad, horizontalSizeClass == .regular, !isInline else { return colorScheme }
        return MiniBarAppearance.systemScheme(fallback: colorScheme)
    }

    private var wideArtSize: CGFloat { 40 }

    private var wideIdentityInset: CGFloat { miniBarSpan == .roomy ? 20 : 10 }

    @MainActor private static var arrivedOfferID: String?

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = coordinator.nowPlaying {
                Group {
                    if miniScrubActive {
                        miniScrubBar(snapshot)
                    } else if isWide {
                        miniBarWide(snapshot)
                    } else if isInline {
                        miniBarInline(snapshot)
                    } else {
                        miniBarExpanded(snapshot)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(HierarchicalShapeStyle.primary)
                .tint(Color.primary)
                .padding(.horizontal, Space.tight)
                .padding(.vertical, isInline ? 4 : 2)
                .modifier(MiniBarSurfaceModifier(isInline: isInline, isScrubbing: miniScrubActive))
                .contentShape(miniBarShape)
                .onTapGesture { expand() }
                .contentShape(.contextMenuPreview, miniBarShape)
                .contextMenu { miniMenu(snapshot) }
                .simultaneousGesture(miniScrubGesture(snapshot))
                .simultaneousGesture(swipeUpGesture)
                .animation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion), value: miniScrubActive)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: snapshot))
                .accessibilityHint("Opens Now Playing")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { expand() }
                .accessibilityAction(named: snapshot.showsPauseGlyph ? "Pause" : "Play") { coordinator.togglePlayPause() }
                .accessibilityAction(named: "Next Track") { coordinator.next() }
                .accessibilityAction(named: "Previous Track") { coordinator.previous() }
                .accessibilityAction(named: "Open Now Playing") { expand() }
                .accessibilityAction(named: "Lyrics") { open(.lyrics) }
                .accessibilityAction(named: "Up Next") { open(.upNext) }
            } else {
                notPlayingBar
            }
        }
        .foregroundStyle(HierarchicalShapeStyle.primary)
        .tint(Color.primary)
        .environment(\.colorScheme, barColorScheme)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            miniBarWidth = max(1, width)
            let span = miniBarSpan.settled(for: width)
            if span != miniBarSpan { miniBarSpan = span }
        }
        .onChange(of: coordinator.nowPlaying?.artworkURL, initial: true) { _, urlString in
            let url = urlString.flatMap(URL.init)
            palette.update(for: url, reduceMotion: reduceMotion)
            ArtworkColors.shared.update(for: url)
        }
        .onChange(of: coordinator.nowPlaying?.trackId, initial: true) { _, trackId in
            miniWaveformStore.ensureLoaded(trackId: trackId, includesComments: false)
            likes.refresh(trackId: trackId, resolved: coordinator.currentTrack)
        }
        .alert("Couldn’t Switch Output", isPresented: Binding(
            get: { outputFailure != nil },
            set: { if !$0 { outputFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outputFailure ?? "")
        }
        .onChange(of: credentials.sessionHealth.canMakeAuthenticatedRequests) { _, canLoad in
            guard canLoad else { return }
            miniWaveformStore.ensureLoaded(trackId: coordinator.nowPlaying?.trackId, includesComments: false)
        }
        .onChange(of: isExpanded, initial: true) { _, _ in
            resetMiniInteractionState()
        }
        .popover(isPresented: $showingConnect, arrowEdge: .bottom) {
            ConnectSheet(onDone: { showingConnect = false })
                .environmentObject(coordinator)
                .frame(idealWidth: 420, idealHeight: 620)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
        }
        .popover(item: $popoverArtist, arrowEdge: .bottom) { artist in
            NavigationStack {
                ArtistDetailView(user: artist)
            }
            .frame(idealWidth: 520, idealHeight: 760)
            .addToPlaylistHost()
            .presentationCompactAdaptation(.sheet)
        }
        .sheet(isPresented: $showingAutoMixStart) {
            AutoDJStartConfigurationView { configuration in
                coordinator.startDJSession(configuration: configuration)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
        .sensoryFeedback(.selection, trigger: scrubFeedbackTick)
        .sensoryFeedback(.impact(weight: .light), trigger: transportTick)
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_NOW_PLAYING_EXPANDED"] == "1" else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            expand()
        }
        .task(id: coordinator.nowPlaying?.trackId) {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_SCRUB"] == "1",
                  coordinator.nowPlaying != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            beginMiniScrub()
        }
        #endif
    }

    private var miniBarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: miniScrubActive ? PhoneRadius.card : 100, style: .continuous)
    }

    // MARK: - Opening

    private func expand() {
        guard coordinator.nowPlaying != nil, !isExpanded, !miniScrubActive else {
            NowPlayingLaunch.pane = nil
            return
        }
        withAnimation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion)) { isExpanded = true }
    }

    private func open(_ pane: NowPlayingPane) {
        NowPlayingLaunch.pane = pane
        expand()
    }

    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onEnded { value in
                let rise = -value.translation.height
                let drift = abs(value.translation.width)
                guard rise > drift * 1.2 else { return }
                guard rise > 18 || -value.predictedEndTranslation.height > 60 else { return }
                expand()
            }
    }

    // MARK: - Layouts

    private func miniBarWide(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                if showsModeButtons { shuffleButton }
                transportButton("backward.fill", label: "Previous Track") { coordinator.previous() }
                miniPlayButton(snapshot, font: .title, side: 48)
                transportButton("forward.fill", label: "Next Track") { coordinator.next() }
                if showsModeButtons { repeatButton }
            }
            .fixedSize()

            Button {
                expand()
            } label: {
                identityContent(
                    identity: snapshot.trackId ?? snapshot.displayTitle,
                    title: snapshot.displayTitle,
                    artist: snapshot.failureMessage ?? subtitle(for: snapshot),
                    artworkURL: snapshot.artworkURL,
                    companionGlyph: outputGlyph(for: snapshot),
                    isFailure: snapshot.failureMessage != nil,
                    artSize: wideArtSize,
                    isHeroSource: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, wideIdentityInset)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                moreMenu(snapshot)
                if !setlists.isMix(trackID: snapshot.trackId, title: snapshot.title, duration: snapshot.duration) {
                    paneButton(.lyrics, systemImage: "quote.bubble")
                }
                paneButton(.upNext, systemImage: "list.bullet")
            }
            .fixedSize()
        }
        .foregroundStyle(.primary)
    }

    private func miniBarExpanded(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 8) {
            identityCarousel(snapshot)

            Spacer(minLength: Space.hair)

            miniTransportButtons(snapshot)
        }
        .contentShape(miniBarShape)
    }

    private func miniBarInline(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                expand()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    miniArtwork(
                        snapshot.artworkURL,
                        identity: snapshot.trackId ?? snapshot.displayTitle,
                        artist: snapshot.displayArtist,
                        size: 30,
                        isHeroSource: true
                    )
                    if snapshot.failureMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .symbolRenderingMode(.multicolor)
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: Spacing.sm)

            miniPlayButton(snapshot, font: .body)
        }
    }

    @ViewBuilder
    private var notPlayingBar: some View {
        if let pending = coordinator.continueOffer(from: continueFrom) {
            offerBar(pending.offer, isLoading: pending.isLoading)
        } else {
            idleBar
        }
    }

    private func hasArrived(_ offer: ContinueFrom.Offer) -> Bool {
        offerArrived || Self.arrivedOfferID == offer.id
    }

    private func offerBar(_ offer: ContinueFrom.Offer, isLoading: Bool) -> some View {
        let size: CGFloat = isWide ? wideArtSize : (isInline ? 30 : 38)
        let title = offer.session.title.isEmpty ? "Continue from \(offer.deviceName)" : offer.session.title
        return HStack(spacing: isInline ? Spacing.sm : 11) {
            miniArtwork(
                offer.session.artworkURL?.absoluteString,
                identity: offer.session.trackID,
                artist: offer.session.artist,
                size: size
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !isInline {
                    Label {
                        Text(offer.miniCaption)
                    } icon: {
                        Image(systemName: offer.session.deviceClass.symbolName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLoading {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Button {
                    continueFrom.accept(offer, play: true)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.primary)
                .buttonBorderShape(.circle)
                .controlSize(isInline ? .small : .regular)
                .accessibilityLabel("Play Here")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, Space.tight)
        .padding(.vertical, isInline ? 4 : 2)
        .contentShape(miniBarShape)
        .onTapGesture {
            guard !isLoading else { return }
            continueFrom.accept(offer, expand: true)
        }
        .contentShape(.contextMenuPreview, miniBarShape)
        .contextMenu {
            if !isLoading {
                Button { continueFrom.dismiss(offer) } label: {
                    Label("Not Now", systemImage: "xmark")
                }
            }
        }
        .opacity(hasArrived(offer) ? 1 : 0)
        .offset(y: hasArrived(offer) || reduceMotion ? 0 : 8)
        .onAppear {
            guard Self.arrivedOfferID != offer.id else {
                offerArrived = true
                return
            }
            Self.arrivedOfferID = offer.id
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.4)) { offerArrived = true }
        }
        .onDisappear { offerArrived = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(offer.miniCaption)")
        .accessibilityHint("Opens Now Playing, paused")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !isLoading { continueFrom.accept(offer, expand: true) } }
        .accessibilityAction(named: "Play Here") { if !isLoading { continueFrom.accept(offer, play: true) } }
        .accessibilityAction(named: "Not Now") { if !isLoading { continueFrom.dismiss(offer) } }
    }

    private var idleBar: some View {
        HStack(spacing: 0) {
            if isWide {
                HStack(spacing: 2) {
                    if showsModeButtons { idleGlyph("shuffle", font: .body, width: 40) }
                    idleGlyph("backward.fill", font: .title2, width: 44)
                    idleGlyph("play.fill", font: .title, width: 48)
                    idleGlyph("forward.fill", font: .title2, width: 44)
                    if showsModeButtons { idleGlyph("repeat", font: .body, width: 40) }
                }
                .fixedSize()
            }

            HStack(spacing: isInline ? Spacing.sm : 11) {
                notPlayingArtwork(size: isWide ? wideArtSize : (isInline ? 30 : 38))
                if !isInline {
                    Text("Not Playing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, isWide ? wideIdentityInset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isWide {
                HStack(spacing: 2) {
                    idleGlyph("ellipsis", font: .title3, width: 44)
                    idleGlyph("quote.bubble", font: .title3, width: 44)
                    idleGlyph("list.bullet", font: .title3, width: 44)
                }
                .fixedSize()
            } else {
                idleGlyph("play.fill", font: isInline ? .body : .title3, width: 44)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, Space.tight)
        .padding(.vertical, isInline ? 4 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not Playing")
    }

    private func idleGlyph(_ systemImage: String, font: Font, width: CGFloat) -> some View {
        Image(systemName: systemImage)
            .font(font.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, height: 44)
    }

    private func notPlayingArtwork(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: artCornerRadius(size), style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
    }

    private func miniScrubBar(_ snapshot: NowPlayingSnapshot) -> some View {
        let shown = miniScrubPosition ?? coordinator.timeline.anchor.position(at: .now)
        return VStack(spacing: 5) {
            HStack(spacing: Spacing.sm) {
                miniArtwork(snapshot.artworkURL, identity: snapshot.trackId ?? snapshot.displayTitle, artist: snapshot.displayArtist, size: 28)
                Text(snapshot.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text("\(scFormatTime(shown)) / \(scFormatTime(snapshot.duration))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            MiniWaveformLaneView(
                timeline: coordinator.timeline,
                waveform: miniWaveformStore.waveform,
                accent: palette.current.accent,
                scrubPosition: miniScrubPosition
            )
            .frame(height: 34)
        }
        .padding(.horizontal, Space.tight)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Menu

    @ViewBuilder
    private func miniMenu(_ snapshot: NowPlayingSnapshot) -> some View {
        let track = coordinator.currentTrack
        if let track {
            Section {
                Button { open(.about) } label: {
                    Label("Behind the Track", systemImage: "info.circle")
                }
                Button { coordinator.playNext(track) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                if track.supportsSoundCloudActions {
                    Button { likes.toggle(trackId: track.id, resolved: track) } label: {
                        if likes.isLiked(track.id, resolved: track) {
                            Label("Remove from Likes", systemImage: "heart.slash")
                        } else {
                            Label("Add to Likes", systemImage: "heart")
                        }
                    }
                }
                AddToPlaylistMenuButton(track: track)
                StartStationMenuButton(track: track)
                Button {
                    if PadLayout.isPad { popoverArtist = track.user } else { presentArtist(track.user) }
                } label: {
                    Label("Go to Artist", systemImage: "person.crop.circle")
                }
                if track.supportsSoundCloudActions {
                    ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        Section {
            Toggle(isOn: Binding(
                get: { isAutoMixOn && !listenTogether.isActive },
                set: { setAutoMix($0) }
            )) {
                Label("Auto Mix", systemImage: "infinity")
                if listenTogether.isActive {
                    Text("Off during SharePlay")
                }
            }
            .disabled(listenTogether.isActive)
        }
        Section {
            Button { showingConnect = true } label: {
                Text("Play On…")
                Text(coordinator.currentOutput.name)
                Image(systemName: coordinator.currentOutput.isLocal ? "airplay.audio" : coordinator.currentOutput.symbolName)
            }
        }
    }

    private func moreMenu(_ snapshot: NowPlayingSnapshot) -> some View {
        Menu {
            miniMenu(snapshot)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
    }

    private var isAutoMixOn: Bool {
        coordinator.djSnapshot.isAutoEnabled
    }

    private func setAutoMix(_ isOn: Bool) {
        if isOn {
            if coordinator.djSnapshot.isEngineLive {
                coordinator.setAutoMixEnabled(true)
            } else {
                showingAutoMixStart = true
            }
        } else {
            coordinator.setDJEnabled(false)
            coordinator.setAutoMixEnabled(false)
        }
    }

    // MARK: - Identity

    private func identityCarousel(_ snapshot: NowPlayingSnapshot) -> some View {
        SkipCarousel(
            current: PhonePlaybackCoordinator.SkipPreview(
                title: snapshot.displayTitle,
                artist: snapshot.failureMessage ?? subtitle(for: snapshot),
                artworkURL: snapshot.artworkURL,
                trackID: snapshot.trackId
            ),
            currentID: snapshot.trackId ?? snapshot.displayTitle,
            previous: coordinator.previousSkipPreview,
            next: coordinator.nextSkipPreview,
            commitThreshold: 0.2,
            isEnabled: !miniScrubActive,
            onCommit: { edge in
                transportTick.toggle()
                if edge == .trailing { coordinator.next() } else { coordinator.previous() }
            }
        ) { preview, isCurrent in
            Button {
                expand()
            } label: {
                identityContent(
                    identity: preview.trackID ?? preview.title,
                    title: preview.title,
                    artist: preview.artist,
                    artworkURL: preview.artworkURL,
                    companionGlyph: outputGlyph(for: snapshot),
                    isFailure: isCurrent && snapshot.failureMessage != nil,
                    artSize: 38,
                    isHeroSource: isCurrent
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputGlyph(for snapshot: NowPlayingSnapshot) -> String? {
        if let glyph = snapshot.source.deviceClassIfRemote?.symbolName { return glyph }
        return coordinator.currentOutput.isLocal ? nil : coordinator.currentOutput.symbolName
    }

    private func remoteOutputName(for snapshot: NowPlayingSnapshot) -> String? {
        if snapshot.source.deviceClassIfRemote != nil { return snapshot.source.name }
        return coordinator.currentOutput.isLocal ? nil : coordinator.currentOutput.name
    }

    private func subtitle(for snapshot: NowPlayingSnapshot) -> String {
        guard let name = remoteOutputName(for: snapshot) else { return snapshot.displayArtist }
        return "Playing on \(name)"
    }

    private func identityContent(
        identity: String,
        title: String,
        artist: String,
        artworkURL: String?,
        companionGlyph: String?,
        isFailure: Bool,
        artSize: CGFloat,
        isHeroSource: Bool
    ) -> some View {
        HStack(spacing: 11) {
            miniArtwork(artworkURL, identity: identity, artist: artist, size: artSize, isHeroSource: isHeroSource)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                    } else if let companionGlyph {
                        Image(systemName: companionGlyph)
                            .font(.caption2.weight(.semibold))
                    }
                    if isAutoMixOn, !isFailure, isHeroSource {
                        Image(systemName: "infinity")
                            .font(.caption2.weight(.bold))
                    }
                    Text(artist)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(isFailure ? AnyShapeStyle(Color.orange) : (companionGlyph != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityLabel(for snapshot: NowPlayingSnapshot) -> String {
        var label = "Now Playing, \(snapshot.displayTitle) by \(snapshot.displayArtist)"
        if let name = remoteOutputName(for: snapshot) { label += ", on \(name)" }
        if snapshot.isLoading {
            label += ", loading"
        } else if !snapshot.showsPauseGlyph {
            label += ", paused"
        }
        if isAutoMixOn { label += ", Auto Mix on" }
        if let failure = snapshot.failureMessage { label += ", \(failure)" }
        return label
    }

    // MARK: - Buttons

    private func miniPlayButton(_ snapshot: NowPlayingSnapshot, font: Font, side: CGFloat = 44) -> some View {
        Button {
            coordinator.togglePlayPause()
        } label: {
            PlayPauseGlyph(isPlaying: snapshot.showsPauseGlyph, font: font)
                .frame(width: side, height: max(44, side))
                .contentShape(.circle)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(snapshot.isLoading ? "Loading" : (snapshot.showsPauseGlyph ? "Pause" : "Play"))
        .sensoryFeedback(.impact(weight: .medium), trigger: snapshot.isPlaying)
    }

    private func transportButton(
        _ systemImage: String, label: String, font: Font = .title2, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            transportTick.toggle()
        } label: {
            Image(systemName: systemImage)
                .font(font.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    private var shuffleButton: some View {
        let isOn = coordinator.isShuffleEnabled
        return Button {
            coordinator.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .disabled(!coordinator.canChangePlaybackModes)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel("Shuffle")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var repeatButton: some View {
        let mode = coordinator.repeatMode
        return Button {
            coordinator.cycleRepeatMode()
        } label: {
            Image(systemName: mode.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(mode.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .disabled(!coordinator.canChangePlaybackModes)
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityLabel("Repeat")
        .accessibilityValue(repeatValue(mode))
    }

    private func repeatValue(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    private func paneButton(_ pane: NowPlayingPane, systemImage: String) -> some View {
        Button {
            open(pane)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(pane.rawValue)
    }

    private func miniTransportButtons(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 0) {
            miniPlayButton(snapshot, font: .title3)
            transportButton("forward.fill", label: "Next Track", font: .title3) { coordinator.next() }
        }
        .foregroundStyle(.primary)
    }

    private func artCornerRadius(_ size: CGFloat) -> CGFloat {
        size >= 36 ? 8 : 6
    }

    private func miniArtwork(
        _ urlString: String?, identity: String, artist: String?, size: CGFloat = 44, isHeroSource: Bool = false
    ) -> some View {
        let radius = artCornerRadius(size)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return MiniArtworkTile(url: Self.thumbnailURL(urlString), identity: identity)
            .frame(width: size, height: size)
            .background(.primary.opacity(0.08), in: shape)
            .clipShape(shape)
            .modifier(MiniBarHeroSource(id: heroID, namespace: heroNamespace, isActive: isHeroSource, cornerRadius: radius))
            .kyleCrowned(user: nil, context: artist)
    }

    fileprivate static func thumbnailURL(_ urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return url.soundCloudArtworkVariant("t200x200")
    }

    // MARK: - Mini scrub

    private func miniScrubGesture(_ snapshot: NowPlayingSnapshot) -> some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 18)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { phase in
                switch phase {
                case .second(true, let drag):
                    guard let drag else { break }
                    if !miniScrubActive, abs(drag.translation.width) > 6 { beginMiniScrub() }
                    if miniScrubActive { updateMiniScrub(at: drag.location.x, duration: snapshot.duration) }
                default:
                    break
                }
            }
            .onEnded { phase in
                switch phase {
                case .second(true, let drag):
                    guard miniScrubActive else { break }
                    if let drag { updateMiniScrub(at: drag.location.x, duration: snapshot.duration) }
                    if let target = miniScrubPosition { coordinator.seek(to: target) }
                default:
                    break
                }
                endMiniScrub()
            }
    }

    private func beginMiniScrub() {
        guard !isExpanded, !miniScrubActive else { return }
        miniScrubPosition = coordinator.timeline.anchor.position(at: .now)
        withAnimation(reduceMotion ? nil : SCContentMotion.settle) {
            miniScrubActive = true
        }
        scrubFeedbackTick.toggle()
    }

    private func updateMiniScrub(at x: CGFloat, duration: TimeInterval) {
        let fraction = Double(min(1, max(0, x / max(miniBarWidth, 1))))
        miniScrubPosition = fraction * max(0, duration)
    }

    private func endMiniScrub() {
        withAnimation(reduceMotion ? nil : SCContentMotion.settle) {
            miniScrubActive = false
        }
        miniScrubPosition = nil
    }

    private func resetMiniInteractionState() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            miniScrubActive = false
            miniScrubPosition = nil
        }
    }
}

private struct MiniArtworkTile: View {
    let url: URL?
    let identity: String

    @State private var image: UIImage?
    @State private var loadedFor: URL?

    private var displayed: UIImage? {
        if loadedFor == url, let image { return image }
        guard let url else { return nil }
        return ArtworkCache.shared.bestCachedImage(for: url, variant: .thumbnail) ?? image
    }

    var body: some View {
        ZStack {
            if let displayed {
                Image(uiImage: displayed).resizable().scaledToFill()
            } else {
                SoundingArtworkView(identity: identity)
                    .environment(\.soundingArtworkPending, url != nil && loadedFor != url)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedFor = nil
                return
            }
            if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .thumbnail) {
                image = cached
                loadedFor = url
                return
            }
            let loaded = await ArtworkCache.shared.image(for: url, variant: .thumbnail)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedFor = url
        }
    }
}

struct MiniWaveformLaneView: View {
    let timeline: NowPlayingTimeline
    let waveform: PhoneWaveformState
    let accent: Color
    var scrubPosition: TimeInterval?

    @State private var bars: [Float] = []
    @State private var width: CGFloat = 0

    private struct Key: Equatable {
        let waveform: PhoneWaveformState
        let widthBucket: Int
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: scrubPosition != nil || !timeline.anchor.isAdvancing)) { context in
            let position = scrubPosition ?? timeline.anchor.position(at: context.date)
            let duration = max(timeline.anchor.duration, 1)
            Canvas { graphics, size in
                guard !bars.isEmpty else { return }
                let pitch = size.width / CGFloat(bars.count)
                let barWidth = max(1, pitch * 0.62)
                let mid = size.height / 2
                let playedCount = Int((position / duration * Double(bars.count)).rounded())
                var played = Path()
                var unplayed = Path()
                for (index, bar) in bars.enumerated() {
                    let half = max(1, CGFloat(bar) * (mid - 2))
                    let rect = CGRect(x: CGFloat(index) * pitch, y: mid - half, width: barWidth, height: half * 2)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    if index < playedCount { played.addPath(path) } else { unplayed.addPath(path) }
                }
                graphics.fill(unplayed, with: .color(.primary.opacity(0.24)))
                graphics.fill(played, with: .color(accent))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: Key(waveform: waveform, widthBucket: Int(width / 3.5))) {
            guard let samples = waveform.samples, !samples.isEmpty, width > 0 else {
                bars = []
                return
            }
            let count = max(1, Int(width / 3.5))
            bars = await Task.detached(priority: .userInitiated) {
                Waveform(samples: SCWaveformSampler.visuallyNormalized(samples)).displayBars(count: count)
            }.value
        }
        .accessibilityHidden(true)
    }
}

func scFormatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours > 0 else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
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
        guard let (data, _) = try? await URLSession.shared.loggedData(from: url, feature: .artwork),
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
    private static let cacheLimit = 48
    private static let maxCommentPages = 6

    private static func trimCaches(keeping trackId: String) {
        if commentsCache.count > cacheLimit {
            let kept = commentsCache[trackId]
            commentsCache.removeAll(keepingCapacity: true)
            commentsCache[trackId] = kept
        }
        if trackCache.count > cacheLimit {
            let kept = trackCache[trackId]
            trackCache.removeAll(keepingCapacity: true)
            trackCache[trackId] = kept
        }
    }

    func ensureLoaded(trackId: String?, includesComments: Bool = true) {
        guard let trackId else {
            reset()
            return
        }
        let hasCredential = SoundCloudCredentialSource.shared.accessToken != nil
        if trackId == loadedTrackId {
            let commentsCanResume = includesComments && commentsState == .signedOut && hasCredential
            let waveformCanResume: Bool
            if case .unavailable = waveform {
                switch WaveformService.shared.state(for: trackId) {
                case .pending, .loading: waveformCanResume = true
                case .failed(let error): waveformCanResume = !error.isPermanent
                case .ready: waveformCanResume = false
                }
            } else {
                waveformCanResume = false
            }
            guard commentsCanResume || waveformCanResume else { return }
        }
        loadedTrackId = trackId
        task?.cancel()

        #if DEBUG
        if VisualFixtures.isEnabled {
            let track = VisualFixtures.nowPlayingMix
            resolvedTrack = track
            let fixtureComments = VisualFixtures.longSetEnabled && trackId == track.id ? VisualFixtures.longSetCommentList() : CommentDemo.comments()
            if ProcessInfo.processInfo.environment["SOUNDING_TV_COMMENTS_FEW"] == "1" {
                comments = Array(fixtureComments.prefix(2))
            } else {
                comments = fixtureComments
            }
            commentsState = .loaded
            waveform = .ready(samples: VisualFixtures.longSetEnabled && trackId == track.id ? VisualFixtures.longSetWaveform() : Self.debugWaveformSamples())
            Self.trackCache[trackId] = track
            Self.commentsCache[trackId] = (.loaded, comments)
            return
        }

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

        let playingTrack = PlayerService.shared.currentTrack
        let cachedTrack = Self.trackCache[trackId]
            ?? (playingTrack?.id == trackId ? playingTrack : nil)
        let waveformCached = Self.phoneWaveformIfCached(WaveformService.shared.state(for: trackId))
        let commentsCached = Self.commentsCache[trackId]
        let commentsAlreadyLoaded = !includesComments
            || (commentsCached != nil && !(hasCredential && commentsCached?.state == .signedOut))
        waveform = waveformCached ?? .loading
        commentsState = commentsAlreadyLoaded ? (commentsCached?.state ?? .idle) : .loading
        comments = commentsAlreadyLoaded ? (commentsCached?.comments ?? []) : []
        resolvedTrack = cachedTrack

        guard waveformCached == nil || !commentsAlreadyLoaded else { return }

        guard hasCredential else {
            if waveformCached == nil {
                if cachedTrack != nil {
                    task = Task { [weak self] in
                        await self?.loadWaveform(
                            trackId: trackId,
                            cachedTrack: cachedTrack,
                            alreadyCached: false
                        )
                    }
                } else {
                    waveform = .unavailable("")
                }
            }
            if !commentsAlreadyLoaded {
                commentsState = .signedOut
                Self.commentsCache[trackId] = (.signedOut, [])
            }
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            async let commentsDone: Void = self.loadComments(
                trackId: trackId,
                alreadyCached: commentsAlreadyLoaded
            )
            async let waveformDone: Void = self.loadWaveform(trackId: trackId, cachedTrack: cachedTrack, alreadyCached: waveformCached != nil)
            _ = await (commentsDone, waveformDone)
        }
    }

    private func loadComments(trackId: String, alreadyCached: Bool) async {
        guard !alreadyCached else { return }
        do {
            var page = try await SoundCloudAPI.shared.getComments(trackId: trackId)
            guard !Task.isCancelled, loadedTrackId == trackId else { return }
            comments = page.collection
            commentsState = .loaded
            var fetched = 1
            while let next = page.nextHref, fetched < Self.maxCommentPages {
                if case .waiting = SoundCloudGateway.shared.trafficSafetyState() { break }
                guard let more = try? await SoundCloudAPI.shared.getPage(Comment.self, from: next) else { break }
                guard !Task.isCancelled, loadedTrackId == trackId else { return }
                page = more
                comments.appendUnique(contentsOf: more.collection)
                fetched += 1
            }
        } catch {
            guard !Task.isCancelled, loadedTrackId == trackId else { return }
            commentsState = .failed
        }
        Self.commentsCache[trackId] = (commentsState, comments)
        Self.trimCaches(keeping: trackId)
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

    func insert(_ comment: Comment, trackId: String) {
        guard loadedTrackId == trackId, !comments.contains(where: { $0.id == comment.id }) else { return }
        comments.append(comment)
        commentsState = .loaded
        Self.commentsCache[trackId] = (.loaded, comments)
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
        CommentTimeline.ordered(comments)
    }

    #if DEBUG

    private static func debugWaveformSamples(count: Int = 2_048) -> [Float] {
        (0..<count).map { index in
            let position = Double(index) / Double(max(1, count - 1))
            let phrase = 0.22 * sin(position * .pi * 12)
            let beat = 0.13 * sin(position * .pi * 94)
            let build = 0.35 + 0.34 * sin(position * .pi)
            let breakLift = position > 0.38 && position < 0.66 ? 0.18 : 0
            return Float(min(1, max(0.08, build + phrase + beat + breakLift)))
        }
    }

    private struct DebugWaveformDocument: Decodable {
        let height: Int?
        let samples: [Int]
    }

    nonisolated private static func fetchDebugWaveform(from url: URL) async -> PhoneWaveformState {
        if ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) {
            return .unavailable("Waveform is image-only")
        }
        guard let (data, response) = try? await URLSession.shared.loggedData(from: url, feature: .waveform) else {
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
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize, CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        let translation = CGSize(width: t.x, height: t.y)
        switch recognizer.state {
        case .changed:
            onChanged(translation)
        case .ended, .cancelled, .failed:
            onEnded(translation, CGSize(width: t.x + v.x * 0.2, height: t.y + v.y * 0.2))
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.08
        }
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
