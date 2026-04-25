// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LocalAIWorkspace",
    platforms: [
        .iOS(.v26),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LocalAIWorkspace",
            targets: ["LocalAIWorkspace"]
        )
    ],
    targets: [
        .target(
            name: "LocalAIWorkspace"
        ),
        .testTarget(
            name: "LocalAIWorkspaceTests",
            dependencies: ["LocalAIWorkspace"]
        )
    ],
    swiftLanguageModes: [.v6]
)
