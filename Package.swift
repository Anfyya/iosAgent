// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LocalAIWorkspace",
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
