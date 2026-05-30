// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "krit-helper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "krit-helper",
            path: "Sources/krit-helper"
        )
    ]
)
