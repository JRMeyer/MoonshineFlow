# Moonshine Flow

Moonshine Flow is a macOS menu-bar dictation app built from Moonshine Note Taker.
It uses Moonshine locally for speech recognition, starts dictation from a global press-and-hold hotkey, and inserts the final transcript into the currently focused app.

## Current behavior

- Hold `fn` to start dictation
- Speak while the key is held
- Release to finalize and insert text
- Prefer Accessibility-based insertion, then fall back to clipboard paste

This repo currently implements the simpler "insert on release" mode first. Live incremental insertion is not wired yet.

## Project layout

```text
MoonshineFlow/
  Dictation/
    DictationController.swift
    HotkeyManager.swift
    AudioEngine.swift
    ChunkBuffer.swift
    Transcriber.swift
    TextStateManager.swift
    TextInjector.swift
```

## Dependency setup

The Xcode project uses the local Swift package at `../moonshine/swift`.

The cloned `moonshine` repo in this workspace has been adjusted to use the current macOS release artifact (`moonshine-voice-macos.tar.gz`) as a vendored local package dependency because the checked-in `Moonshine.xcframework` is not present in the clone.

## Build

1. Open `MoonshineFlow.xcodeproj` in Xcode.
2. Let Swift Package Manager resolve the local `../moonshine/swift` package.
3. Build and run the `Moonshine Flow` target.
4. Grant:
   - Microphone access
   - Accessibility access
   - Input Monitoring if the global hotkey does not fire on your machine

## Notes

- `xcodebuild` could not be run in this environment because the active developer directory is the Command Line Tools instance, not a full Xcode install.
- The local Moonshine Swift package does build with `swift build` after vendoring the current macOS artifact.
