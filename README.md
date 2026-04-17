# MoonshineFlow

<p align="center">
  <img src="./demo/readme-icon.png" alt="MoonshineFlow icon" width="144">
</p>

MoonshineFlow is a macOS menu-bar dictation app powered by [Moonshine](https://github.com/moonshine-ai/moonshine) for local, on-device speech recognition. Double-tap a key, speak, and optionally capture any system audio playing on your Mac too -- then tap again to stop and your words stream into whatever app has focus.

All transcription runs locally. No audio leaves your machine.

## Demo

<p align="center">
  <img src="./demo/moonshine-flow.gif" alt="MoonshineFlow demo" width="50%">
</p>

## How it works

1. Launch the app -- the MoonshineFlow icon appears in the menu bar
2. Focus any text field (TextEdit, terminal, browser, Slack, etc.)
3. **Double-tap right Option** to start dictation
4. Speak -- text streams into the focused app in real time
5. **Tap right Option** once to stop

For standard text fields (Slack, Chrome, WhatsApp, TextEdit, Notes, etc.), text is inserted and updated live via the Accessibility API -- including partial text that refines as you speak.

For terminals (Ghostty, Terminal.app, iTerm2, kitty, etc.), completed sentences stream in via clipboard paste since terminals don't support AX text insertion.

## Requirements

- macOS 15 or newer on Apple Silicon **or Intel x86_64**
- Xcode (not just Command Line Tools)

On Intel, the default Swift Package Manager dependency on `moonshine-swift` can't be used: the published xcframework's x86_64 slice is missing all Moonshine symbols, so linking fails. This branch (`intel-x86_64-build`) depends on a local build of [tattorba87/moonshine](https://github.com/tattorba87/moonshine) (branch `intel-x86_64-build`, a fork that fixes the build script) checked out as a sibling directory. Apple Silicon users can also use this setup, or stay on `main` and use the published package.

## Quick start

```bash
# 1. Clone the moonshine fork with the x86_64 build fix, next to MoonshineFlow.
git clone --branch intel-x86_64-build git@github.com:tattorba87/moonshine.git ~/dev/moonshine
cd ~/dev/moonshine && git lfs install && git lfs pull
# Rebuild the xcframework locally (one-time, ~10 min).
bash scripts/build-swift.sh

# 2. Clone MoonshineFlow.
git clone --branch intel-x86_64-build git@github.com:tattorba87/MoonshineFlow.git ~/dev/MoonshineFlow
cd ~/dev/MoonshineFlow

# 3. Download model files (~290MB).
MODEL_DIR=MoonshineFlow/models/medium-streaming-en
for f in adapter.ort cross_kv.ort decoder_kv.ort encoder.ort \
         frontend.ort streaming_config.json tokenizer.bin; do
  curl -L "https://download.moonshine.ai/model/medium-streaming-en/quantized/$f" \
    -o "$MODEL_DIR/$f"
done

# 4. Build, install to ~/Applications, and set up autostart.
scripts/build-app.sh install
```

After `install`, grant Input Monitoring to `~/Applications/MoonshineFlow.app` (System Settings → Privacy & Security → Input Monitoring → `+`). The launch agent auto-starts the app at login and restarts it if it crashes.

Other build commands:
- `scripts/build-app.sh` — build the debug bundle at `.build/MoonshineFlow.app` without installing.
- `scripts/build-app.sh run` — build and open the debug bundle for local iteration.
- `scripts/build-app.sh uninstall` — remove `~/Applications/MoonshineFlow.app` and the launch agent.

The bundle is ad-hoc signed with a stable identifier (`ai.moonshine.flow`), so TCC grants persist across rebuilds.

See [SETUP.md](SETUP.md) for the full setup guide.

## Permissions

Grant all four in **System Settings > Privacy & Security**:

| Permission | Why |
|---|---|
| Microphone | Audio capture for your voice |
| Screen & System Audio Recording | Audio capture for speaker and app output |
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
    SystemAudioCapture.swift       System output capture via Core Audio taps
    ChunkBuffer.swift              Chunks each audio source into 0.6s windows
    Transcriber.swift              Moonshine streaming transcription wrapper
    TextStateManager.swift         Tracks streaming text deltas
    TextInjector.swift             Inserts text via AX or clipboard paste
```

## Current behavior

- Double-tap right Option to start dictation; single tap to stop
- Dictation can capture microphone only, system audio only, or both
- Text streams into the focused app as you speak
- AX-capable apps get live partial text that refines in place
- Terminals get committed sentences streamed via clipboard paste
- Microphone and system audio are transcribed in separate streams and merged after transcription
- Clipboard is saved before dictation and restored after

## License

See [LICENSE.txt](LICENSE.txt).
