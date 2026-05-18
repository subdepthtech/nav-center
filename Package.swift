// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NavCenter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NavCenterCore", targets: ["NavCenterCore"]),
        .executable(name: "NavCenterApp", targets: ["NavCenterApp"]),
        .executable(name: "navcenterctl", targets: ["NavCenterCLI"])
    ],
    targets: [
        .target(
            name: "NavCenterCore",
            path: "Sources/NavCenterCore"
        ),
        .executableTarget(
            name: "NavCenterApp",
            dependencies: ["NavCenterCore"],
            path: "Sources/NavCenterApp",
            resources: [
                .copy("../../Resources/AppIcon.png")
            ]
        ),
        .executableTarget(
            name: "NavCenterCLI",
            dependencies: ["NavCenterCore"],
            path: "Sources/NavCenterCLI"
        ),
        .testTarget(
            name: "NavCenterTests",
            dependencies: ["NavCenterApp", "NavCenterCore"],
            path: "Tests/NavCenterTests"
        )
    ]
)
