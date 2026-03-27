// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SankofaIOS",
    platforms: [
        .iOS(.v14),
        .macOS(.v11), // For testing on macOS CI runners
    ],
    products: [
        .library(
            name: "SankofaIOS",
            targets: ["SankofaIOS"]
        ),
    ],
    dependencies: [
        // GRDB.swift – Thread-safe SQLite for offline-first event queuing.
        // Chosen over CoreData for its simpler API and better concurrency model,
        // mirroring the Android SDK's Room database architecture.
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            // from: "6.0.0"
            exact: "7.10.0"
        ),
    ],
    targets: [
        .target(
            name: "SankofaIOS",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/SankofaIOS",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "SankofaIOSTests",
            dependencies: ["SankofaIOS"],
            path: "Tests/SankofaIOSTests"
        ),
    ]
)
