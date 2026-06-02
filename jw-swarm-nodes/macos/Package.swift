// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JWSwarmNode",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.9453.0")),
    ],
    targets: [
        .executableTarget(
            name: "JWSwarmNode",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift"),
            ],
            path: "Sources/JWSwarmNode",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
            ]
        ),
    ]
)
