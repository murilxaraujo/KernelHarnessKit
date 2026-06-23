// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernelHarnessKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "KernelHarnessKit", targets: ["KernelHarnessKit"]),
        .library(name: "KernelHarnessFoundationModels", targets: ["KernelHarnessFoundationModels"]),
        .library(name: "KernelHarnessOpenAICompatible", targets: ["KernelHarnessOpenAICompatible"]),
    ],
    targets: [
        .target(
            name: "KernelHarnessKit"
        ),
        .target(
            name: "KernelHarnessFoundationModels",
            dependencies: ["KernelHarnessKit"]
        ),
        .target(
            name: "KernelHarnessOpenAICompatible",
            dependencies: ["KernelHarnessKit"],
            exclude: ["OpenAICompatibleProvider.swift"]
        ),
        .testTarget(
            name: "KernelHarnessKitTests",
            dependencies: ["KernelHarnessKit", "KernelHarnessOpenAICompatible"]
        ),
    ]
)
