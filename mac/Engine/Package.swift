// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DictationEngine",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DictationEngine", targets: ["DictationEngine"])],
    targets: [
        .target(name: "DictationEngine", path: "Sources/DictationEngine"),
        .testTarget(name: "DictationEngineTests", dependencies: ["DictationEngine"], path: "Tests/DictationEngineTests"),
    ]
)
