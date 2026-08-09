import SwiftUI

struct QueueManagerView: View {
    @EnvironmentObject var client: CompanionClient
    @State private var editMode: EditMode = .inactive
    @State private var jumpTick = false
    @State private var reorderTick = false

    var body: some View {
        ZStack {
            Color.scBgBase.ignoresSafeArea()

            switch client.state {
            case .unlinked:
                unlinkedState
            case .idle, .searching, .connecting:
                connectingState
            case .failed(let message):
                failedState(message)
            case .connected:
                if !client.hasSnapshot {
                    connectingState
                } else if client.tracks.isEmpty {
                    emptyQueueState
                } else {
                    queueList
                }
            }
        }
        .navigationTitle("Up Next")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if case .connected = client.state, !client.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task { client.connect() }
        .overlay(alignment: .bottom) {
            if let rejection = client.rejection {
                rejectionBanner(rejection)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: client.rejection)
    }

    private var queueList: some View {
        List {
            Section {
                ForEach(Array(client.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        guard editMode == .inactive else { return }
                        jumpTick.toggle()
                        client.jump(to: index)
                    } label: {
                        QueueRow(
                            track: track,
                            isCurrent: index == client.currentIndex,
                            isPlaying: client.isPlaying
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg, bottom: Spacing.xs, trailing: Spacing.lg))
                    .listRowBackground(
                        index == client.currentIndex
                            ? RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .padding(.vertical, 2)
                            : nil
                    )
                    .scrollTransition { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1 : 0.4)
                            .scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: .center)
                    }
                }
                .onMove { indices, newOffset in
                    guard let source = indices.first else { return }
                    reorderTick.toggle()
                    client.move(from: source, to: newOffset > source ? newOffset - 1 : newOffset)
                }
                .onDelete { indices in
                    reorderTick.toggle()
                    for index in indices.sorted(by: >) {
                        client.remove(at: index)
                    }
                }
            } header: {
                Text("\(client.tracks.count) Track\(client.tracks.count == 1 ? "" : "s")")
                    .font(.scCaption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.bottom, Spacing.xs)
            } footer: {
                Text("Swipe a track to remove it. Tap Edit to reorder.")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.xs)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        .refreshable { client.requestQueue() }
        .sensoryFeedback(.selection, trigger: jumpTick)
        .sensoryFeedback(.impact(weight: .light), trigger: reorderTick)
    }

    private var unlinkedState: some View {
        SCEmptyState(
            icon: "qrcode.viewfinder",
            title: "Not Paired Yet",
            message: "Open SoundingCloud on your Apple TV and scan the on-screen QR code. Once you've signed in, the queue shows up here.",
            style: .phone
        )
    }

    private var connectingState: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)

            Text(client.state == .searching ? "Looking for your Apple TV…" : "Connecting…")
                .font(.scHeadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyQueueState: some View {
        SCEmptyState(
            icon: "music.note.list",
            title: "Nothing Up Next",
            message: "Start playing something on your Apple TV and upcoming tracks appear here.",
            actionTitle: "Refresh",
            action: { client.requestQueue() },
            style: .phone
        )
    }

    private func failedState(_ message: String) -> some View {
        SCEmptyState(
            kind: .error,
            title: "Can't Reach Your Apple TV",
            message: message,
            actionTitle: "Try Again",
            action: { client.retry() },
            style: .phone
        )
    }

    private func rejectionBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.scSubhead)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.scBgOverlay, in: Capsule())
            .padding(.bottom, Spacing.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct QueueRow: View {
    let track: QueueTrack
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(isCurrent ? .scHeadline : .scBody)
                    .fontWeight(isCurrent ? .bold : .semibold)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            if isCurrent {
                Image(systemName: isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.scAccent)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            } else {
                Text(track.formattedDuration)
                    .font(.scNumeric.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }

    private var artwork: some View {
        AsyncImage(url: Self.thumbnailURL(track.artworkURL)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
    }

    private static func thumbnailURL(_ url: URL?) -> URL? {
        url?.soundCloudArtworkVariant("t200x200")
    }
}

#Preview {
    NavigationStack {
        QueueManagerView()
    }
    .environmentObject(CompanionClient())
    .preferredColorScheme(.dark)
}
