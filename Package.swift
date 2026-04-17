// swift-tools-version: 6.1
import PackageDescription
import Foundation

// If the `moonshine` fork is checked out as a sibling directory, depend on
// its local Swift package. Otherwise fetch the published moonshine-swift
// package. The local path is needed on Intel x86_64 because the published
// xcframework ships an x86_64 slice missing all Moonshine symbols; Apple
// Silicon users can use either.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let siblingMoonshineManifest = packageDir
    .appendingPathComponent("../moonshine/swift/Package.swift")
    .path
let useLocalMoonshine = FileManager.default.fileExists(atPath: siblingMoonshineManifest)

let moonshineDependency: Package.Dependency = useLocalMoonshine
    ? .package(path: "../moonshine/swift")
    : .package(url: "https://github.com/moonshine-ai/moonshine-swift", from: "0.0.51")

// `.package(path:)` derives its identifier from the directory name ("swift"),
// while `.package(url:)` derives it from the repo name ("moonshine-swift").
let moonshinePackageRef = useLocalMoonshine ? "swift" : "moonshine-swift"

let package = Package(
    name: "MoonshineFlow",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "MoonshineFlow", targets: ["MoonshineFlow"]),
    ],
    dependencies: [
        moonshineDependency,
    ],
    targets: [
        .executableTarget(
            name: "MoonshineFlow",
            dependencies: [
                .product(name: "MoonshineVoice", package: moonshinePackageRef),
            ],
            path: "MoonshineFlow",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "MoonshineFlow.entitlements",
                "Preview Content",
            ],
            resources: [
                .copy("models"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend",
                    "-strict-concurrency=minimal",
                    "-Xfrontend",
                    "-disable-actor-data-race-checks",
                ])
            ]
        ),
    ]
)
