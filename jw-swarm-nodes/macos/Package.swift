// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JWSwarmNode",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JWSwarmNode",
            path: "Sources/JWSwarmNode",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
            ]
        ),
    ]
)
