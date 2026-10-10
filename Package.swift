// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MemGlass",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MemGlass",
            path: "Sources/MemGlass"
        )
    ]
)