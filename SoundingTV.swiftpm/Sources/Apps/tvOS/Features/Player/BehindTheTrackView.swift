import SwiftUI

struct BehindTheTrackView: View {
    let track: Track
    let palette: ArtworkColors.Palette

    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool
    @StateObject private var related = RelatedTracksStore()
    @State private var about: TrackAbout?
    @State private var showingShare = false

    private var model: SCBehindTrackModel { SCBehindTrackModel(track: track, about: about) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                header

                trackActionsRow

                if let description = track.description, !description.isEmpty {
                    DescriptionSection(description: description, tint: palette.accent)
                }

                sectionsRow

                uploaderCard

                QuietTextButton(title: "Open on SoundCloud", tint: palette.accent) {
                    showingShare = true
                }

                relatedSection
            }
            .padding(Space.page)
            .padding(.bottom, Space.roomy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Color.scBackground
                RadialGradient(
                    colors: [palette.primary.opacity(0.20), .clear],
                    center: .topLeading, startRadius: 40, endRadius: 1000
                )
            }
            .ignoresSafeArea()
        )
        .defaultFocus($closeFocused, true)
        .fullScreenCover(isPresented: $showingShare) {
            ShareTrackView(track: track)
        }
        .task(id: track.id) {
            await related.load(for: track)
        }
        .task(id: track.id) {
            about = try? await SoundCloudAPI.shared.getTrackAbout(trackId: track.id)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.tight) {
                SCEyebrow("Behind This Track", tint: palette.accent, style: .tv)
                Text(track.title)
                    .font(.tvTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(track.user.displayName)
                    .font(.tvHeadline)
                    .foregroundStyle(Color.scTextSecondary)
            }
            Spacer()
            PanelCloseButton { dismiss() }
                .focused($closeFocused)
        }
    }

    private var trackActionsRow: some View {
        HStack(spacing: Spacing.sm) {
            QueueActionButton(track: track)
            AddToPlaylistActionButton(track: track)
            ShareActionButton(track: track)
        }
        .focusSection()
    }

    // Exactly two readable sections, equal cards, aligned baselines.
    private var sectionsRow: some View {
        HStack(alignment: .top, spacing: Space.base) {
            SectionCard(title: "Engagement", tint: palette.accent) {
                SCStatsStrip(model: model, style: .tv)
            }

            SectionCard(title: "Track Facts", tint: palette.accent) {
                VStack(alignment: .leading, spacing: Space.snug) {
                    if !factsChips.isEmpty {
                        FlowChips {
                            ForEach(factsChips, id: \.self) { chip in
                                InfoChip(text: chip)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.hair) {
                        factLine(label: "Uploaded", value: model.relativeUploadDate)
                        if let releaseDate = about?.releaseDate {
                            factLine(label: "Released", value: Self.uploadedFormatter.string(from: releaseDate))
                        }
                        factLine(label: "Duration", value: track.formattedDuration)
                    }
                }
            }
        }
    }

    // Genre first, then label, then tags — the shared content-model ordering.
    private var factsChips: [String] {
        var chips: [String] = []
        if let genre = about?.genre ?? track.genre {
            chips.append(GenrePresentation.displayName(for: genre))
        }
        if let label = about?.labelName { chips.append(label) }
        let aboutTags = about?.tags ?? []
        chips.append(contentsOf: (aboutTags.isEmpty ? track.tags : aboutTags).prefix(8))
        if about?.isExplicit == true { chips.append("Explicit") }
        return chips
    }

    private func factLine(label: String, value: String) -> some View {
        HStack(spacing: Space.tight) {
            Text(label.uppercased())
                .font(.tvMini)
                .foregroundStyle(Color.scTextTertiary)
            Text(value)
                .font(.tvCallout)
                .foregroundStyle(Color.scTextSecondary)
        }
    }

    private static let uploadedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private var uploaderCard: some View {
        HStack(spacing: Space.base) {
            ArtworkImage(url: track.user.largeAvatarURL, icon: "person.fill")
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .kyleCrowned(user: track.user, context: track.user.displayName)

            VStack(alignment: .leading, spacing: Space.hair) {
                SCEyebrow("Uploaded By", tint: palette.accent, style: .tv)
                Text(track.user.displayName)
                    .font(.tvHeadline)
                    .foregroundStyle(.white)
                Text("\(track.user.formattedFollowers) followers · \(track.user.formattedTracks) tracks")
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
            }

            Spacer(minLength: Space.base)

            UtilityActionButton(
                icon: "play.fill",
                label: "More from \(track.user.displayName)",
                accessibilityLabel: "Play more from \(track.user.displayName)"
            ) {
                Task {
                    await PlayActions.play(user: track.user)
                    dismiss()
                }
            }
        }
        .padding(Space.base)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .focusSection()
    }

    @ViewBuilder
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            SCEyebrow(
                related.isFromArtist ? "More From \(track.user.displayName)" : "Related Tracks",
                tint: palette.accent,
                style: .tv
            )

            switch related.state {
            case .idle, .loading:
                StatusRow {
                    HStack(spacing: Space.snug) {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                        Text("Loading…")
                            .font(.tvBody)
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
            case .failed:
                StatusRow {
                    Text("Couldn't load related tracks.")
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                }
            case .loaded where related.tracks.isEmpty:
                StatusRow {
                    Text("Nothing else to suggest here yet.")
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                }
            case .loaded:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.snug) {
                        ForEach(related.tracks.prefix(12)) { relatedTrack in
                            RelatedTrackCard(track: relatedTrack) {
                                Task {
                                    await PlayerService.shared.play(relatedTrack, in: related.tracks)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
        }
        .focusSection()
    }
}

// One flat card per section — content, not chrome, so never glass.
private struct SectionCard<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            SCEyebrow(title, tint: tint, style: .tv)
            content
        }
        .padding(Space.base)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

// Quiet accent-text action ("More", "Open on SoundCloud") with the §7 focus ring.
private struct QuietTextButton: View {
    let title: String
    var tint: Color
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .font(.tvCalloutEmph)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.snug)
            .padding(.vertical, Space.tight)
            .scFocus(focused, in: Capsule(), reduceMotion: reduceMotion)
            .contentShape(Capsule())
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
    }
}

// Description capped at four lines with an in-place More/Less disclosure.
private struct DescriptionSection: View {
    let description: String
    let tint: Color

    @State private var expanded = false
    @State private var isTruncated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SCEyebrow("Description", tint: tint, style: .tv)
            Text(description)
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: 1200, alignment: .leading)
                .background(truncationMeasure)
            if isTruncated || expanded {
                QuietTextButton(title: expanded ? "Less" : "More", tint: tint) {
                    withAnimation(reduceMotion ? nil : .smoothEase) { expanded.toggle() }
                }
            }
        }
    }

    // Measures the full-height text behind the clamped one so "More" only
    // appears when the description actually truncates.
    private var truncationMeasure: some View {
        GeometryReader { clipped in
            Text(description)
                .font(.tvBody)
                .frame(maxWidth: 1200, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { full in
                        Color.clear.onAppear {
                            isTruncated = full.size.height > clipped.size.height + 1
                        }
                    }
                )
                .hidden()
        }
    }
}

private struct InfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.tvCaptionEmph)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, Space.snug)
            .padding(.vertical, Space.tight)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

private struct FlowChips: Layout {
    var spacing: CGFloat = Space.tight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                totalHeight += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct RelatedTrackCard: View {
    let track: Track
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ArtworkImage(url: track.artworkURL)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .kyleCrowned(user: track.user, context: track.title)

            Text(track.title)
                .font(.tvCaptionEmph)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
            Text(track.user.displayName)
                .font(.tvCaption)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)
        }
        .frame(width: 200, alignment: .leading)
        .scFocus(focused, cornerRadius: Corner.control, reduceMotion: reduceMotion)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
    }
}

@MainActor
final class RelatedTracksStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isFromArtist = false
    @Published private(set) var state: CommentsLoadState = .idle

    private var loadedTrackId: String?

    func load(for track: Track) async {
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        state = .loading
        tracks = []

        if let page = try? await SoundCloudAPI.shared.getRelatedTracks(trackId: track.id),
           !page.collection.isEmpty {
            tracks = page.collection.filter { $0.id != track.id }
            isFromArtist = false
            state = .loaded
            return
        }

        guard let page = try? await SoundCloudAPI.shared.getUserTracks(userId: track.user.id) else {
            state = .failed
            return
        }
        tracks = page.collection.filter { $0.id != track.id }
        isFromArtist = true
        state = .loaded
    }
}

private struct StatusRow<Content: View>: View {
    @ViewBuilder var content: Content

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.vertical, Space.base)
            .padding(.horizontal, Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scFocus(focused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
    }
}
