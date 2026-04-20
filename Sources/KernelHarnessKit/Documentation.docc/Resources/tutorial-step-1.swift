// Package.swift
let package = Package(
    name: "kb-agent",
    dependencies: [
        .package(url: "https://github.com/you/KernelHarnessKit.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "kb-agent",
            dependencies: [
                .product(name: "KernelHarnessKit", package: "KernelHarnessKit"),
            ]
        ),
    ]
)
