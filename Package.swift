// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MoonshineFlow",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "MoonshineFlow", targets: ["MoonshineFlow"]),
    ],
    dependencies: [
        .package(path: "../moonshine/swift"),
    ],
    targets: [
        .executableTarget(
            name: "MoonshineFlow",
            dependencies: [
                .product(name: "MoonshineVoice", package: "swift"),
            ],
            path: "MoonshineFlow",
            exclude: [
                "Audio",
                "Assets.xcassets",
                "AudioDeviceManager.swift",
                "AudioPlayer.swift",
                "AudioTranscriber.swift",
                "CaptureEngine.swift",
                "Info.plist",
                "MicrophonePCMSampleVendor.swift",
                "MicrophonePCMSampleVendorError.swift",
                "MoonshineFlow.entitlements",
                "Preview Content",
                "ScreenRecorder.swift",
                "SleepAssertion.swift",
                "TranscriptDocument.swift",
                "Views/TranscriptView.swift",
                "Views/ProvenanceTrackingTextView.swift",
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
