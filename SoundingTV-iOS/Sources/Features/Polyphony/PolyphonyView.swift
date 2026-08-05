import Combine
import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit


// MARK: - iPhone UI

struct PolyphonyView: View {
    @EnvironmentObject private var polyphony: PolyphonyController
    @ObservedObject private var player = PlayerService.shared
    @State private var sessionToJoin: PolyphonyController.NearbySession?

    var body: some View {
        ScrollView {
            VStack(spacing: Space.roomy) {
                hero
                content
            }
            .padding(.horizontal, Space.roomy)
            .padding(.top, Space.tight)
            .padding(.bottom, PhoneChrome.floatingClearance)
        }
        .background(Color.scBackgroundGradient.ignoresSafeArea())
        .navigationTitle("Polyphony")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            polyphony.startBrowsing()
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_POLYPHONY"] == "host",
               polyphony.mode == .idle {
                polyphony.startLeading()
            }
            #endif
        }
        .onDisappear { polyphony.stopBrowsingIfIdle() }
        .sheet(item: $sessionToJoin) { nearbySession in
            JoinPolyphonySheet(nearbySession: nearbySession)
                .environmentObject(polyphony)
                .presentationDetents([.medium])
        }
    }

    private var hero: some View {
        HStack(spacing: Space.base) {
            PolyphonyHeroView(leaderClass: .phone)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text("More than one way to listen")
                    .font(.scTitle)
                Text("One device leads. Everyone streams through their own SoundCloud account.")
                    .font(.scSubhead)
                    .foregroundStyle(Color.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.roomy)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [Color.scAccent, Color(red: 0.50, green: 0.12, blue: 0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Corner.hero, style: .continuous)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch polyphony.mode {
        case .idle:
            idleContent
        case .startingLeader:
            progressCard("Starting Polyphony…")
        case .leading:
            hostingContent
        case .connecting(let leaderName):
            progressCard("Joining \(leaderName)…")
        case .speaker(let leaderName):
            guestContent(leaderName: leaderName)
        case .failed(let message):
            failureContent(message)
        }
    }

    private var idleContent: some View {
        VStack(spacing: Space.roomy) {
            VStack(alignment: .leading, spacing: Space.snug) {
                Label("Lead Polyphony", systemImage: "play.circle.fill")
                    .font(.scSection)
                Text("Your queue and transport drive the room. Start or change a playlist as normal and your good boys follow.")
                    .font(.scSubhead)
                    .foregroundStyle(Color.scTextSecondary)
                Button {
                    polyphony.startLeading()
                } label: {
                    Label("Start Polyphony", systemImage: "dot.radiowaves.left.and.right")
                        .font(.scHeadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(.scAccent)
            }
            .scCard()

            VStack(alignment: .leading, spacing: Space.snug) {
                HStack {
                    Label("Nearby Polyphony", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.scSection)
                    Spacer()
                    ProgressView().controlSize(.small)
                }

                if polyphony.nearbySessions.isEmpty {
                    Text("Keep both devices open and on the same Wi-Fi. Sessions appear here on their own.")
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.tight)
                } else {
                    ForEach(polyphony.nearbySessions) { nearbySession in
                        Button {
                            sessionToJoin = nearbySession
                        } label: {
                            HStack(spacing: Space.snug) {
                                Image(systemName: "iphone")
                                    .font(.title3)
                                    .foregroundStyle(Color.scAccent)
                                    .frame(width: 34, height: 34)
                                    .background(Color.scAccentMuted, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(nearbySession.leaderName).font(.scHeadline)
                                    Text("Tap to enter the leader's code")
                                        .font(.scCaption)
                                        .foregroundStyle(Color.scTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.scTextTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scCard()
        }
    }

    private var hostingContent: some View {
        VStack(spacing: Space.roomy) {
            VStack(spacing: Space.base) {
                Label("You're leading", systemImage: "crown.fill")
                    .font(.scSection)
                    .foregroundStyle(Color.scWarning)
                Text("Tell nearby listeners this code")
                    .font(.scSubhead)
                    .foregroundStyle(Color.scTextSecondary)
                if let code = polyphony.joinCode { PolyphonyCodeView(code: code) }
                Text(polyphony.speakerCount == 1 ? "1 good boy" : "\(polyphony.speakerCount) good boys")
                    .font(.scHeadline)
            }
            .frame(maxWidth: .infinity)
            .scCard()

            nowPlayingCard(
                title: player.currentTrack?.title,
                artist: player.currentTrack?.user.displayName,
                artworkURL: player.currentTrack?.artworkURL,
                emptyMessage: "Play any track or playlist. Joined phones follow along."
            )

            Button("End Polyphony", role: .destructive) { polyphony.leave() }
                .buttonStyle(.bordered)
        }
    }

    private func guestContent(leaderName: String) -> some View {
        VStack(spacing: Space.roomy) {
            HStack(spacing: Space.snug) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.scSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Following \(leaderName)").font(.scHeadline)
                    Text("The leader drives the queue and transport")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
                Spacer()
            }
            .scCard()

            nowPlayingCard(
                title: polyphony.remoteSnapshot?.title,
                artist: polyphony.remoteSnapshot?.artist,
                artworkURL: polyphony.remoteSnapshot?.artworkURL.flatMap(URL.init(string:)),
                emptyMessage: "Waiting for the leader to play something."
            )

            Text("Audio streams straight from SoundCloud on this phone's account. Your sign-in and likes are never shared with the leader.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.base)

            Button("Leave Polyphony", role: .destructive) { polyphony.leave() }
                .buttonStyle(.bordered)
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: Space.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.scWarning)
            Text("Couldn't Join Polyphony").font(.scTitle2)
            Text(message)
                .font(.scSubhead)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
            Button("Look Again") {
                polyphony.leave()
                polyphony.startBrowsing()
            }
            .buttonStyle(.borderedProminent)
            .tint(.scAccent)
        }
        .frame(maxWidth: .infinity)
        .scCard()
    }

    private func progressCard(_ message: String) -> some View {
        HStack(spacing: Space.snug) {
            ProgressView()
            Text(message).font(.scHeadline)
        }
        .frame(maxWidth: .infinity)
        .scCard()
    }

    private func nowPlayingCard(
        title: String?,
        artist: String?,
        artworkURL: URL?,
        emptyMessage: String
    ) -> some View {
        HStack(spacing: Space.base) {
            ArtworkImage(url: artworkURL, icon: "music.note")
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            VStack(alignment: .leading, spacing: Space.hair) {
                if let title {
                    Text(title).font(.scHeadline).lineLimit(2)
                    Text(artist ?? "Unknown Artist")
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                } else {
                    Text("Waiting to play").font(.scHeadline)
                    Text(emptyMessage)
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scCard()
    }
}

private struct PolyphonyCodeView: View {
    let code: String

    private var halves: (String, String) {
        let digits = code.filter(\.isNumber)
        return (String(digits.prefix(3)), String(digits.dropFirst(3).prefix(3)))
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            codeCard(halves.0)
            Text("–")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.scTextTertiary)
            codeCard(halves.1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Polyphony code \(code.map(String.init).joined(separator: " "))")
    }

    private func codeCard(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 31, weight: .bold, design: .rounded).monospacedDigit())
            .tracking(5)
            .padding(.leading, 5)
            .frame(minWidth: 118, minHeight: 62)
            .background(Color.scBgOverlay, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
    }
}

private struct JoinPolyphonySheet: View {
    @EnvironmentObject private var polyphony: PolyphonyController
    @Environment(\.dismiss) private var dismiss
    let nearbySession: PolyphonyController.NearbySession
    @State private var code = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.roomy) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.scAccent)
                VStack(spacing: Space.hair) {
                    Text("Join \(nearbySession.leaderName)").font(.scTitle)
                    Text("Enter the six-digit code shown by the leader.")
                        .font(.scSubhead)
                        .foregroundStyle(Color.scTextSecondary)
                }
                TextField("000 000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.scBgRaised, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                    .onChange(of: code) { _, value in
                        code = String(value.filter(\.isNumber).prefix(6))
                    }
                Button("Join Polyphony") {
                    polyphony.join(nearbySession, code: code)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.scAccent)
                .controlSize(.large)
                .disabled(code.count != 6)
                Spacer()
            }
            .padding(Space.roomy)
            .background(Color.scBgBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
