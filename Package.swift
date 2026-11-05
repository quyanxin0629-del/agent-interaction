// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentInteraction",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentInteraction", targets: ["AgentInteraction"])],
    targets: [
        .executableTarget(name: "AgentInteraction"),
        .testTarget(name: "AgentInteractionTests", dependencies: ["AgentInteraction"])
    ]
)
