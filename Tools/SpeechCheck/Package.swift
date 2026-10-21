// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeechCheck",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../PresenterCore"),
    ],
    targets: [
        .executableTarget(
            name: "SpeechCheck",
            dependencies: [.product(name: "PresenterCore", package: "PresenterCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
