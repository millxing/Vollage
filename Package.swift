// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VollageNative",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "VollageNative", swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
