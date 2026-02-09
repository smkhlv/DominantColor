// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DominantColorKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DominantColorKit",
            targets: ["DominantColorKit"]
        )
    ],
    targets: [
        .target(
            name: "DominantColorKit",
            resources: [
                .process("Metal")
            ]
        )
    ]
)
