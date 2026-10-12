// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LidShot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LidShot", path: "Sources/LidShot")
    ]
)
