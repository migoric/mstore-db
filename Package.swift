// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mstore-db",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mstore-db", targets: ["mstore-db"])
    ],
    targets: [
        .executableTarget(
            name: "mstore-db",
            path: "Sources/mstore-db"
        )
    ]
)
