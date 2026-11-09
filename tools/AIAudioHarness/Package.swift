// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIAudioHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0")
    ],
    targets: [
        .executableTarget(
            name: "AIAudioHarness",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
