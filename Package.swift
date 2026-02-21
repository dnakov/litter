// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Litter",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "Litter", targets: ["Litter"])
    ],
    targets: [
        .binaryTarget(
            name: "codex_bridge",
            path: "apps/ios/Frameworks/codex_bridge.xcframework"
        ),
        .target(
            name: "Litter",
            dependencies: ["codex_bridge"],
            path: "apps/ios/Sources/Litter",
            publicHeadersPath: "Bridge"
        )
    ]
)
