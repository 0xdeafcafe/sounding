import SwiftUI

struct TVPolyphonyView: View {
    @EnvironmentObject private var polyphony: PolyphonyController
    @ObservedObject private var player = PlayerService.shared
    @State private var selectedSession: PolyphonyController.NearbySession?
    @State private var joinCode = ""
    @FocusState private var leadIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.roomy) {
                hero
                content
            }
            .frame(maxWidth: 1480, alignment: .leading)
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.roomy)
        }
        .background(BrowseBackdrop())
        .task { polyphony.startBrowsing() }
        .onDisappear { polyphony.stopBrowsingIfIdle() }
        .defaultFocus($leadIsFocused, true)
    }

    private var hero: some View {
        HStack(spacing: Space.roomy) {
            VStack(alignment: .leading, spacing: Space.snug) {
                Eyebrow(text: "PLAY TOGETHER", tint: .scAccent)
                Text("Polyphony")
                    .font(.tvLargeTitle)
                    .foregroundStyle(Color.scTextPrimary)
                Text("Start a room or join one nearby. Everyone hears the same track in sync, through their own SoundCloud account.")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 780, alignment: .leading)
            }

            Spacer(minLength: Space.roomy)

            PolyphonyHeroView(leaderClass: .tv)
                .frame(width: 224, height: 224)
                .accessibilityHidden(true)
        }
        .padding(.leading, Space.roomy)
        .padding(.trailing, Space.base)
        .padding(.vertical, Space.base)
        .background(
            LinearGradient(
                colors: [Color.scBgRaised, Color.scBgRaised.opacity(0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Corner.hero, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Corner.hero, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
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
        HStack(alignment: .top, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.base) {
                Label("Start a room", systemImage: "play.circle.fill")
                    .font(.tvHeadline)
                Text("Use this Apple TV's queue as the source. Nearby devices can join with a short code.")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    polyphony.startLeading(leaderName: "Apple TV")
                } label: {
                    Label("Start Polyphony", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .focused($leadIsFocused)
            }
            .polyphonyCard(tint: Color.scAccent.opacity(0.13))

            VStack(alignment: .leading, spacing: Space.base) {
                HStack(spacing: Space.snug) {
                    Label("Join a room", systemImage: "dot.radiowaves.left.and.right")
                        .font(.tvHeadline)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.scAccent)
                }
                if polyphony.nearbySessions.isEmpty {
                    ContentUnavailableView(
                        "Looking for rooms",
                        systemImage: "wifi",
                        description: Text("Keep the leader open on the same Wi-Fi network. Rooms appear here automatically.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    ForEach(polyphony.nearbySessions) { session in
                        Button {
                            selectedSession = session
                            joinCode = ""
                        } label: {
                            HStack {
                                Image(systemName: "appletv.fill")
                                    .foregroundStyle(Color.scAccent)
                                Text(session.leaderName)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.tvCaption.weight(.bold))
                                    .foregroundStyle(Color.scTextTertiary)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                }
                if let selectedSession {
                    TextField("Six-digit code", text: $joinCode)
                        .textContentType(.oneTimeCode)
                        .onChange(of: joinCode) { _, value in
                            joinCode = String(value.filter(\.isNumber).prefix(6))
                        }
                    Button("Join \(selectedSession.leaderName)") {
                        polyphony.join(selectedSession, code: joinCode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(joinCode.count != 6)
                }
            }
            .polyphonyCard()
        }
    }

    private var hostingContent: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label("This Apple TV is leading", systemImage: "crown.fill")
                .font(.tvHeadline).foregroundStyle(Color.scWarning)
            if let code = polyphony.joinCode {
                Text(code.chunkedPolyphonyCode)
                    .font(.system(size: 72, weight: .bold, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Polyphony code \(code)")
            }
            Text(polyphony.speakerCount == 1 ? "1 good boy" : "\(polyphony.speakerCount) good boys")
                .font(.tvBody)
            nowPlaying(title: player.currentTrack?.title, artist: player.currentTrack?.user.displayName)
            Button("End Polyphony", role: .destructive) { polyphony.leave() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .polyphonyCard(tint: Color.scAccent.opacity(0.10))
    }

    private func guestContent(leaderName: String) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label("Following \(leaderName)", systemImage: "checkmark.circle.fill")
                .font(.tvHeadline).foregroundStyle(Color.scSuccess)
            nowPlaying(title: polyphony.remoteSnapshot?.title, artist: polyphony.remoteSnapshot?.artist)
            Text("The leader controls playback. This Apple TV streams with its own SoundCloud account.")
                .font(.tvBody).foregroundStyle(Color.scTextSecondary)
            Button("Leave Polyphony", role: .destructive) { polyphony.leave() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .polyphonyCard(tint: Color.scSuccess.opacity(0.10))
    }

    private func nowPlaying(title: String?, artist: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Eyebrow(text: "NOW PLAYING", tint: .scAccent)
            Text(title ?? "Waiting for the leader").font(.tvHeadline)
            if let artist { Text(artist).font(.tvBody).foregroundStyle(Color.scTextSecondary) }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .polyphonyCard()
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.base) {
            ProgressView().scaleEffect(1.2)
            Text(text).font(.tvHeadline)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .polyphonyCard()
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label("Polyphony stopped", systemImage: "exclamationmark.triangle.fill")
                .font(.tvHeadline).foregroundStyle(Color.scWarning)
            Text(message).font(.tvBody).foregroundStyle(Color.scTextSecondary)
            Button("Look Again") { polyphony.leave(); polyphony.startBrowsing() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .polyphonyCard(tint: Color.scWarning.opacity(0.10))
    }
}

private extension View {
    func polyphonyCard(tint: Color = .clear) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.roomy)
            .background(Color.scBgRaised.opacity(0.92), in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .fill(tint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension String {
    var chunkedPolyphonyCode: String {
        let digits = filter(\.isNumber)
        return "\(digits.prefix(3))  \(digits.dropFirst(3).prefix(3))"
    }
}
