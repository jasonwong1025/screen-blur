// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay"),
        .executableTarget(name: "ScreenBlur", dependencies: ["CVirtualDisplay"], path: "Sources/ScreenBlur"),
    ]
)
