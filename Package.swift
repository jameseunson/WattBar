// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattBar",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure power arithmetic: no hardware access, no AppKit, no private
        // system libraries. Everything the app can work out without touching
        // the machine lives here, where it can be tested.
        .target(
            name: "WattBarCore",
            path: "Sources/WattBarCore"
        ),
        .executableTarget(
            name: "WattBar",
            dependencies: ["WattBarCore"],
            path: "Sources/WattBar",
            linkerSettings: [
                .linkedLibrary("IOReport")
            ]
        ),
        .testTarget(
            name: "WattBarCoreTests",
            dependencies: ["WattBarCore"]
        ),
    ]
)
