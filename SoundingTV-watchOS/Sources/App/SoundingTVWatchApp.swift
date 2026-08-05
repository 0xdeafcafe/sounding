import SwiftUI

enum WatchUIPreview {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SoundingWatchUIPreview")
        #else
        false
        #endif
    }
}

@main
struct SoundingTVWatchApp: App {
    @StateObject private var link = WatchLinkClient.shared
    @StateObject private var credentials = WatchCredentialSource.shared

    init() {
        WatchCredentialSource.install()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(link)
                .environmentObject(credentials)
                .tint(WatchStyle.style.accent)
                .task {
                    link.activate()
                    await credentials.adoptFromPhoneIfNeeded()
                }
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource

    var body: some View {
        NavigationStack {
            List {
                if let offer = credentials.pendingTVOffer {
                    Section("Companion") {
                        Button {
                            Task { await credentials.authorizeWaitingTV() }
                        } label: {
                            HStack(spacing: WatchStyle.style.spaceTight) {
                                Image(systemName: "appletv.fill")
                                    .foregroundStyle(WatchStyle.style.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Authorise \(offer.tvName)")
                                        .font(WatchStyle.style.fontCaptionEmphasis)
                                    Text("It's waiting to sign in")
                                        .font(WatchStyle.style.fontCaption)
                                        .foregroundStyle(WatchStyle.style.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if credentials.isAuthorizingTV {
                                    ProgressView()
                                } else {
                                    Image(systemName: "checkmark.shield")
                                }
                            }
                        }
                        .disabled(credentials.isAuthorizingTV)
                    }
                }

                if link.nowPlaying.hasTrack {
                    Section {
                        NavigationLink { WatchNowPlayingView() } label: {
                            WatchNowPlayingChip(nowPlaying: link.nowPlaying)
                        }
                    }
                }

                Section {
                    NavigationLink { WatchHomeView() } label: {
                        WatchDestinationRow(title: "Listen Now", systemImage: "play.circle.fill")
                    }
                    NavigationLink { WatchLibraryView() } label: {
                        WatchDestinationRow(title: "Library", systemImage: "music.note.list")
                    }
                    NavigationLink { WatchDownloadsView() } label: {
                        WatchDestinationRow(title: "Downloaded", systemImage: "arrow.down.circle.fill")
                    }
                }

                Section {
                    NavigationLink { WatchDJView() } label: {
                        WatchDestinationRow(
                            title: "Auto DJ",
                            systemImage: "wand.and.stars",
                            tint: link.djState.isEngineLive ? WatchStyle.style.success : WatchStyle.style.accent
                        )
                    }
                    NavigationLink { WatchPolyphonyView() } label: {
                        WatchDestinationRow(
                            title: "Polyphony",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            tint: link.polyphonyState.mode == .idle
                                ? WatchStyle.style.accent
                                : WatchStyle.style.success
                        )
                    }
                    NavigationLink { WatchSettingsView() } label: {
                        WatchDestinationRow(title: "Settings", systemImage: "gearshape.fill", tint: WatchStyle.style.textSecondary)
                    }
                }
            }
            .navigationTitle("Sounding")
            .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
        }
        .overlay {
            if !credentials.isSignedIn, !WatchUIPreview.isEnabled {
                WatchSignInGate()
            }
        }
        .task {
            while !Task.isCancelled {
                credentials.refreshTVAuthorizationOffer()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .alert("Companion", isPresented: Binding(
            get: { credentials.tvAuthorizationResult != nil },
            set: { if !$0 { credentials.dismissTVAuthorizationResult() } }
        )) {
            Button("OK", role: .cancel) { credentials.dismissTVAuthorizationResult() }
        } message: {
            Text(credentials.tvAuthorizationResult ?? "")
        }
    }
}

private struct WatchPolyphonyView: View {
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        List {
            Section {
                status
            }

            Section {
                switch link.polyphonyState.mode {
                case .idle, .failed:
                    Button {
                        link.polyphony(.lead)
                    } label: {
                        Label("Start on iPhone", systemImage: "play.circle.fill")
                    }
                    .disabled(!link.isReachable)
                case .startingLeader, .leading, .connecting, .speaker:
                    Button(role: .destructive) {
                        link.polyphony(.leave)
                    } label: {
                        Label("Leave Polyphony", systemImage: "xmark.circle")
                    }
                    .disabled(!link.isReachable)
                }
            }

            if !link.isReachable {
                Section {
                    Label("Change the session on iPhone.", systemImage: "iphone")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                }
            }
        }
        .navigationTitle("Polyphony")
    }

    @ViewBuilder
    private var status: some View {
        switch link.polyphonyState.mode {
        case .idle:
            WatchEmptyState(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "Not Playing Together",
                message: "Start one here, or join from iPhone."
            )
        case .startingLeader:
            HStack { ProgressView(); Text("Starting on iPhone…") }
        case .leading:
            VStack(alignment: .leading, spacing: WatchStyle.style.spaceTight) {
                Label("iPhone is leading", systemImage: "crown.fill")
                    .foregroundStyle(WatchStyle.style.success)
                if let code = link.polyphonyState.joinCode {
                    Text(code.watchPolyphonyCode)
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                }
                Text(link.polyphonyState.speakerCount == 1
                     ? "1 good boy"
                     : "\(link.polyphonyState.speakerCount) good boys")
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textSecondary)
            }
        case .connecting:
            HStack { ProgressView(); Text("Joining \(link.polyphonyState.leaderName ?? "session")…") }
        case .speaker:
            Label("Following \(link.polyphonyState.leaderName ?? "the leader")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(WatchStyle.style.success)
        case .failed:
            Label(link.polyphonyState.message ?? "Polyphony needs a look", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private extension String {
    var watchPolyphonyCode: String {
        let digits = filter(\.isNumber)
        return "\(digits.prefix(3)) \(digits.dropFirst(3).prefix(3))"
    }
}

struct WatchNowPlayingChip: View {
    let nowPlaying: WatchNowPlaying
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: WatchStyle.style.spaceTight) {
            WatchArtwork(url: nowPlaying.artworkURL, size: 28, corner: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(nowPlaying.title)
                    .font(WatchStyle.style.fontCaptionEmphasis)
                    .foregroundStyle(WatchStyle.style.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Text(nowPlaying.output.displayName)
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: nowPlaying.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WatchStyle.style.accent)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .padding(.vertical, 2)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nowPlaying.trackId)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nowPlaying.isPlaying)
    }
}

struct WatchSignInGate: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: WatchStyle.style.spaceTight) {
                    Image(systemName: link.isReachable ? "iphone.and.arrow.forward" : "iphone.slash")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(WatchStyle.style.accent)
                        .padding(.top, WatchStyle.style.spaceTight)

                    Text(link.isReachable ? "Sign in on iPhone" : "iPhone not reachable")
                        .font(WatchStyle.style.fontBodyEmphasis)
                        .foregroundStyle(WatchStyle.style.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(link.isReachable
                         ? "Open SoundingCloud on iPhone to share its account."
                         : "Bring your iPhone closer to sign in.")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if credentials.isAdopting {
                        ProgressView()
                            .padding(.top, WatchStyle.style.spaceTight)
                    } else {
                        Button("Try Again") {
                            Task { await credentials.adoptFromPhone() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchStyle.style.accent)
                        .font(WatchStyle.style.fontCaptionEmphasis)
                        .padding(.top, WatchStyle.style.spaceTight)
                    }
                }
                .padding(.horizontal, WatchStyle.style.spaceTight)
            }
        }
    }
}
