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
    targets: [
        .target(name: "KernelHarnessKit"),
        .testTarget(name: "KernelHarnessKitTests", dependencies: ["KernelHarnessKit"]),
    ]
)
