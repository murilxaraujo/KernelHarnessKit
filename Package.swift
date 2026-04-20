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
        .library(name: "KernelHarnessPostgres", targets: ["KernelHarnessPostgres"]),
        .executable(name: "kernel-harness-demo", targets: ["KernelHarnessDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KernelHarnessKit",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "KernelHarnessPostgres",
            dependencies: [
                "KernelHarnessKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "KernelHarnessDemo",
            dependencies: [
                "KernelHarnessKit",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KernelHarnessKitTests",
            dependencies: ["KernelHarnessKit"]
        ),
        .testTarget(
            name: "KernelHarnessPostgresTests",
            dependencies: ["KernelHarnessPostgres"]
        ),
    ]
)
