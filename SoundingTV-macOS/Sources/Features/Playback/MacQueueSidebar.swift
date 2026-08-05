import SwiftUI
import AppKit

struct MacQueueSidebar: View {
    enum Appearance {
        case standard
        case onArtwork(accent: Color)
        case rootArtwork
    }

    var appearance: Appearance = .standard

    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var palette: ArtworkPalette = .fallback
    @State private var ambientArtwork: Image?
    @State private var showingAutoDJStartConfiguration = false

    private var isOnArtwork: Bool {
        switch appearance {
        case .standard: return false
        case .onArtwork, .rootArtwork: return true
        }
    }

    private var rendersArtworkBackdrop: Bool {
        if case .rootArtwork = appearance { return true }
        return false
    }

    private var accent: Color {
        if case .onArtwork(let accent) = appearance { return accent }
        if case .rootArtwork = appearance { return palette.accent }
        return .scAccent
    }

    private var primaryText: Color { isOnArtwork ? .white : .primary }
    private var secondaryText: Color { isOnArtwork ? .white.opacity(0.6) : .secondary }

    private var upcoming: [(index: Int, track: Track)] {
        guard player.currentIndex + 1 < player.queue.count else { return [] }
        return Array(player.queue[(player.currentIndex + 1)...]).enumerated()
            .map { (player.currentIndex + 1 + $0.offset, $0.element) }
    }

    private var history: [(index: Int, track: Track)] {
        guard player.currentIndex > 0, !player.queue.isEmpty else { return [] }
        return Array(player.queue.prefix(player.currentIndex)).enumerated()
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        ZStack {
            if rendersArtworkBackdrop {
                AmbientArtworkBackdrop(seed: ambientArtworkSeed, intensity: 0.55)
                    .overlay(Color.black.opacity(0.24))
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 14) {
                modePills

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !history.isEmpty {
                            queueSectionHeader("History", actionTitle: "Clear") {
                                player.clearPlaybackHistory()
                            }
                            LazyVStack(spacing: 2) {
                                ForEach(history, id: \.index) { entry in
                                    row(entry.track, index: entry.index)
                                }
                            }
                        }

                        queueSectionHeader("Continue Playing", actionTitle: upcoming.isEmpty ? nil : "Clear") {
                            clearUpcoming()
                        }

                        if upcoming.isEmpty {
                            queueEmptyState
                        } else {
                            LazyVStack(spacing: 2) {
                                ForEach(upcoming, id: \.index) { entry in
                                    row(entry.track, index: entry.index)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(rendersArtworkBackdrop ? 18 : 0)
        }
        .task(id: player.currentTrack?.artworkURL) {
            guard rendersArtworkBackdrop, let url = player.currentTrack?.artworkURL else {
                palette = .fallback
                ambientArtwork = nil
                return
            }
            async let paletteResult = ArtworkCache.shared.palette(for: url)
            async let artworkResult = ArtworkCache.shared.heroImage(for: url)
            palette = await paletteResult
            ambientArtwork = await artworkResult
        }
        .sheet(isPresented: $showingAutoDJStartConfiguration) {
            AutoDJStartConfigurationView { configuration in
                player.startDJSession(configuration: configuration, reconfigure: true)
            }
            .frame(minWidth: 440, minHeight: 380)
        }
    }

    private var ambientArtworkSeed: AmbientArtworkSeed {
        AmbientArtworkSeed(
            artwork: ambientArtwork,
            colors: palette.gradientStops,
            accent: palette.accent,
            scrim: max(0.48, palette.localScrimOpacity)
        )
    }

    private func queueSectionHeader(
        _ title: String,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(primaryText)
            Spacer()
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    private func clearUpcoming() {
        let indices = upcoming.map(\.index).reversed()
        Task {
            for index in indices {
                await player.removeFromQueue(at: index)
            }
        }
    }

    private var queueEmptyState: some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(isOnArtwork ? Color.white.opacity(0.22) : Color(nsColor: .separatorColor))
                .frame(height: 1)
            Text("There's no music in the queue.")
                .font(.system(size: 13))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: history.isEmpty ? 280 : 150)
    }

    private var modePills: some View {
        HStack(spacing: 8) {
            Button {
                if settings.djAutoMixEnabled {
                    player.setAutomaticMixEnabled(false)
                } else if settings.hasStoredValue(SettingKeys.DJStartOptions.self) {
                    player.startDJSession(configuration: settings.djStartConfiguration)
                } else {
                    showingAutoDJStartConfiguration = true
                }
            } label: {
                Label(
                    settings.djAutoMixEnabled ? "AutoMix On" : "AutoMix Off",
                    systemImage: settings.djAutoMixEnabled ? "checkmark.circle.fill" : "circle"
                )
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, SCContentStyle.mac.spaceBase)
                .frame(height: 35.5)
            }
            .buttonStyle(.plain)
            .background(
                Capsule().fill(
                    settings.djAutoMixEnabled
                        ? (isOnArtwork ? Color.white.opacity(0.92) : accent)
                        : primaryText.opacity(isOnArtwork ? 0.07 : 0.06)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    settings.djAutoMixEnabled && !isOnArtwork
                        ? accent
                        : primaryText.opacity(isOnArtwork ? 0.12 : 0.10)
                )
            )
            .foregroundStyle(
                settings.djAutoMixEnabled
                    ? (isOnArtwork ? Color.black.opacity(0.82) : Color.white)
                    : secondaryText
            )
            .accessibilityAddTraits(settings.djAutoMixEnabled ? [.isSelected] : [])
            .accessibilityLabel(
                "AutoMix, currently \(settings.djAutoMixEnabled ? "on" : "off")."
            )

            if settings.djAutoMixEnabled {
                Menu {
                    ForEach(DJProfile.all) { profile in
                        Button {
                            player.setDJProfile(profile.id)
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: settings.djDefaultProfileId == profile.id ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(DJProfile.profile(id: settings.djDefaultProfileId)?.displayName ?? "Auto DJ")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOnArtwork ? Color.white.opacity(0.96) : Color.primary)
                    .padding(.horizontal, SCContentStyle.mac.spaceBase)
                    .frame(height: 35.5)
                    .background(
                        (isOnArtwork ? Color.white.opacity(0.11) : accent.opacity(0.10)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isOnArtwork ? Color.white.opacity(0.22) : accent.opacity(0.22)
                        )
                    )
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .environment(\.colorScheme, .dark)
                .help(DJProfile.profile(id: settings.djDefaultProfileId)?.blurb ?? "How AutoMix chooses the next track")

                Button("Configure") {
                    showingAutoDJStartConfiguration = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryText)
            }
        }
    }

    private var trackRowStyle: SCContentStyle {
        var style = SCContentStyle.mac
        style.rowArtworkSize = 32
        if isOnArtwork {
            style.textPrimary = .white
            style.textSecondary = .white.opacity(0.6)
            style.textTertiary = .white.opacity(0.4)
        }
        return style
    }

    private func row(_ track: Track, index: Int) -> some View {
        QueueRow(
            track: track,
            index: index,
            isCurrent: index == player.currentIndex,
            style: trackRowStyle
        ) {
            Task { await player.playTrackAt(index: index) }
        }
    }
}

private struct QueueRow: View {
    let track: Track
    let index: Int
    let isCurrent: Bool
    let style: SCContentStyle
    let onSelect: () -> Void

    @State private var artwork: NSImage?

    var body: some View {
        Button(action: onSelect) {
            SCTrackRow(
                title: track.title,
                subtitle: track.user.displayName,
                artworkImage: artwork.map { Image(nsImage: $0) },
                isAvailable: track.streamURL != nil,
                crownUser: track.user,
                crownContext: track.title,
                style: style
            )
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous)
                .fill(isCurrent ? style.accent.opacity(0.12) : Color.clear)
        )
        .macHoverRowHighlight(cornerRadius: style.cornerControl)
        .contextMenu {
            MacTrackContextMenu(track: track)
            Divider()
            Button("Remove from Queue") {
                Task { await PlayerService.shared.removeFromQueue(at: index) }
            }
        }
        .task(id: track.artworkURL) {
            artwork = nil
            guard let url = track.artworkURL else { return }
            artwork = await ArtworkCache.shared.image(for: url, variant: .standard)
        }
    }
}
