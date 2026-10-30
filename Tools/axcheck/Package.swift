// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "axcheck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "axcheck", targets: ["axcheck"]),
    ],
    targets: [
        .executableTarget(name: "axcheck", path: "Sources/axcheck"),
    ]
)
