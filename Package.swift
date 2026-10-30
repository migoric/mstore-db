// swift-tools-version: 6.2
import PackageDescription

// 只支持 macOS 26：界面依赖 Liquid Glass（glassEffect / GlassEffectContainer /
// scrollEdgeEffectStyle）与新的窗口合成行为，这些在 15 上既没有 API 也没有效果。
// 与其在低版本上做一套退化的灰底界面，不如明确不兼容。
let package = Package(
    name: "mstore-db",
    platforms: [.macOS("26.0")],
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
