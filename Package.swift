// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MOS",
    platforms: [.macOS(.v15)],
    products: [.library(name: "HermesClient", targets: ["HermesClient"]), .executable(name: "BotClient", targets: ["BotClient"])],
    targets: [
        .target(name: "HermesClient"),
        .executableTarget(name: "BotClient", dependencies: ["HermesClient"]),
        .testTarget(name: "HermesClientTests", dependencies: ["HermesClient"])
    ],
    swiftLanguageModes: [.v5]
)
