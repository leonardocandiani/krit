// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Krit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "krit", targets: ["KritCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "KritApp",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Krit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "KritCLI",
            path: "Sources/KritCLI"
        ),
    ]
)
