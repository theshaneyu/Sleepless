// swift-tools-version: 6.0
// Test harness only. The app itself is still built by build.sh with plain `swiftc`; this
// package exists so `swift test` can check the logic in Core/ without AppKit.
import PackageDescription

let package = Package(
    name: "Sleepless",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SleeplessCore", path: "Core"),
        .testTarget(name: "SleeplessCoreTests", dependencies: ["SleeplessCore"]),
    ]
)
