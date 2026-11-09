import SwiftUI

struct CollectionReleaseInfo: Equatable {
    var lines: [String]

    init(playlist: Playlist, tracks: [Track], showsSummary: Bool = true) {
        var lines: [String] = []

        if let dateLine = Self.dateLine(playlist) { lines.append(dateLine) }

        if showsSummary {
            let count = max(playlist.totalTrackCount, tracks.count)
            if count > 0 {
                let seconds = playlist.duration > 0 ? playlist.duration : tracks.reduce(0) { $0 + $1.duration }
                lines.append(Self.countText(count, seconds: seconds))
            }
        }

        let publishers = tracks.compactMap(\.publisher)
        let year = playlist.releaseDate.map { String(Calendar.current.component(.year, from: $0)) }
        if let pLine = Self.mostCommon(publishers.compactMap(\.pLine)) {
            lines.append(Self.marked(pLine, symbol: "℗", alias: "(P)"))
            if let label = playlist.labelName, !pLine.localizedCaseInsensitiveContains(label) {
                lines.append(label)
            }
        } else if let label = playlist.labelName ?? Self.mostCommon(publishers.compactMap(\.publisher)) {
            lines.append((["℗", year, label] as [String?]).compactMap { $0 }.joined(separator: " "))
        }
        if let cLine = Self.mostCommon(publishers.compactMap(\.cLine)) {
            lines.append(Self.marked(cLine, symbol: "©", alias: "(C)"))
        }
        if let license = Self.license(playlist.license) {
            lines.append(license)
        }
        self.lines = lines
    }

    init(local collection: LocalCollection, showsSummary: Bool = true) {
        var lines: [String] = []
        let genres = collection.tracks.compactMap { track -> String? in
            guard let genre = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty else { return nil }
            return genre
        }
        if let genre = Self.mostCommon(genres) {
            lines.append(genre)
        }
        if showsSummary, !collection.tracks.isEmpty {
            lines.append(Self.countText(collection.tracks.count, seconds: collection.tracks.reduce(0) { $0 + $1.duration }))
        }
        self.lines = lines
    }

    var isEmpty: Bool { lines.isEmpty }

    private static func countText(_ count: Int, seconds: Double) -> String {
        var parts = ["\(count) \(count == 1 ? "track" : "tracks")"]
        if seconds >= 60 {
            parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
        }
        return parts.joined(separator: " · ")
    }

    private static func dateLine(_ playlist: Playlist) -> String? {
        let word = playlist.releaseTypeWord
        if let released = playlist.releaseDate {
            return "\(word) released \(released.formatted(.dateTime.day().month(.wide).year()))"
        }
        guard !playlist.permalinkURL.isFileURL else { return nil }
        let verb = CollectionPageKind(playlist: playlist) == .album ? "posted" : "created"
        return "\(word) \(verb) \(playlist.createdAt.formatted(.dateTime.day().month(.wide).year()))"
    }

    private static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return values.first { counts[$0] == counts.values.max() }
    }

    private static func marked(_ text: String, symbol: String, alias: String) -> String {
        if text.hasPrefix(symbol) { return text }
        if text.uppercased().hasPrefix(alias) {
            return symbol + text.dropFirst(alias.count)
        }
        return "\(symbol) \(text)"
    }

    private static func license(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), raw != "all-rights-reserved" else { return nil }
        if raw == "no-rights-reserved" { return "No Rights Reserved" }
        guard raw.hasPrefix("cc-") else { return nil }
        return "Creative Commons " + raw.dropFirst(3).uppercased()
    }
}

struct CollectionReleaseFooter: View {
    let info: CollectionReleaseInfo
    var font: Font = .footnote
    var spacing: CGFloat = 2

    var body: some View {
        if !info.isEmpty {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(info.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

struct CollectionArtistLabel: View {
    let user: User
    var avatarSize: CGFloat = 64
    var spacing: CGFloat = 14
    var nameFont: Font = .headline
    var detailFont: Font = .subheadline
    var showsChevron = true
    var postsMusic = false

    private var bio: String? {
        guard let text = user.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    var body: some View {
        HStack(spacing: spacing) {
            SCArtworkResolver(url: User.customAvatar(user.largeAvatarURL), variant: .standard) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    SoundingArtworkView(identity: user.id, subject: .person)
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.displayName)
                        .lineLimit(1)
                    if user.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                            .accessibilityLabel("Verified")
                    }
                }
                .font(nameFont)
                .foregroundStyle(.primary)
                let counts = user.countsLine(postsMusic: postsMusic)
                if !counts.isEmpty {
                    Text(counts)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let bio {
                    Text(bio)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(detailFont.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows \(user.displayName)")
    }
}

struct CollectionRelatedTrigger: View {
    let action: () -> Void

    var body: some View {
        Color.clear
            .frame(height: 1)
            .accessibilityHidden(true)
            .onAppear(perform: action)
    }
}

#if !os(tvOS)
struct PersonAboutSection: View {
    let user: User
    let style: SCContentStyle
    var inset: CGFloat
    var showConnections: ((ArtistConnectionKind) -> Void)? = nil

    @ObservedObject private var webProfiles = SoundCloudWebProfileStore.shared

    private var bio: String? {
        guard let text = user.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceSnug) {
            Text("About \(user.displayName)")
                .font(style.fontHeadline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            if let bio {
                SoundCloudExpandableText(bio, font: style.fontBody, lineLimit: 4)
                    .textSelection(.enabled)
            }

            if let location = user.locationText {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(style.fontBody)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 24) {
                stat(user.formattedFollowers, label: user.followersCount == 1 ? "Follower" : "Followers", kind: .followers)
                stat(CompactCount.string(user.followingsCount), label: "Following", kind: .following)
                if user.isArtist {
                    stat(user.formattedTracks, label: user.trackCount == 1 ? "Track" : "Tracks", kind: nil)
                }
            }

            SoundCloudFlowLayout(spacing: 16) {
                ForEach(SoundCloudProfileLink.links(for: user, webProfiles: webProfiles.profiles(for: user))) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: link.symbol)
                            .lineLimit(1)
                    }
                }
                Link(destination: user.permalinkURL) {
                    Label("SoundCloud", systemImage: "arrow.up.right.square")
                }
            }
            .font(style.fontBody)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.vertical, 24)
        .background(.fill.quaternary)
        .task(id: user.id) { await webProfiles.load(user) }
    }

    @ViewBuilder
    private func stat(_ value: String, label: String, kind: ArtistConnectionKind?) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(style.fontBodyEmphasis)
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(style.fontCaption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        if let kind, let showConnections {
            Button { showConnections(kind) } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows \(user.displayName)\u{2019}s \(label.lowercased())")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}
#endif
