// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GFind",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GFind", path: "Sources/GFind")
    ]
)
