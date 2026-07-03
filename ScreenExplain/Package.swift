// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenExplain",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.26.0"))
    ],
    targets: [
        .executableTarget(
            name: "ScreenExplain",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox")
            ],
            path: "Sources/ScreenExplain",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
