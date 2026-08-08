// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AILimitBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ai-limit-bar", targets: ["CodexLimitBar"]),
    ],
    targets: [
        .target(name: "CodexLimitCore"),
        .executableTarget(
            name: "CodexLimitBar",
            dependencies: ["CodexLimitCore"]
        ),
        .testTarget(
            name: "CodexLimitCoreTests",
            dependencies: ["CodexLimitCore"]
        ),
    ]
)
