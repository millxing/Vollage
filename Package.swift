// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Vollage",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Vollage", path: "Sources/VollageNative", swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
