import Foundation

struct LyricsSignature: Codable, Hashable, Sendable {
    var track: String
    var artist: String
    var album: String?
    var duration: Int?

    var cacheKey: String {
        [LyricsText.normalised(track), LyricsText.normalised(artist), LyricsText.normalised(album ?? ""), duration.map(String.init) ?? "-"]
            .joined(separator: "|")
    }
}

struct LyricsTrackInfo: Hashable, Sendable {
    var title: String
    var uploader: String
    var publisherArtist: String?
    var publisherTitle: String?
    var album: String?
    var duration: TimeInterval
    var isLocal: Bool

    init(title: String, uploader: String, publisherArtist: String? = nil, publisherTitle: String? = nil,
         album: String? = nil, duration: TimeInterval, isLocal: Bool = false) {
        self.title = title
        self.uploader = uploader
        self.publisherArtist = publisherArtist
        self.publisherTitle = publisherTitle
        self.album = album
        self.duration = duration
        self.isLocal = isLocal
    }

    init(track: Track) {
        self.init(
            title: track.title,
            uploader: track.user.username,
            publisherArtist: track.publisher?.artist,
            publisherTitle: track.publisher?.releaseTitle,
            album: track.publisher?.albumTitle,
            duration: track.duration,
            isLocal: track.isLocal
        )
    }

    var isMix: Bool { CollectionKind.classify(trackDurationSeconds: duration) == .set }
}

enum LyricsSignatureDeriver {
    static let maximumCandidates = 3

    static func candidates(for source: LyricsTrackInfo) -> [LyricsSignature] {
        let duration = source.duration > 0 ? Int(source.duration.rounded()) : nil
        let album = source.album.flatMap { LyricsText.nonEmpty(LyricsText.stripTags($0)) }
        var ordered: [LyricsSignature] = []

        func add(_ track: String?, _ artist: String?, album: String? = nil) {
            guard let track = track.flatMap({ LyricsText.nonEmpty($0) }),
                  let artist = artist.flatMap({ LyricsText.nonEmpty($0) }) else { return }
            ordered.append(LyricsSignature(track: track, artist: artist, album: album, duration: duration))
        }

        let cleanedTitle = LyricsText.stripTags(source.title)
        let split = LyricsText.splitArtistTitle(cleanedTitle)
        let uploader = LyricsText.cleanUploader(source.uploader)

        if source.isLocal {
            add(cleanedTitle, LyricsText.stripTags(source.uploader), album: album)
            add(LyricsText.removeFeaturing(cleanedTitle), LyricsText.primaryArtist(source.uploader))
        }

        if let publisherArtist = source.publisherArtist.map(LyricsText.stripTags) {
            let publisherTitle = source.publisherTitle.map(LyricsText.stripTags)
            let title: String
            if let split, LyricsText.similarity(split.artist, publisherArtist) >= 0.5 {
                title = split.title
            } else if let publisherTitle, !LyricsText.normalised(publisherTitle).isEmpty, publisherTitle.count <= cleanedTitle.count + 40 {
                title = LyricsText.splitArtistTitle(publisherTitle)?.title ?? publisherTitle
            } else {
                title = split?.title ?? cleanedTitle
            }
            add(title, publisherArtist, album: album)
            add(LyricsText.removeFeaturing(title), LyricsText.primaryArtist(publisherArtist))
        }

        if let split {
            add(split.title, split.artist, album: album)
            add(LyricsText.removeFeaturing(split.title), LyricsText.primaryArtist(split.artist))
        }

        add(cleanedTitle, uploader, album: album)
        add(LyricsText.removeFeaturing(cleanedTitle), LyricsText.primaryArtist(uploader))

        var seen = Set<String>()
        var unique: [LyricsSignature] = []
        for candidate in ordered {
            let key = LyricsText.normalised(candidate.track) + "|" + LyricsText.normalised(candidate.artist)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(candidate)
        }
        return Array(unique.prefix(maximumCandidates))
    }
}

enum LyricsText {
    private static let dashSeparators = [" - ", " – ", " — ", " -- ", " ~ "]

    private static let junkPatterns: [String] = [
        "free\\s*(dl|download)", "out\\s*now", "premiere", "exclusive", "official(\\s*(music|lyric))?\\s*(video|audio|visuali[sz]er)?",
        "lyrics?(\\s*video)?", "audio", "video", "visuali[sz]er", "hq", "hd", "4k", "explicit", "clean", "extended\\s*mix",
        "original\\s*mix", "radio\\s*edit", "click\\s*buy[^)\\]]*", "buy\\s*=[^)\\]]*", "supported\\s*by[^)\\]]*", "out\\s*on[^)\\]]*", "prod\\.?\\s*(by)?[^)\\]]*",
        "produced\\s*by[^)\\]]*", "m/v", "mv",
    ]

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stripTags(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*[^*]{1,40}\\*", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "^\\s*(premiere|exclusive|free\\s*(dl|download))\\s*[:|\\-–]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        let junk = "(" + junkPatterns.joined(separator: "|") + ")"
        result = result.replacingOccurrences(of: "\\s*[\\[(【]\\s*\(junk)\\s*[\\])】]", with: " ", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s*[|｜]\\s*(free|out|buy|premiere|support).*$", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "#\\S+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|:")))
    }

    static func splitArtistTitle(_ text: String) -> (artist: String, title: String)? {
        for separator in dashSeparators {
            guard let range = text.range(of: separator) else { continue }
            let artist = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty, !title.isEmpty, artist.count <= 80 else { continue }
            return (artist, title)
        }
        return nil
    }

    static func removeFeaturing(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "\\s*[(\\[]\\s*(feat\\.?|ft\\.?|featuring|with)\\s[^)\\]]*[)\\]]",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "\\s+(feat\\.?|ft\\.?|featuring)\\s.*?(?=\\s*[(\\[]|$)",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func primaryArtist(_ text: String) -> String {
        let pattern = "\\s*(,|&|\\bx\\b|\\bvs\\.?|\\bfeat\\.?|\\bft\\.?|\\bfeaturing\\b|\\band\\b|\\bwith\\b).*$"
        let primary = removeFeaturing(text).replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        return primary.trimmingCharacters(in: .whitespaces).isEmpty ? text : primary.trimmingCharacters(in: .whitespaces)
    }

    static func cleanUploader(_ text: String) -> String {
        var result = stripTags(text)
        result = result.replacingOccurrences(of: "\\s*(official|music|vevo|records|recordings|tv)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        if result.hasSuffix("Official") || result.hasSuffix("VEVO") {
            result = String(result.dropLast(result.hasSuffix("VEVO") ? 4 : 8))
        }
        return result.trimmingCharacters(in: .whitespaces).isEmpty ? text : result.trimmingCharacters(in: .whitespaces)
    }

    static func normalised(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB"))
        let replaced = folded.replacingOccurrences(of: "&", with: " and ")
        let scalars = replaced.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(normalised(text).split(separator: " ").map(String.init))
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalised(lhs)
        let b = normalised(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.replacingOccurrences(of: " ", with: "") == b.replacingOccurrences(of: " ", with: "") { return 0.95 }
        let left = tokens(lhs)
        let right = tokens(rhs)
        let shared = Double(left.intersection(right).count)
        let jaccard = shared / Double(left.union(right).count)
        let containment = shared / Double(min(left.count, right.count))
        return max(jaccard, containment * 0.85)
    }
}
