import SwiftUI

struct SCCommentRailMetrics: Sendable {
    var railHeight: CGFloat
    var captionHeight: CGFloat
    var markerDiameter: CGFloat
    var activeMarkerDiameter: CGFloat
    var tapDiameter: CGFloat
    var clusterSpacing: CGFloat
    var passedOpacity: Double
    var stackOpacity: Double
    var stackScale: CGFloat
    var stackOffsetFraction: CGFloat
    var liftShadowColor: Color
    var liftShadowRadius: CGFloat
    var liftShadowY: CGFloat
    /// Diameter for a marker representing more than one comment. Defaults to
    /// `markerDiameter` (stacked-avatar look); the phone rail uses a single
    /// larger avatar with a `+N` badge instead.
    var clusterMarkerDiameter: CGFloat
    /// When set, a marker whose avatar hasn't loaded renders as a small accent
    /// dot of this diameter instead of the generated-artwork placeholder.
    var dotFallbackDiameter: CGFloat?
    /// Clusters show a `+N` count badge on an accent capsule (phone rail).
    var showsCountBadge: Bool

    static func derived(from style: SCContentStyle) -> SCCommentRailMetrics {
        let marker = (style.rowArtworkSize * 0.3).rounded()
        let active = (style.rowArtworkSize * 0.45).rounded()
        return SCCommentRailMetrics(
            railHeight: active + style.spaceTight * 2,
            captionHeight: active + style.spaceTight,
            markerDiameter: marker,
            activeMarkerDiameter: active,
            tapDiameter: active + style.spaceTight,
            clusterSpacing: marker + style.spaceTight,
            passedOpacity: 0.55,
            stackOpacity: 0.7,
            stackScale: 0.85,
            stackOffsetFraction: 0.45,
            liftShadowColor: .black.opacity(0.55),
            liftShadowRadius: style.spaceTight,
            liftShadowY: style.spaceHair / 2,
            clusterMarkerDiameter: marker,
            dotFallbackDiameter: nil,
            showsCountBadge: false
        )
    }

    /// iOS Now Playing rail (ios-design-spec §4.1): 10pt commenter avatars in a
    /// compact rail under the waveform, 6pt accent dot while an avatar loads,
    /// 14pt avatar with a `+N` accent badge for clusters, 26pt spacing.
    static let phoneRail = SCCommentRailMetrics(
        railHeight: 20,
        captionHeight: 24,
        markerDiameter: 10,
        activeMarkerDiameter: 14,
        tapDiameter: 26,
        clusterSpacing: 26,
        passedOpacity: 0.55,
        stackOpacity: 0.7,
        stackScale: 0.85,
        stackOffsetFraction: 0.45,
        liftShadowColor: .black.opacity(0.55),
        liftShadowRadius: 4,
        liftShadowY: 1,
        clusterMarkerDiameter: 14,
        dotFallbackDiameter: 6,
        showsCountBadge: true
    )
}

struct SCCommentCluster: Identifiable, Equatable {
    let threads: [CommentThread]

    static func == (lhs: SCCommentCluster, rhs: SCCommentCluster) -> Bool {
        lhs.threads == rhs.threads
    }

    var id: String { threads.first?.id ?? "" }
    var time: TimeInterval { threads.first?.timeInTrack ?? 0 }
    var representative: Comment? { threads.first?.root }
    var commentCount: Int { threads.reduce(0) { $0 + 1 + $1.replies.count } }

    var secondary: Comment? {
        if threads.count > 1 { return threads[1].root }
        return threads.first?.replies.first
    }

    func fraction(in duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }
}

enum SCCommentTimeline {
    static let leadSeconds: TimeInterval = 1
    static let lingerSeconds: TimeInterval = 4

    static func clusters(
        from threads: [CommentThread],
        duration: TimeInterval,
        width: CGFloat,
        metrics: SCCommentRailMetrics
    ) -> [SCCommentCluster] {
        guard duration > 0, width > 0 else { return [] }
        let timed = threads.filter { $0.timeInTrack != nil }
        guard !timed.isEmpty else { return [] }
        let spacingSeconds = TimeInterval(metrics.clusterSpacing / width) * duration

        var grouped: [[CommentThread]] = []
        for thread in timed {
            let time = thread.timeInTrack ?? 0
            if let anchor = grouped.last?.first?.timeInTrack, time - anchor <= spacingSeconds {
                grouped[grouped.count - 1].append(thread)
            } else {
                grouped.append([thread])
            }
        }
        return grouped.map(SCCommentCluster.init)
    }

    static func active(in clusters: [SCCommentCluster], at time: TimeInterval) -> SCCommentCluster? {
        clusters
            .filter { time >= $0.time - leadSeconds && time <= $0.time + lingerSeconds }
            .min { abs($0.time - time) < abs($1.time - time) }
    }
}

struct SCCommentRail: View {
    let clusters: [SCCommentCluster]
    let duration: TimeInterval
    let playhead: TimeInterval
    var activeClusterID: String?
    var style: SCContentStyle = .tv
    var reduceMotion: Bool = false
    var railMetrics: SCCommentRailMetrics?
    var onSelect: ((SCCommentCluster) -> Void)?
    var onHoverCluster: ((SCCommentCluster?) -> Void)?

    private var metrics: SCCommentRailMetrics { railMetrics ?? .derived(from: style) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(clusters) { cluster in
                    markerCell(cluster, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: metrics.railHeight, alignment: .topLeading)
        }
        .frame(height: metrics.railHeight)
        .scrollClipDisabled()
        .animation(reduceMotion ? nil : SCContentMotion.settle, value: clusters)
        .animation(reduceMotion ? nil : SCContentMotion.focus, value: activeClusterID)
    }

    @ViewBuilder
    private func markerCell(_ cluster: SCCommentCluster, width: CGFloat) -> some View {
        let m = metrics
        let isActive = cluster.id == activeClusterID
        let diameter = m.markerDiameter(for: cluster, isActive: isActive)
        let stackedExtent = diameter * (m.stackOffsetFraction + m.stackScale / 2)
        let halfMarker = max(m.tapDiameter / 2, stackedExtent)
        let x = min(
            max(CGFloat(cluster.fraction(in: duration)) * width, halfMarker),
            max(halfMarker, width - halfMarker)
        )
        let badge = SCCommentMarkerBadge(
            cluster: cluster,
            isActive: isActive,
            isPassed: cluster.time < playhead && !isActive,
            style: style,
            metrics: m
        )
        .frame(width: m.tapDiameter, height: m.railHeight)
        .contentShape(Rectangle())

        Group {
            if let onSelect {
                Button {
                    onSelect(cluster)
                } label: {
                    badge
                }
                .buttonStyle(.plain)
            } else {
                badge.allowsHitTesting(false)
            }
        }
        .modifier(SCCommentHoverReporter { inside in
            onHoverCluster?(inside ? cluster : nil)
        })
        .position(x: x, y: m.railHeight / 2)
        .zIndex(isActive ? 1 : 0)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
        .accessibilityLabel(Self.accessibilityText(for: cluster))
    }

    private static func accessibilityText(for cluster: SCCommentCluster) -> String {
        let clock = CommentFormat.clock(cluster.time)
        guard cluster.commentCount > 1 else {
            let name = cluster.representative?.user.displayName ?? "someone"
            return "Comment from \(name) at \(clock)"
        }
        return "\(cluster.commentCount) comments at \(clock)"
    }
}

private struct SCCommentHoverReporter: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onHover(perform: onChange)
        #else
        content
        #endif
    }
}

extension SCCommentRailMetrics {
    func markerDiameter(for cluster: SCCommentCluster, isActive: Bool) -> CGFloat {
        let base = cluster.commentCount > 1 ? clusterMarkerDiameter : markerDiameter
        return isActive ? max(activeMarkerDiameter, base) : base
    }
}

private struct SCCommentMarkerBadge: View {
    let cluster: SCCommentCluster
    let isActive: Bool
    let isPassed: Bool
    let style: SCContentStyle
    let metrics: SCCommentRailMetrics

    private var diameter: CGFloat {
        metrics.markerDiameter(for: cluster, isActive: isActive)
    }

    var body: some View {
        ZStack {
            if !metrics.showsCountBadge, let secondary = cluster.secondary {
                avatar(secondary, diameter: diameter * metrics.stackScale)
                    .offset(x: diameter * metrics.stackOffsetFraction)
                    .opacity(metrics.stackOpacity)
            }
            if let representative = cluster.representative {
                avatar(representative, diameter: diameter)
                    .overlay(alignment: .topTrailing) {
                        if metrics.showsCountBadge, cluster.commentCount > 1 {
                            Text("+\(cluster.commentCount - 1)")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(style.accentOn)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Capsule(style: .continuous).fill(style.accent))
                                .offset(x: 4, y: -2)
                        }
                    }
            }
        }
        .opacity(isPassed ? metrics.passedOpacity : 1)
        .shadow(
            color: isActive ? metrics.liftShadowColor : .clear,
            radius: isActive ? metrics.liftShadowRadius : 0,
            y: isActive ? metrics.liftShadowY : 0
        )
    }

    private func avatar(_ comment: Comment, diameter: CGFloat) -> some View {
        SCArtworkResolver(url: comment.user.avatarURL) { image in
            if let dot = metrics.dotFallbackDiameter, image == nil {
                Circle()
                    .fill(style.accent)
                    .frame(width: dot, height: dot)
                    .frame(width: diameter, height: diameter)
            } else {
                SCArtwork(
                    image: image,
                    identity: comment.user.username,
                    style: style,
                    cornerRadius: diameter / 2
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(style.separator, lineWidth: 1))
    }
}

struct SCCommentCaption: View {
    let cluster: SCCommentCluster?
    var style: SCContentStyle = .tv
    var reduceMotion: Bool = false

    private var metrics: SCCommentRailMetrics { .derived(from: style) }

    var body: some View {
        ZStack(alignment: .leading) {
            if let cluster, let comment = cluster.representative {
                if reduceMotion {
                    line(cluster: cluster, comment: comment)
                        .id(cluster.id)
                        .transition(.opacity)
                } else {
                    line(cluster: cluster, comment: comment)
                        .id(cluster.id)
                        .transition(.blurReplace)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: metrics.captionHeight)
        .animation(reduceMotion ? nil : SCContentMotion.gentle, value: cluster?.id)
    }

    private func line(cluster: SCCommentCluster, comment: Comment) -> some View {
        HStack(spacing: style.spaceTight) {
            SCArtworkResolver(url: comment.user.avatarURL) { image in
                SCArtwork(
                    image: image,
                    identity: comment.user.username,
                    style: style,
                    cornerRadius: metrics.markerDiameter / 2
                )
            }
            .frame(width: metrics.markerDiameter, height: metrics.markerDiameter)
            .clipShape(Circle())

            Text(comment.user.displayName)
                .font(style.fontCaptionEmphasis)
                .foregroundStyle(style.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            Text(comment.body)
                .font(style.fontCaption)
                .foregroundStyle(style.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if cluster.commentCount > 1 {
                Text("+\(cluster.commentCount - 1)")
                    .font(style.fontCaptionEmphasis)
                    .foregroundStyle(style.accent)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// The phone Now Playing comment bubble (ios-design-spec §4.1): chrome floating
// over content, so glass is correct here — a single shape (rounded rect plus a
// connector tick pointing up at its marker), tinted with the artwork accent.
// Width and placement are the caller's job: min(300, width - 48), below the rail.
struct SCCommentBubble: View {
    let cluster: SCCommentCluster
    var style: SCContentStyle = .phone
    /// Center of the connector tick, measured from the bubble's leading edge.
    var tickOffset: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: style.spaceTight) {
            if let comment = cluster.representative {
                SCArtworkResolver(url: comment.user.avatarURL) { image in
                    SCArtwork(
                        image: image,
                        identity: comment.user.username,
                        style: style,
                        cornerRadius: 10
                    )
                }
                .frame(width: 20, height: 20)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: style.spaceTight) {
                        Text(comment.user.displayName)
                            .font(style.fontCaptionEmphasis)
                            .foregroundStyle(style.textPrimary)
                            .lineLimit(1)
                        Text(CommentFormat.clock(cluster.time))
                            .font(style.fontCaptionEmphasis)
                            .monospacedDigit()
                            .foregroundStyle(style.accent)
                        if cluster.commentCount > 1 {
                            Text("+\(cluster.commentCount - 1)")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(style.accentOn)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Capsule(style: .continuous).fill(style.accent))
                        }
                    }
                    Text(comment.body)
                        .font(style.fontCaption)
                        .foregroundStyle(style.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, style.spaceSnug)
        .padding(.vertical, style.spaceTight)
        .padding(.top, SCBubbleShape.tickHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(style.accent.opacity(0.16)),
            in: SCBubbleShape(cornerRadius: style.cornerCard, tickOffset: tickOffset)
        )
        .accessibilityElement(children: .combine)
    }
}

// Rounded rect with a small triangular tab on its top edge — one continuous
// shape so the bubble and its connector tick are a single glass element.
struct SCBubbleShape: Shape {
    var cornerRadius: CGFloat
    var tickOffset: CGFloat

    static let tickWidth: CGFloat = 12
    static let tickHeight: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let tickW = Self.tickWidth
        let tickH = min(Self.tickHeight, rect.height / 3)
        let bodyRect = CGRect(
            x: rect.minX, y: rect.minY + tickH,
            width: rect.width, height: rect.height - tickH
        )
        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius, style: .continuous)
        let x = min(
            max(tickOffset, cornerRadius + tickW / 2),
            rect.width - cornerRadius - tickW / 2
        )
        path.move(to: CGPoint(x: x - tickW / 2, y: bodyRect.minY + 1))
        path.addLine(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x + tickW / 2, y: bodyRect.minY + 1))
        path.closeSubpath()
        return path
    }
}
