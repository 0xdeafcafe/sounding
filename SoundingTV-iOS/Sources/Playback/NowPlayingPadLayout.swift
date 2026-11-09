import SwiftUI

struct NowPlayingPadLayout: View {
    let context: NowPlayingContext
    let size: CGSize
    let safe: EdgeInsets
    let keyboard: CGFloat

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isMoving = false

    private var router: NowPlayingRouter { context.router }

    private var scale: CGFloat { min(1, size.height / 1032, size.width / 1376) }
    private var columnLeft: CGFloat { 76 * scale }
    private var top: CGFloat { max(82 * scale, safe.top + 40) }
    private var gutter: CGFloat { 64 * scale }
    private var trailing: CGFloat { 40 * scale }
    private var belowArt: CGFloat { dynamicTypeSize.isAccessibilitySize ? 640 : 420 }

    private var art: CGFloat {
        let byHeight = size.height - top - belowArt - max(safe.bottom, 20)
        let byWidth = (size.width - columnLeft - gutter - trailing) * 0.45
        return max(220, min(500, byHeight, byWidth))
    }

    var body: some View {
        if let snapshot = coordinator.nowPlaying {
            let tint = context.artwork.tint
            let pausedScale: CGFloat = (snapshot.isPlaying || reduceMotion) ? 1 : 0.86
            ZStack(alignment: .topLeading) {
                Button(action: context.onClose) {
                    Capsule()
                        .fill(NPInk.faint)
                        .frame(width: 46, height: 5)
                        .frame(width: 120, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Now Playing")
                .position(x: size.width / 2, y: max(36 * scale, safe.top) + 12)

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView {
                            column(snapshot, tint: tint, pausedScale: pausedScale)
                                .padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                    } else {
                        column(snapshot, tint: tint, pausedScale: pausedScale)
                            .padding(.bottom, max(40 * scale, safe.bottom + 12))
                    }
                }
                .frame(width: art, height: size.height - top, alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center)
                .offset(x: columnLeft, y: top)

                NowPlayingPadPanel(context: context, snapshot: snapshot)
                    .frame(
                        width: max(320, size.width - columnLeft - art - gutter - trailing),
                        height: max(320, size.height - top - (keyboard > 0 ? keyboard + 12 : max(40 * scale, safe.bottom + 12)))
                    )
                    .offset(x: columnLeft + art + gutter, y: top)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .ignoresSafeArea()
            .onChange(of: coordinator.currentOutput.id) { _, _ in
                guard !reduceMotion else { return }
                isMoving = true
                Task {
                    try? await Task.sleep(for: .milliseconds(420))
                    isMoving = false
                }
            }
        }
    }

    private func column(_ snapshot: NowPlayingSnapshot, tint: Color, pausedScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingHeroArt(context: context, snapshot: snapshot, side: art, gap: 80, cornerRadius: 16)
                .scaleEffect(isMoving ? 0.95 : pausedScale)
                .animation(reduceMotion ? nil : NPMotion.spring, value: pausedScale)
                .animation(reduceMotion ? nil : NPMotion.spring, value: isMoving)

            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    Button { router.pane = .about } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            NowPlayingTitleBlock(
                                title: snapshot.displayTitle,
                                artist: snapshot.displayArtist,
                                tint: tint,
                                font: .title,
                                trackId: snapshot.trackId
                            )
                            SoundCloudPreviewNowPlayingLine(trackID: snapshot.trackId)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(NPInk.secondary)
                            StationNowPlayingLine(source: coordinator.queueSource)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(NPInk.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows Behind the Track")
                    .id(snapshot.trackId ?? snapshot.displayTitle)
                    .transition(.opacity)
                }
                .animation(.easeOut(duration: 0.18), value: snapshot.trackId)
                NowPlayingActions(
                    context: context,
                    snapshot: snapshot,
                    diameter: 40,
                    isPad: true,
                    store: context.waveformStore,
                    cueBoard: context.cueBoard
                )
                .padding(.top, 8)
            }
            .overlay(alignment: .topLeading) {
                ListenTogetherIndicator()
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(NPInk.secondary)
                    .offset(y: -24)
            }
            .padding(.top, 30)

            if NowPlayingTape.isActive(router: router, trackId: snapshot.trackId, duration: coordinator.timeline.anchor.duration) {
                NowPlayingDock(
                    context: context,
                    snapshot: snapshot,
                    style: .pad,
                    isPad: true,
                    tapeStyle: NowPlayingTape.style(isPad: true, timesHeight: 18),
                    bleed: TapeBleed(leading: columnLeft, trailing: gutter / 2)
                )
                .padding(.top, 22)
            } else {
                NowPlayingMixLine(trackId: snapshot.trackId, timeline: coordinator.timeline, font: .subheadline) {
                    router.pane = .tracklist
                }
                .padding(.top, 6)

                NowPlayingDock(context: context, snapshot: snapshot, style: .pad, isPad: true)
                    .padding(.top, 20)
            }

            NowPlayingTransport(snapshot: snapshot, playSize: 40, skipSize: 30)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: 84)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            NowPlayingVolumeSlider()
                .padding(.top, 14)

            NowPlayingPadRoutePill(context: context)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }
}

private struct NowPlayingPadPanel: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    var body: some View {
        let router = context.router
        VStack(spacing: 0) {
            NowPlayingPaneTabs(router: router, panes: NowPlayingPane.padTabs(
                isDeviceTrack: snapshot.isDeviceTrack,
                hidesLyrics: setlists.isMix(trackID: snapshot.trackId, title: snapshot.title, duration: snapshot.duration)
            ))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

            ZStack {
                NowPlayingPaneContent(
                    context: context,
                    snapshot: snapshot,
                    pane: router.pane,
                    style: NowPlayingPaneStyle(inset: 28, titleFont: .title2.weight(.bold)),
                    store: context.waveformStore
                )
                .id(router.pane)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.26), value: router.pane)
            .padding(.bottom, router.pane == .comments ? 20 : 0)
        }
        .padding(.top, 22)
        .glassEffect(.regular.tint(context.artwork.tint.opacity(0.06)), in: .rect(cornerRadius: 36, style: .continuous))
    }
}

private struct NowPlayingPadRoutePill: View {
    let context: NowPlayingContext

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        let remote = !coordinator.currentOutput.isLocal
        let tint = context.artwork.tint
        NowPlayingOutputButton(context: context, showsClose: false) {
            HStack(spacing: 8) {
                Image(systemName: remote ? coordinator.currentOutput.symbolName : "airplay.audio")
                    .font(.system(size: 17, weight: .medium))
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : bounce)
                Text(coordinator.currentOutput.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(remote ? tint : NPInk.primary)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(minHeight: 40)
            .glassEffect(.regular.tint(NowPlayingTint.glass(context.artwork.tint)).interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .fixedSize()
        .onChange(of: coordinator.currentOutput.id) { _, _ in bounce += 1 }
    }
}
