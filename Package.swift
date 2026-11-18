// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Vollage",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FrameShiftEffects"),
        .executableTarget(name: "Vollage", dependencies: ["FrameShiftEffects"], path: "Sources/VollageNative", swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
