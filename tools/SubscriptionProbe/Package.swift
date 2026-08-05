// swift-tools-version: 5.9
import PackageDescription

// A macOS CLI for exercising the app's SoundCloud subscription logic outside
// the app.
//
// `SubscriptionService.swift` and `User.swift` are **symlinks to the real app
// sources**, not copies — this compiles the code that actually ships, so the
// self-test here and the one printed under `SOUNDING_TV_MIXTEST=1` can never
// drift apart. `AppStubs.swift` supplies the few app-only seams those two
// files reference (the credential source and the `.sessionExpired`
// notification); everything the tier logic depends on is real.
//
// Not part of `SoundingTV.xcodeproj` and deliberately outside it — this adds
// no target, no scheme, and no `project.pbxproj` change.
let package = Package(
    name: "SubscriptionProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SubscriptionProbe",
            path: "Sources/SubscriptionProbe",
            swiftSettings: [
                // `SubscriptionSelfTest` lives behind `#if DEBUG`. SwiftPM
                // does not define DEBUG for Swift targets on its own, so the
                // self-test would silently vanish without this.
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
    ]
)
