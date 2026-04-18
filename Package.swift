// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MinerScheduler",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MinerScheduler", targets: ["MinerScheduler"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MinerScheduler",
            dependencies: []
        )
    ]
)
