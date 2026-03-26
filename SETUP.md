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

## 3. Download model files

The model files are hosted on Moonshine's servers. Download them into the app's models directory:

```bash
MODEL_DIR=~/code/MoonshineFlow/MoonshineFlow/models/medium-streaming-en

for f in adapter.ort cross_kv.ort decoder_kv.ort encoder.ort frontend.ort streaming_config.json tokenizer.bin; do
  curl -L "https://download.moonshine.ai/model/medium-streaming-en/quantized/$f" -o "$MODEL_DIR/$f"
done
```

Verify the files are real (not Git LFS pointers):

```bash
ls -lh "$MODEL_DIR"/*.ort
# encoder.ort should be ~90MB, decoder_kv.ort ~139MB
```

If any `.ort` file is under 1KB, it's an LFS pointer and needs to be re-downloaded.

## 4. Patch Moonshine dependency

Download the macOS Moonshine binary artifact:

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

## 5. Build

Build the Moonshine Swift package first:

```bash
cd ~/code/moonshine/swift
swift build
```

This must succeed before building the app.

Then build MoonshineFlow:

```bash
cd ~/code/MoonshineFlow
swift build
```

## 6. Run

```bash
swift run
```

The app appears as a microphone icon in the menu bar.

## 7. Grant permissions

On first run, grant all three in **System Settings > Privacy & Security**:

- **Microphone** -- required for audio capture
- **Accessibility** -- required for text insertion into apps
- **Input Monitoring** -- required for the global hotkey to work

If running via `swift run`, the permissions attach to your terminal app (e.g. Ghostty, Terminal.app). If running as a `.app` bundle, permissions attach to that bundle's code signature.

## 8. First functional test

1. Open **TextEdit** and put cursor in a blank document
2. Launch Moonshine Flow (menu bar icon appears)
3. Hold **right Option** key
4. Speak a short sentence
5. Release **right Option**
6. Confirm text inserts at the cursor

Then test in: Notes, Slack, a terminal (Ghostty, Terminal.app), Chrome text fields.

## Constraints

- **macOS 15 or newer** -- the vendored Moonshine binary targets macOS 15-era SDKs.
- **Xcode must be installed** -- Command Line Tools alone have a Swift toolchain mismatch. Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to activate the Xcode toolchain.
- Do not change the sibling folder layout unless you also update the dependency path in both `MoonshineFlow.xcodeproj/project.pbxproj` and `Package.swift`.

## Key files

| File | Role |
|------|------|
| `MoonshineFlow/MoonshineFlowApp.swift` | App entry point |
| `MoonshineFlow/Dictation/DictationController.swift` | Main controller |
| `MoonshineFlow/Dictation/AudioEngine.swift` | Audio capture (16kHz mono) |
| `MoonshineFlow/Dictation/ChunkBuffer.swift` | Audio chunking (0.6s windows) |
| `MoonshineFlow/Dictation/Transcriber.swift` | Moonshine streaming wrapper |
| `MoonshineFlow/Dictation/TextInjector.swift` | Text injection (AX + clipboard fallback) |
| `MoonshineFlow/Dictation/HotkeyManager.swift` | Global hotkey via CGEvent tap |
| `MoonshineFlow/Dictation/TextStateManager.swift` | Incremental text tracking |
