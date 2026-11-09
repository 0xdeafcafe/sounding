import Foundation

struct SonosICYInterleaver: Sendable {
    static let defaultMetaInterval = 16_000

    let metaInterval: Int
    private(set) var bytesUntilMetadata: Int
    private var lastSentTitle: String?

    init(metaInterval: Int = Self.defaultMetaInterval) {
        self.metaInterval = metaInterval
        bytesUntilMetadata = metaInterval
    }

    mutating func interleave(_ audio: Data, title: String) -> Data {
        var result = Data(capacity: audio.count + 64)
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let take = min(bytesUntilMetadata, audio.endIndex - offset)
            result.append(audio[offset..<(offset + take)])
            offset += take
            bytesUntilMetadata -= take
            if bytesUntilMetadata == 0 {
                if title == lastSentTitle {
                    result.append(0)
                } else {
                    result.append(Self.metadataBlock(title: title))
                    lastSentTitle = title
                }
                bytesUntilMetadata = metaInterval
            }
        }
        return result
    }

    static func metadataBlock(title: String) -> Data {
        let cleaned = title
            .replacingOccurrences(of: "'", with: "\u{2019}")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var payload = Data("StreamTitle='".utf8)
        var titleBytes = Data(cleaned.utf8)
        let limit = 255 * 16 - payload.count - 2
        if titleBytes.count > limit {
            var truncated = ""
            for character in cleaned {
                if truncated.utf8.count + String(character).utf8.count > limit { break }
                truncated.append(character)
            }
            titleBytes = Data(truncated.utf8)
        }
        payload.append(titleBytes)
        payload.append(contentsOf: Array("';".utf8))
        let blocks = (payload.count + 15) / 16
        payload.append(Data(count: blocks * 16 - payload.count))
        var block = Data([UInt8(blocks)])
        block.append(payload)
        return block
    }
}
