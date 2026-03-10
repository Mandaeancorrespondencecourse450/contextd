// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ContextD",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContextD",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "ContextD",
            exclude: ["Assets.xcassets"]
        ),
    ]
)
