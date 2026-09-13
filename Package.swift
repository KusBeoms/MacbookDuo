// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacbookDuo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacbookDuo",
            path: "Sources/MacbookDuo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
