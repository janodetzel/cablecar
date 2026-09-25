// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cablecar",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Cablecar", path: "Sources/Cablecar"),
        .testTarget(name: "CablecarTests", dependencies: ["Cablecar"], path: "Tests/CablecarTests"),
    ]
)
