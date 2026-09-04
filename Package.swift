// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PureSwiftQR",

    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "PureSwiftQR",
            targets: ["PureSwiftQR"]
        )
    ],

    targets: [
        .target(
            name: "PureSwiftQR"
        ),
        .testTarget(
            name: "PureSwiftQRTests",
            dependencies: ["PureSwiftQR"]
        )
    ]
)
