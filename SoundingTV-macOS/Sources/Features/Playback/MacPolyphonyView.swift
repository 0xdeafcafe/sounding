import SwiftUI
import AppKit

struct MacPolyphonyView: View {
    @EnvironmentObject private var polyphony: PolyphonyController
    @ObservedObject private var player = PlayerService.shared

    @State private var selectedSession: PolyphonyController.NearbySession?
    @State private var joinCode = ""

    var body: some View {
        VStack(spacing: 0) {
            MacPaneHeader(
                title: "Polyphony",
                subtitle: "One queue, playing together on nearby devices"
            )

            ScrollView {
                VStack(spacing: 30) {
                    hero
                    content
                }
                .frame(maxWidth: 680, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 38)
            }
        }
        .task { polyphony.startBrowsing() }
        .onDisappear { polyphony.stopBrowsingIfIdle() }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            heroArtwork
            heroCopy
            onboardingSteps
        }
        .frame(maxWidth: .infinity)
    }

    private var heroArtwork: some View {
        PolyphonyHeroView(leaderClass: .mac)
            .frame(width: 126, height: 126)
    }

    private var heroCopy: some View {
        VStack(spacing: 7) {
            Text("Play together")
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text("One device leads. Every nearby device plays the same SoundCloud track in sync.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560, alignment: .center)
    }

    private var onboardingSteps: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                onboardingStep("1", "Start on one device", icon: "macbook")
                onboardingStep("2", "Enter the code", icon: "number")
                onboardingStep("3", "Press play", icon: "play.fill")
            }
            VStack(spacing: 8) {
                onboardingStep("1", "Start on one device", icon: "macbook")
                onboardingStep("2", "Enter the code", icon: "number")
                onboardingStep("3", "Press play", icon: "play.fill")
            }
        }
    }

    private func onboardingStep(_ number: String, _ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch polyphony.mode {
        case .idle: idleContent
        case .startingLeader: progress("Starting Polyphony…")
        case .leading: hostingContent
        case .connecting(let leaderName): progress("Joining \(leaderName)…")
        case .speaker(let leaderName): guestContent(leaderName: leaderName)
        case .failed(let message): failure(message)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            leadBox
            joinBox
        }
        .frame(maxWidth: .infinity)
    }

    private var leadBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Lead from this Mac", systemImage: "play.circle.fill")
                .font(.headline)
            Text("Everyone who joins follows this Mac's queue and transport controls.")
                .foregroundStyle(.secondary)
            Button {
                polyphony.startLeading(leaderName: Host.current().localizedName ?? "Mac")
            } label: {
                Label("Start Polyphony", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 17)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(.orange.opacity(0.30)),
                in: Capsule(style: .continuous)
            )
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var joinBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Join a nearby session", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if polyphony.nearbySessions.isEmpty {
                ContentUnavailableView(
                    "Looking for nearby devices",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Leave Polyphony open on the leader and put both devices on the same network.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Picker("Session", selection: $selectedSession) {
                    Text("Choose a session").tag(nil as PolyphonyController.NearbySession?)
                    ForEach(polyphony.nearbySessions) { session in
                        Text(session.leaderName).tag(Optional(session))
                    }
                }

                TextField("Six-digit code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: joinCode) { _, value in
                        joinCode = String(value.filter(\.isNumber).prefix(6))
                    }

                Button {
                    guard let selectedSession else { return }
                    polyphony.join(selectedSession, code: joinCode)
                } label: {
                    Label("Join Polyphony", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 17)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(.orange.opacity(0.24)),
                    in: Capsule(style: .continuous)
                )
                .disabled(selectedSession == nil || joinCode.count != 6)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var hostingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("This Mac is leading", systemImage: "crown.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)

            if let code = polyphony.joinCode {
                Text(code.polyphonyDisplayCode)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .textSelection(.enabled)
                    .accessibilityLabel("Polyphony code \(code)")
            }

            Text(polyphony.speakerCount == 1 ? "1 good boy" : "\(polyphony.speakerCount) good boys")
                .foregroundStyle(.secondary)
            nowPlaying(title: player.currentTrack?.title, artist: player.currentTrack?.user.displayName)
            Button("End Polyphony", role: .destructive) { polyphony.leave() }
        }
    }

    private func guestContent(leaderName: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Following \(leaderName)", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            nowPlaying(title: polyphony.remoteSnapshot?.title, artist: polyphony.remoteSnapshot?.artist)
            Text("The leader controls playback. This Mac streams the same SoundCloud track through its own account.")
                .foregroundStyle(.secondary)
            Button("Leave Polyphony", role: .destructive) { polyphony.leave() }
        }
    }

    private func nowPlaying(title: String?, artist: String?) -> some View {
        GroupBox("Now Playing") {
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? "Waiting for the leader")
                    .font(.headline)
                if let artist { Text(artist).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(label).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Polyphony Stopped", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(friendlyFailure(message))
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            HStack {
                if isLocalNetworkFailure(message) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Try Again") {
                    polyphony.leave()
                    polyphony.startBrowsing()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func isLocalNetworkFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("noauth") || lower.contains("-65555") || lower.contains("local network")
    }

    private func friendlyFailure(_ message: String) -> String {
        if isLocalNetworkFailure(message) {
            return "SoundingCloud does not currently have access to nearby devices. Allow Local Network access in System Settings, then try again."
        }
        return "Nearby devices could not be reached. Make sure they are on the same Wi-Fi network, then try again."
    }
}

private extension String {
    var polyphonyDisplayCode: String {
        let digits = filter(\.isNumber)
        return "\(digits.prefix(3))  \(digits.dropFirst(3).prefix(3))"
    }
}
