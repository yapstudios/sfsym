// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sfsym",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sfsym", targets: ["sfsym"]),
        .executable(name: "harness", targets: ["harness"]),
    ],
    targets: [
        .executableTarget(name: "sfsym", path: "Sources/sfsym"),
        .executableTarget(name: "harness", path: "Sources/harness"),
    ]
)
