// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sapo",
    platforms: [.macOS("14.4")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Sapo",
            path: "Sources/Sapo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SapoTests",
            dependencies: ["Sapo"],
            path: "Tests/SapoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
