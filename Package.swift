// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LLMUsageBar",
            path: "Sources/LLMUsageBar"
        )
    ]
)
