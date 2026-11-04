// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NebulaGUI", platforms: [.macOS(.v13)],
    products: [.executable(name: "NebulaGUI", targets: ["NebulaGUI"])],
    targets: [
        .target(name: "NebulaClient"),
        .executableTarget(name: "NebulaGUI", dependencies: ["NebulaClient"]),
        .testTarget(name: "NebulaClientTests", dependencies: ["NebulaClient"]),
        .testTarget(name: "NebulaGUITests", dependencies: ["NebulaGUI", "NebulaClient"])
    ]
)
