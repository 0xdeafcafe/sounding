// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnalysisModelTrainer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0")
    ],
    targets: [
        .executableTarget(
            name: "AnalysisModelTrainer",
            dependencies: [.product(name: "MLX", package: "mlx-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
