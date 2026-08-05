import Foundation
@testable import SoundingTV

#if DEBUG
enum DownloadSourceSelfTest {
    private static func make(
        _ preset: String,
        _ proto: String,
        _ mime: String,
        quality: String? = nil
    ) -> Transcoding {
        Transcoding(
            url: URL(string: "https://example.invalid/\(preset)")!,
            preset: preset,
            duration: 180_000,
            quality: quality,
            snipped: false,
            format: Transcoding.Format(protocol: proto, mimeType: mime)
        )
    }

    static func run() -> DownloadBudgetSelfTest.Report {
        var report = DownloadBudgetSelfTest.Report()

        func expect(_ name: String, _ ladder: [Transcoding], picksProgressive expectHLS: Bool, preset: String) {
            let got = DownloadSourceSelection.choose(from: ladder)
            if got?.transcoding.preset == preset, got?.isHLS == expectHLS {
                report.lines.append("\(name) → \(preset) (isHLS: \(expectHLS))")
            } else {
                report.failures.append(
                    "\(name): expected \(preset) (isHLS: \(expectHLS)), got \(got?.transcoding.preset ?? "nil") (isHLS: \(got?.isHLS.description ?? "nil"))"
                )
            }
        }

        // Same ladder as `TranscodingRankSelfTest`'s "go+ ladder": playback
        // would pick the HLS `aac_256k` (higher `playbackRank`), but
        // downloads must prefer the progressive `mp3_1_0` instead, since
        // `URLSessionDownloadTask` can't turn an HLS playlist into one file.
        expect("prefers progressive over a higher-ranked HLS source", [
            make("mp3_1_0", "progressive", "audio/mpeg"),
            make("mp3_1_0", "hls", "audio/mpeg"),
            make("aac_256k", "hls", "audio/mp4; codecs=\"mp4a.40.2\"", quality: "hq")
        ], picksProgressive: false, preset: "mp3_1_0")

        // No progressive offered at all: falls back to the best HLS source.
        expect("falls back to HLS when nothing progressive exists", [
            make("aac_256k", "hls", "audio/mp4; codecs=\"mp4a.40.2\"", quality: "hq"),
            make("opus_0_0", "hls", "audio/ogg; codecs=\"opus\"")
        ], picksProgressive: true, preset: "aac_256k")

        // Opus is excluded from both branches regardless of ranking or
        // protocol — no decoder anywhere in this app.
        let opusOnly = [make("opus_0_0", "progressive", "audio/ogg; codecs=\"opus\"")]
        if DownloadSourceSelection.choose(from: opusOnly) == nil {
            report.lines.append("Opus-only ladder → nil (correctly refused)")
        } else {
            report.failures.append("Opus-only ladder should refuse to choose a source")
        }

        return report
    }
}
#endif
