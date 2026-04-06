# Local Setup

## 1. Clone the repo

```bash
mkdir -p ~/code
cd ~/code
git clone git@github.com:JRMeyer/MoonshineFlow.git
```

## 2. Download model files

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

## 3. Build and run

```bash
cd ~/code/MoonshineFlow
xcodebuild -scheme MoonshineFlow -configuration Release -derivedDataPath build build
open build/Build/Products/Release/MoonshineFlow.app
```

Xcode will automatically fetch the [moonshine-swift](https://github.com/moonshine-ai/moonshine-swift) package and download the pre-built xcframework on first build.

## 4. Grant permissions

On first run, grant all four in **System Settings > Privacy & Security**:

- **Microphone** -- required for audio capture
- **Screen & System Audio Recording** -- required if you want dictation to include speaker or app output
- **Accessibility** -- required for text insertion into apps
- **Input Monitoring** -- required for the global hotkey to work

Permissions attach to the app bundle's code signature, so they persist across restarts.

## 5. First functional test

1. Open **TextEdit** and put cursor in a blank document
2. Launch MoonshineFlow (the MoonshineFlow menu bar icon appears)
3. **Double-tap right Option** to start dictation
4. Speak a short sentence
5. **Tap right Option** once to stop
6. Confirm text inserts at the cursor

Then test in: Notes, Slack, a terminal (Ghostty, Terminal.app), Chrome text fields.

## Requirements

- **macOS 15 or newer** on Apple Silicon
- **Xcode** (not just Command Line Tools) -- run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to activate the Xcode toolchain

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
| `MoonshineFlow/Dictation/TextStateManager.swift` | Streaming text tracking |
