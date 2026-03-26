# Moonshine Flow

Moonshine Flow is a macOS menu-bar dictation app powered by [Moonshine](https://github.com/moonshine-ai/moonshine) for local, on-device speech recognition. Hold a key, speak, release -- your words appear in whatever app has focus.

All transcription runs locally. No audio leaves your machine.

## How it works

1. Launch the app -- a microphone icon appears in the menu bar
2. Focus any text field (TextEdit, terminal, browser, Slack, etc.)
3. Hold **right Option** key and speak
4. Release the key -- transcribed text is inserted at the cursor

For standard text fields, text is inserted via the Accessibility API. For terminals (Ghostty, Terminal.app, iTerm2, kitty, etc.), the app falls back to clipboard paste (Cmd+V) since terminals don't support AX text insertion.

## Requirements

- macOS 15 or newer
- Xcode (not just Command Line Tools)

## Quick start

```bash
# Clone both repos side by side
mkdir -p ~/code && cd ~/code
git clone git@github.com:JRMeyer/MoonshineFlow.git
git clone git@github.com:moonshine-ai/moonshine.git

# Download model files (~290MB total)
MODEL_DIR=~/code/MoonshineFlow/MoonshineFlow/models/medium-streaming-en
for f in adapter.ort cross_kv.ort decoder_kv.ort encoder.ort frontend.ort streaming_config.json tokenizer.bin; do
  curl -L "https://download.moonshine.ai/model/medium-streaming-en/quantized/$f" -o "$MODEL_DIR/$f"
done

# Patch the Moonshine Swift package (see SETUP.md for details)
# Then build and run:
cd ~/code/MoonshineFlow
swift build && swift run
```

See [SETUP.md](SETUP.md) for the full step-by-step setup including patching the Moonshine dependency.

## Permissions

Grant all three in **System Settings > Privacy & Security**:

| Permission | Why |
|---|---|
| Microphone | Audio capture for transcription |
| Accessibility | Inserting text into focused apps |
| Input Monitoring | Global hotkey detection (right Option key) |

## Project layout

```
MoonshineFlow/
  MoonshineFlowApp.swift          App entry point (menu bar)
  Views/
    ContentView.swift              Menu bar popover UI
    SettingsView.swift             Settings window
  Dictation/
    DictationController.swift      Orchestrates the dictation session
    HotkeyManager.swift            Global hotkey via CGEvent tap
    AudioEngine.swift              Mic capture, resampled to 16kHz mono
    ChunkBuffer.swift              Splits audio into 0.6s chunks
    Transcriber.swift              Moonshine streaming transcription wrapper
    TextStateManager.swift         Tracks incremental transcription state
    TextInjector.swift             Inserts text via AX or clipboard paste
```

## Current behavior

- Hold right Option to start dictation; release to finalize
- Final text inserts into the focused app
- Accessibility insertion for standard apps; clipboard paste for terminals
- Transcriber is pre-initialized at launch for fast first-press response

## Not yet implemented

- Live incremental insertion while still holding the key
- Rollback / cursor reconciliation for unstable partials
- Hotkey remapping UI

## License

See [LICENSE.txt](LICENSE.txt).
