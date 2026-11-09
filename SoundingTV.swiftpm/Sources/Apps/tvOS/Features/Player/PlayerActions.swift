import SwiftUI
import Combine

struct UtilityActionButton: View {
    let icon: String
    var label: String? = nil
    var badge: String? = nil
    var isActive: Bool = false
    var isBusy: Bool = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didActivate = false

    var body: some View {
        Button {
            didActivate.toggle()
            action()
        } label: {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(focused ? Color.scChromeFocusOn : .white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                        .symbolEffect(.bounce, value: reduceMotion ? false : didActivate)
                        .accessibilityLabel(accessibilityLabel ?? label ?? icon)
                }
                if let label {
                    Text(label)
                        .font(.tvBodyEmph)
                }
                if let badge {
                    Text(badge)
                        .font(.tvMini)
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, label == nil ? Spacing.sm + 2 : Space.snug)
            .padding(.vertical, Space.tight)
            .frame(minWidth: label == nil ? Control.circle : nil, minHeight: Control.circle)
            .background {
                Capsule()
                    .fill(Color.scChromeFocus)
                    .opacity(focused ? 1 : 0)
            }
            .liquidGlass(in: Capsule(), tint: isActive && !focused ? Color.white.opacity(0.24) : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(), sizeClass: .card))
        .focused($focused)
        .accessibilityLabel(accessibilityLabel ?? label ?? icon)
        .accessibilityValue(isBusy ? "Busy" : (isActive ? "On" : ""))
    }

    private var foreground: Color {
        if focused { return Color.scChromeFocusOn }
        return Color.scTextPrimary
    }
}

@MainActor
final class TrackEngagementStore: ObservableObject {
    @Published private(set) var likedOverrides: [String: Bool] = [:]
    @Published private(set) var pendingTrackIds: Set<String> = []
    private var locallyMutatedTrackIds: Set<String> = []

    func isLiked(_ track: Track) -> Bool {
        likedOverrides[track.id] ?? track.userFavorite
    }

    func isPending(_ track: Track) -> Bool {
        pendingTrackIds.contains(track.id)
    }

    func refreshLikeState(_ track: Track) async {
        guard !locallyMutatedTrackIds.contains(track.id) else { return }
        let indexed = await LibraryCache.shared.containsLike(id: track.id)
        guard !locallyMutatedTrackIds.contains(track.id) else { return }
        likedOverrides[track.id] = track.userFavorite || indexed
    }

    func toggleLike(_ track: Track) async {
        guard !pendingTrackIds.contains(track.id) else { return }
        let previous = isLiked(track)
        let next = !previous
        locallyMutatedTrackIds.insert(track.id)
        likedOverrides[track.id] = next
        pendingTrackIds.insert(track.id)
        defer { pendingTrackIds.remove(track.id) }

        do {
            try await LikeRequest.send(next, track: track)
        } catch {
            likedOverrides[track.id] = previous
            locallyMutatedTrackIds.remove(track.id)
        }
    }
}

struct QueueActionButton: View {
    let track: Track

    @State private var justAdded = false
    @State private var clearTask: Task<Void, Never>?

    var body: some View {
        UtilityActionButton(
            icon: justAdded ? "checkmark" : "text.badge.plus",
            accessibilityLabel: "Add to Up Next"
        ) {
            PlayerService.shared.addToQueue(track)
            justAdded = true
            clearTask?.cancel()
            clearTask = Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                justAdded = false
            }
        }
    }
}

struct AddToPlaylistActionButton: View {
    let track: Track

    @Environment(\.presentAddToPlaylist) private var present

    var body: some View {
        UtilityActionButton(icon: "text.badge.plus", accessibilityLabel: "Add to Playlist") {
            present(PlaylistTrackRef(track: track))
        }
    }
}

struct ShareActionButton: View {
    let track: Track

    @State private var showingShare = false

    var body: some View {
        UtilityActionButton(icon: "qrcode", accessibilityLabel: "Share") {
            showingShare = true
        }
        .fullScreenCover(isPresented: $showingShare) {
            ShareTrackView(track: track)
        }
    }
}

struct ShareTrackView: View {
    let track: Track
    var url: URL?
    var eyebrow = "Share"

    @Environment(\.dismiss) private var dismiss
    @State private var matrix: QRMatrix?
    @FocusState private var closeFocused: Bool
    @ObservedObject private var artworkColors = ArtworkColors.shared

    var body: some View {
        VStack(spacing: Space.roomy) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Eyebrow(text: eyebrow)
                    Text(track.title)
                        .font(.tvTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($closeFocused)
            }

            Spacer()

            VStack(spacing: Space.base) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(artworkColors.current.primary.opacity(0.30))
                        .frame(width: 400, height: 400)
                        .blur(radius: 50)

                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(.white)
                        .frame(width: 380, height: 380)
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
                        .overlay {
                            if let matrix {
                                QRCodeView(matrix: matrix, markColor: artworkColors.current.primary)
                                    .frame(width: 340, height: 340)
                            } else {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(1.5)
                                    .tint(.black.opacity(0.4))
                            }
                        }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(matrix == nil ? "Preparing QR code" : "QR code linking to \(track.title) on SoundCloud")
                Text("Scan to open “\(track.title)” on your phone")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($closeFocused, true)
        .task {
            matrix = QRCodeGenerator.matrix(for: (url ?? track.permalinkURL).absoluteString)
        }
    }
}

struct PanelCloseButton: View {
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.bold))
                .accessibilityLabel("Close")
                .foregroundStyle(focused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .frame(width: Control.circle, height: Control.circle)
                .background(Circle().fill(focused ? Color.scChromeFocus : .clear))
                .liquidGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Circle()))
        .focused($focused)
        .accessibilityLabel("Close")
    }
}
