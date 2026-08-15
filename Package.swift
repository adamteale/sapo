// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Stems",
    platforms: [.macOS("14.4")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Stems",
            path: "Sources/Stems",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StemsTests",
            dependencies: ["Stems"],
            path: "Tests/StemsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
