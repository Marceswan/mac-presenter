// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PresenterCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PresenterCore", targets: ["PresenterCore"]),
    ],
    targets: [
        .target(
            name: "PresenterCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PresenterCoreTests",
            dependencies: ["PresenterCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
