// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ScreenBlur", path: "Sources/ScreenBlur")
    ]
)
