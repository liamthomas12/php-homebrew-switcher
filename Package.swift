// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PHPSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PHPSwitcher",
            path: "Sources/PHPSwitcher"
        )
    ]
)
