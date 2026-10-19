// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "quackShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "quackShot", targets: ["quackShot"]),
    ],
    targets: [
        // Drawing, geometry, CLI parsing and config: everything that can be
        // tested without Screen Recording permission or a window server.
        .target(
            name: "QuackShotCore",
            path: "Sources/QuackShotCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "quackShot",
            dependencies: ["QuackShotCore"],
            path: "Sources/quackShot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuackShotCoreTests",
            dependencies: ["QuackShotCore"],
            path: "Tests/QuackShotCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
