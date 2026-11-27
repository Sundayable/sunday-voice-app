// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalMeetingEngine", targets: ["LocalMeetingEngine"]),
        .executable(name: "meeting-engine-check", targets: ["MeetingEngineCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", revision: "9f99b5cb6a907730543823ad271b82532782a899"),
    ],
    targets: [
        .target(name: "LocalMeetingEngine", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift"),
                                                     .product(name: "SpeakerKit", package: "argmax-oss-swift")]),
        .executableTarget(name: "MeetingEngineCheck", dependencies: ["LocalMeetingEngine"]),
        .testTarget(name: "LocalMeetingEngineTests", dependencies: ["LocalMeetingEngine"]),
    ]
)
