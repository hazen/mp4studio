// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP4Studio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MP4StudioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mp4studio-ocr",
            dependencies: ["MP4StudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MP4Studio",
            dependencies: ["MP4StudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MP4StudioCoreTests",
            dependencies: ["MP4StudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
