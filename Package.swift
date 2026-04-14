// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zspeak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.30.6"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "zspeak",
            dependencies: [
                "FluidAudio",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "zspeak",
            exclude: ["Info.plist", "zspeak.entitlements"]
        ),
        .testTarget(
            name: "zspeakTests",
            dependencies: ["zspeak"],
            path: "Tests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
