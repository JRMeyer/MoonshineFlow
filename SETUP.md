# Local Setup

## 1. Create a clean workspace

```bash
mkdir -p ~/code
cd ~/code
```

## 2. Clone both repos as siblings

```bash
git clone git@github.com:JRMeyer/MoonshineFlow.git
git clone git@github.com:moonshine-ai/moonshine.git
```

The folder layout must be:

```
~/code/
  MoonshineFlow/
  moonshine/
```

MoonshineFlow expects the Moonshine Swift package at `../moonshine/swift`.

## 3. Patch Moonshine Dependency

Download the current macOS Moonshine binary artifact:

```bash
curl -L https://github.com/moonshine-ai/moonshine/releases/download/v0.0.51/moonshine-voice-macos.tar.gz \
  -o /tmp/moonshine-voice-macos.tar.gz
```

Unpack it into the Moonshine Swift package:

```bash
mkdir -p ~/code/moonshine/swift/Vendor
tar -xzf /tmp/moonshine-voice-macos.tar.gz -C ~/code/moonshine/swift/Vendor
mkdir -p ~/code/moonshine/swift/Vendor/moonshine-voice-macos/swift-include
printf '#include "../include/moonshine-c-api.h"\n' \
  > ~/code/moonshine/swift/Vendor/moonshine-voice-macos/swift-include/Moonshine.h
```

Replace `~/code/moonshine/swift/Package.swift` with this exact file:

```swift
// swift-tools-version: 6.1
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let moonshineLibraryPath = packageRoot + "/Vendor/moonshine-voice-macos/lib"
let moonshineIncludePath = packageRoot + "/Vendor/moonshine-voice-macos/include"

let package = Package(
    name: "Moonshine",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MoonshineVoice", type: .static, targets: ["MoonshineVoice"])
    ],
    targets: [
        .target(
            name: "Moonshine",
            path: "Vendor/moonshine-voice-macos",
            publicHeadersPath: "swift-include",
            cSettings: [
                .unsafeFlags([
                    "-I\(moonshineIncludePath)",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(moonshineLibraryPath)",
                    "-lmoonshine",
                ])
            ]
        ),
        .target(
            name: "MoonshineVoice",
            dependencies: ["Moonshine"],
            path: "Sources/MoonshineVoice",
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "MoonshineVoiceTests",
            dependencies: ["MoonshineVoice"],
            path: "Tests/MoonshineVoiceTests",
            resources: [
                .copy("test-assets")
            ]
        ),
    ]
)
```

## 4. Verify Moonshine builds

```bash
cd ~/code/moonshine/swift
swift build
```

This must succeed before touching the app.

## 5. Build and run MoonshineFlow

```bash
cd ~/code/MoonshineFlow
swift build
swift run
```

### Using Xcode

```bash
open ~/code/MoonshineFlow/MoonshineFlow.xcodeproj
```

In Xcode:

- Select the **Moonshine Flow** target
- Let SwiftPM resolve the local package dependency
- Build and run

## 6. Permissions

On first run, grant:

- **Microphone**
- **Accessibility**

If the hotkey does not fire, also grant:

- **Input Monitoring**

## 7. First Functional Test

Validate in this order:

1. Open TextEdit
2. Put cursor in a blank document
3. Launch Moonshine Flow
4. Hold **fn**
5. Speak a short sentence
6. Release **fn**
7. Confirm text inserts at the cursor

Then test in: Notes, Slack, Chrome text field.

## Current Behavior

What works:

- Menu bar app launches
- Hold fn starts dictation; release fn finalizes
- Final text inserts into the focused app
- Accessibility insertion is attempted first; clipboard paste fallback if AX insert fails

Not yet implemented:

- Live incremental insertion while still holding the key
- Rollback / cursor reconciliation for unstable partials
- Hotkey remapping UI

## Constraints

- **macOS 15 or newer** — the vendored Moonshine binary targets macOS 15-era SDKs.
- Do not change the sibling folder layout unless you also update the dependency path in both `MoonshineFlow.xcodeproj/project.pbxproj` and `Package.swift`.

## Key Files

| File | Role |
|------|------|
| `MoonshineFlow/MoonshineFlowApp.swift` | App entry point |
| `MoonshineFlow/Dictation/DictationController.swift` | Main controller |
| `MoonshineFlow/Dictation/AudioEngine.swift` | Audio capture |
| `MoonshineFlow/Dictation/ChunkBuffer.swift` | Chunking |
| `MoonshineFlow/Dictation/Transcriber.swift` | Moonshine wrapper |
| `MoonshineFlow/Dictation/TextInjector.swift` | Text injection |
| `MoonshineFlow/Dictation/HotkeyManager.swift` | Hotkey handling |
