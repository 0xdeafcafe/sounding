// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SoundingTV",
    // Not used to build the apps — see docs/source-tree.md; this manifest exists only
    // so the folder opens as a Swift Playgrounds package. It matters anyway,
    // because **SourceKit resolves every file under `Sources/` against this
    // manifest rather than against the Xcode targets**. While it said
    // `.tvOS(.v17)` and named no other platform, the editor reported a steady
    // stream of errors that no build ever produced: `Font.tvBodyEmph` missing,
    // `StatusPanel`/`SCCardButtonStyle`/`WaveformService` "not in scope",
    // `MusicUnderstandingSession` and the tvOS 27 `AVAudioSession` symbols
    // "only available in iOS 27.0 or newer", and "Loading the standard library
    // failed" on every macOS file. Agents repeatedly chased those phantoms.
    //
    // These four floors must track the targets' real deployment targets
    // (currently 27.0 for tvOS/macOS/watchOS, 26.5 for iOS), or the diagnostics
    // start lying again. PackageDescription has no `.v26_5`, so `.v26` is the
    // closest available floor for the iOS target.
    platforms: [
        .tvOS(.v27),
        .iOS(.v26),
        .macOS(.v27),
        .watchOS(.v27)
    ],
    products: [
        .library(
            name: "SoundingTV",
            targets: ["SoundingTV"]
        )
    ],
    targets: [
        .target(
            name: "SoundingTV",
            path: "Sources"
        )
    ]
)
