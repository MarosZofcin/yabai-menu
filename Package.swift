// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YabaiMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "YabaiMenu", targets: ["YabaiMenu"])
    ],
    targets: [
        .executableTarget(
            name: "YabaiMenu",
            path: "Sources/YabaiMenu"
        )
    ],
    swiftLanguageModes: [.v5]
)
