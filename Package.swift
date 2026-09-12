// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxKey",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VoxKey", targets: ["VoxKeyApp"]),
        .executable(name: "VoxKeyTestHost", targets: ["VoxKeyTestHost"]),
        .library(name: "VoxKeyCore", targets: ["VoxKeyCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10809/llama-b10809-xcframework.zip",
            checksum: "d6813b3b6c73728a19f0bc0d1d7cea04ccdb07f9583c1d930c0b38af2377606d"
        ),
        .target(
            name: "VoxKeyS1",
            dependencies: ["llama"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),
        .target(
            name: "VoxKeyAudioRing",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoxKeyCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "VoxKeyApp",
            dependencies: [
                "VoxKeyS1",
                "VoxKeyCore",
                "VoxKeyAudioRing",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.process("Resources/CaptureCues"), .copy("Resources/GrammarPreparation")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "VoxKeyTestHost",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoxKeyCoreTests",
            dependencies: ["VoxKeyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoxKeyAudioRingTests",
            dependencies: ["VoxKeyAudioRing"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoxKeyAppTests",
            dependencies: ["VoxKeyApp", "VoxKeyCore"],
            resources: [.copy("Fixtures/Grammar")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
