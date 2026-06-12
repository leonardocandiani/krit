// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Krit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "krit", targets: ["KritCLI"]),
        // Library product so Xcode generates a KritKit scheme: previews and
        // code snippets only work outside executable targets.
        .library(name: "KritKit", targets: ["KritKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
    ],
    targets: [
        // All app code lives in this library so Xcode previews and code
        // snippets work on it (both are unavailable inside executable targets).
        .target(
            name: "KritKit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Krit",
            resources: [.process("Resources")]
        ),
        // Thin entry point: just main.swift calling KritMain.run().
        .executableTarget(
            name: "KritApp",
            dependencies: ["KritKit"],
            path: "Sources/KritApp"
        ),
        .executableTarget(
            name: "KritCLI",
            path: "Sources/KritCLI"
        ),
    ]
)
