import SwiftUI

enum SCTrackActivity: Equatable, Sendable {
    case none
    case loading
    case playing
    case paused
}

enum SCTrackListLeading: Equatable, Sendable {
    case number
    case artwork
}

typealias CollectionTrackRow = SCTrackListItem

struct SCTrackListItem: Identifiable, Equatable {
    let id: String
    var number: Int
    let title: String
    var artist: String?
    var analysis: String?
    var duration: String
    var artworkURL: URL?
    var isPlayable: Bool
    var accessibilityLabel: String
    var mark: SoundCloudTrackMark?

    init(
        id: String,
        number: Int,
        title: String,
        artist: String?,
        analysis: String?,
        duration: String,
        artworkURL: URL? = nil,
        isPlayable: Bool,
        accessibilityLabel: String,
        mark: SoundCloudTrackMark? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.artist = artist
        self.analysis = analysis
        self.duration = duration
        self.artworkURL = artworkURL
        self.isPlayable = isPlayable
        self.accessibilityLabel = accessibilityLabel
        self.mark = mark
    }

    @MainActor
    init(track: Track, number: Int = 0, showsArtist: Bool = true, analysis summary: TrackAnalysisSummary? = nil, detail: String? = nil) {
        let isPlayable = track.streamURL != nil
        let duration = SubscriptionService.shared.displayedDuration(for: track)
        let mark = SoundCloudTrackMark.of(track, showsPreview: false)
        let spoken = TrackAccessibility.label(
            title: track.title,
            artist: track.user.displayName,
            duration: isPlayable ? duration : nil,
            isDownloaded: DownloadManager.shared.entries[track.id]?.isDownloaded == true,
            isUnavailable: !isPlayable,
            analysis: summary
        )
        var label = number > 0 ? "\(number). " + spoken : spoken
        if let mark { label += ", " + mark.spokenLabel }
        self.init(
            id: track.id,
            number: number,
            title: track.title,
            artist: showsArtist ? track.user.displayName : nil,
            analysis: detail ?? Self.analysisText(summary),
            duration: duration,
            artworkURL: track.artworkURL,
            isPlayable: isPlayable,
            accessibilityLabel: label,
            mark: mark
        )
    }

    static func analysisText(_ summary: TrackAnalysisSummary?) -> String? {
        guard let summary else { return nil }
        var parts: [String] = []
        if let bpm = summary.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key = summary.key { parts.append(key.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SCTrackListMetrics {
    var artworkSize: CGFloat
    var artworkCorner: CGFloat
    var numberWidth: CGFloat
    var minHeight: CGFloat
    var spacing: CGFloat
    var verticalPadding: CGFloat
    var horizontalPadding: CGFloat = 0
    var titleFont: Font
    var subtitleFont: Font
    var detailFont: Font
    var numberFont: Font
    var indicatorFont: Font
    var durationMinWidth: CGFloat
    var isSingleLine = false
    var showsAnalysisInline = true
    var invertsOnFocus = false
    var primary: Color = .primary
    var secondary: Color = .secondary
    var tertiary: Color = Color.primary.opacity(0.5)
    var focusedPrimary: Color = .primary
    var focusedSecondary: Color = .secondary

    static let phone = SCTrackListMetrics(
        artworkSize: 44,
        artworkCorner: 6,
        numberWidth: 28,
        minHeight: 52,
        spacing: 12,
        verticalPadding: 3,
        titleFont: .body,
        subtitleFont: .subheadline,
        detailFont: .subheadline,
        numberFont: .body,
        indicatorFont: .subheadline.weight(.semibold),
        durationMinWidth: 40
    )

    static let phoneRoomy = SCTrackListMetrics(
        artworkSize: 48,
        artworkCorner: 6,
        numberWidth: 28,
        minHeight: 56,
        spacing: 12,
        verticalPadding: 4,
        titleFont: .body,
        subtitleFont: .subheadline,
        detailFont: .subheadline,
        numberFont: .body,
        indicatorFont: .subheadline.weight(.semibold),
        durationMinWidth: 40
    )

    static let phoneSearch: SCTrackListMetrics = {
        var metrics = phoneRoomy
        metrics.artworkSize = 56
        metrics.artworkCorner = 7
        metrics.minHeight = 64
        return metrics
    }()

    static let phoneDense = SCTrackListMetrics(
        artworkSize: 30,
        artworkCorner: 5,
        numberWidth: 26,
        minHeight: 38,
        spacing: 12,
        verticalPadding: 1,
        titleFont: .body,
        subtitleFont: .body,
        detailFont: .subheadline.monospacedDigit(),
        numberFont: .subheadline,
        indicatorFont: .footnote.weight(.semibold),
        durationMinWidth: 38,
        isSingleLine: true
    )

    static let mac = SCTrackListMetrics(
        artworkSize: 34,
        artworkCorner: 4,
        numberWidth: 24,
        minHeight: 44,
        spacing: 10,
        verticalPadding: 3,
        titleFont: .body,
        subtitleFont: .subheadline,
        detailFont: .subheadline,
        numberFont: .subheadline,
        indicatorFont: .caption.weight(.bold),
        durationMinWidth: 44
    )
}

struct SCTrackListRow<Accessories: View>: View {
    let item: SCTrackListItem
    var leading: SCTrackListLeading = .artwork
    var activity: SCTrackActivity = .none
    let metrics: SCTrackListMetrics
    var crownUser: User?
    @ViewBuilder var accessories: () -> Accessories

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var inverted: Bool { metrics.invertsOnFocus && isFocused }
    private var primary: Color { inverted ? metrics.focusedPrimary : metrics.primary }
    private var secondary: Color { inverted ? metrics.focusedSecondary : metrics.secondary }
    private var tertiary: Color { inverted ? metrics.focusedSecondary.opacity(0.8) : metrics.tertiary }
    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: metrics.spacing) {
            leadingView
            labels
                .frame(maxWidth: .infinity, alignment: .leading)
            accessories()
            if item.isPlayable {
                if !isLarge {
                    Text(item.duration)
                        .font(metrics.detailFont)
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .frame(minWidth: metrics.durationMinWidth, alignment: .trailing)
                }
            } else {
                Image(systemName: "lock.fill")
                    .font(metrics.detailFont)
                    .foregroundStyle(tertiary)
                    .frame(minWidth: metrics.durationMinWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, metrics.verticalPadding)
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(minHeight: metrics.minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(item.isPlayable ? 1 : 0.5)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .number:
            ZStack {
                if activity == .none {
                    Text("\(item.number)")
                        .font(metrics.numberFont)
                        .monospacedDigit()
                        .foregroundStyle(tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    indicator(tinted: !inverted)
                }
            }
            .frame(width: metrics.numberWidth, alignment: .center)
        case .artwork:
            SCArtworkResolver(url: item.artworkURL, variant: metrics.artworkSize <= 64 ? .thumbnail : .standard) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    SoundingArtworkView(identity: item.id, subject: .track, displaySize: CGSize(width: metrics.artworkSize, height: metrics.artworkSize))
                }
            }
            .frame(width: metrics.artworkSize, height: metrics.artworkSize)
            .overlay {
                if activity != .none {
                    ZStack {
                        Color.black.opacity(0.45)
                        indicator(tinted: false)
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.artworkCorner, style: .continuous))
            .kyleCrowned(user: crownUser, context: item.title)
        }
    }

    @ViewBuilder
    private func indicator(tinted: Bool) -> some View {
        switch activity {
        case .none:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading")
        case .playing:
            styled(Image(systemName: "waveform"), tinted: tinted)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityLabel("Now Playing")
        case .paused:
            styled(Image(systemName: "waveform"), tinted: tinted)
                .accessibilityLabel("Paused")
        }
    }

    @ViewBuilder
    private func styled(_ image: Image, tinted: Bool) -> some View {
        if tinted {
            image.font(metrics.indicatorFont).collectionAccentTinted()
        } else if inverted {
            image.font(metrics.indicatorFont).foregroundStyle(primary)
        } else {
            image.font(metrics.indicatorFont)
        }
    }

    @ViewBuilder
    private var labels: some View {
        if metrics.isSingleLine && !isLarge {
            HStack(spacing: metrics.spacing) {
                HStack(spacing: 6) {
                    Group {
                        if let artist = item.artist {
                            Text("\(Text(item.title).foregroundStyle(primary)) · \(Text(artist).foregroundStyle(secondary))")
                        } else {
                            Text(item.title).foregroundStyle(primary)
                        }
                    }
                    .font(metrics.titleFont)
                    .lineLimit(1)
                    SoundCloudTrackBadge(mark: item.mark, color: secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if metrics.showsAnalysisInline, let analysis = item.analysis {
                    Text(analysis)
                        .font(metrics.detailFont)
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(metrics.titleFont)
                        .foregroundStyle(primary)
                        .lineLimit(isLarge ? 4 : 1)
                    SoundCloudTrackBadge(mark: item.mark, color: secondary)
                }
                if let line = secondaryLine {
                    Text(line)
                        .font(metrics.subtitleFont)
                        .foregroundStyle(secondary)
                        .monospacedDigit()
                        .lineLimit(isLarge ? 3 : 1)
                }
                if isLarge, item.isPlayable {
                    Text(item.duration)
                        .font(metrics.subtitleFont)
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                }
            }
        }
    }

    private var secondaryLine: String? {
        let analysis = metrics.showsAnalysisInline ? item.analysis : nil
        let parts = [item.artist, analysis].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension SCTrackListRow where Accessories == EmptyView {
    init(
        item: SCTrackListItem,
        leading: SCTrackListLeading = .artwork,
        activity: SCTrackActivity = .none,
        metrics: SCTrackListMetrics,
        crownUser: User? = nil
    ) {
        self.init(item: item, leading: leading, activity: activity, metrics: metrics, crownUser: crownUser, accessories: { EmptyView() })
    }
}

#if !os(tvOS)
struct SCTrackListMoreMenu<Items: View>: View {
    let title: String
    var size: CGFloat = 44
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel("More for \(title)")
    }
}
#endif
