// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WattBar",
            path: "Sources/WattBar",
            linkerSettings: [
                .linkedLibrary("IOReport")
            ]
        )
    ]
)
