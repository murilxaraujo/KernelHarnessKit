// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "KernelHarnessKit",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .watchOS(.v27),
    ],
    products: [
        .library(name: "KernelHarnessKit", targets: ["KernelHarnessKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0"),
    ],
    targets: [
        .target(name: "KernelHarnessKit"),
        .testTarget(name: "KernelHarnessKitTests", dependencies: ["KernelHarnessKit"]),
    ]
)
