// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanAlephaMac98",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CleanAlephaMac98", targets: ["CleanAlephaMac98"])
    ],
    targets: [
        .executableTarget(
            name: "CleanAlephaMac98",
            path: "Sources/CleanAlephaMac98"
        )
    ]
)
