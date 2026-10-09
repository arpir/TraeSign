// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TraeSign",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "TraeSign",
            path: "Sources/TraeSign",
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
                .unsafeFlags(["-framework", "WebKit"]),
                .unsafeFlags(["-framework", "CryptoKit"]),
                .unsafeFlags(["-framework", "Security"]),
            ]
        )
    ]
)
