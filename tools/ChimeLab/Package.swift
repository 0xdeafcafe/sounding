// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChimeLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ChimeLab",
            path: "Sources/ChimeLab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
