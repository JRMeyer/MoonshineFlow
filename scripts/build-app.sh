#!/bin/bash
# Build MoonshineFlow as a standalone .app bundle with a stable code-signing
# identity so macOS TCC grants (Input Monitoring, Accessibility, Microphone)
# survive rebuilds.
#
# Why a bundle? Launching the raw SPM executable from a terminal makes the
# shell the TCC "responsible process", which shadows any grants made against
# the app itself. Launching a .app via `open` or Finder puts launchd in that
# role instead, so permissions stick.
#
# Usage:
#   scripts/build-app.sh             # build + bundle (debug config)
#   scripts/build-app.sh release     # release config
#   scripts/build-app.sh run         # build + bundle + open the .app
#   scripts/build-app.sh install     # build + copy to ~/Applications + install LaunchAgent (autostarts at login)
#   scripts/build-app.sh uninstall   # remove LaunchAgent and ~/Applications copy
#
# Output: .build/MoonshineFlow.app
# On install: ~/Applications/MoonshineFlow.app + ~/Library/LaunchAgents/ai.moonshine.flow.plist

set -euo pipefail

CONFIG="debug"
OPEN_AFTER=0
DO_INSTALL=0
DO_UNINSTALL=0
for arg in "$@"; do
	case "$arg" in
		release)   CONFIG="release" ;;
		debug)     CONFIG="debug" ;;
		run)       OPEN_AFTER=1 ;;
		install)   DO_INSTALL=1; CONFIG="release" ;;
		uninstall) DO_UNINSTALL=1 ;;
		*) echo "unknown arg: $arg" >&2; exit 2 ;;
	esac
done

INSTALLED_APP="$HOME/Applications/MoonshineFlow.app"
LAUNCH_AGENT_LABEL="ai.moonshine.flow"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LAUNCH_AGENT_LOG_DIR="$HOME/Library/Logs/MoonshineFlow"

uninstall_agent() {
	if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
		launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
		rm -f "$LAUNCH_AGENT_PLIST"
		echo "removed $LAUNCH_AGENT_PLIST"
	fi
	pkill -x MoonshineFlow 2>/dev/null || true
}

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
	uninstall_agent
	if [[ -d "$INSTALLED_APP" ]]; then
		rm -rf "$INSTALLED_APP"
		echo "removed $INSTALLED_APP"
	fi
	echo "uninstalled."
	exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_FLAGS=""
if [[ "$CONFIG" == "release" ]]; then
	BUILD_FLAGS="-c release"
fi
swift build $BUILD_FLAGS

BIN_DIR="$(swift build $BUILD_FLAGS --show-bin-path)"
BINARY="$BIN_DIR/MoonshineFlow"
RESOURCE_BUNDLE="$BIN_DIR/MoonshineFlow_MoonshineFlow.bundle"

if [[ ! -x "$BINARY" ]]; then
	echo "error: expected binary at $BINARY" >&2
	exit 1
fi

APP="$REPO_ROOT/.build/MoonshineFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/MoonshineFlow"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
	cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

# Compile AppIcon.icns from the PNGs in AppIcon.appiconset. iconutil needs
# a directory named *.iconset with files named exactly
# icon_<N>x<N>[@2x].png, so we stage them in a tmp dir.
ICON_SRC="$REPO_ROOT/MoonshineFlow/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$ICON_SRC" ]]; then
	ICONSET="$(mktemp -d)/AppIcon.iconset"
	mkdir -p "$ICONSET"
	cp "$ICON_SRC/MoonshineNoteTaker16.png"   "$ICONSET/icon_16x16.png"
	cp "$ICON_SRC/MoonshineNoteTaker32.png"   "$ICONSET/icon_16x16@2x.png"
	cp "$ICON_SRC/MoonshineNoteTaker32.png"   "$ICONSET/icon_32x32.png"
	cp "$ICON_SRC/MoonshineNoteTaker64.png"   "$ICONSET/icon_32x32@2x.png"
	cp "$ICON_SRC/MoonshineNoteTaker128.png"  "$ICONSET/icon_128x128.png"
	cp "$ICON_SRC/MoonshineNoteTaker256.png"  "$ICONSET/icon_128x128@2x.png"
	cp "$ICON_SRC/MoonshineNoteTaker256.png"  "$ICONSET/icon_256x256.png"
	cp "$ICON_SRC/MoonshineNoteTaker512.png"  "$ICONSET/icon_256x256@2x.png"
	cp "$ICON_SRC/MoonshineNoteTaker512.png"  "$ICONSET/icon_512x512.png"
	cp "$ICON_SRC/MoonshineNoteTaker1024.png" "$ICONSET/icon_512x512@2x.png"
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
	rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MoonshineFlow</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>ai.moonshine.flow</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MoonshineFlow</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>This app needs permission to capture system audio so dictation can include speaker output as well as your microphone.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>This app needs microphone access to transcribe audio from your microphone.</string>
</dict>
</plist>
PLIST

# Stable ad-hoc identity. Without --identifier, codesign derives one from
# a hash of the binary contents, which changes on every rebuild and makes
# TCC treat each build as a different app.
codesign --force --sign - --identifier ai.moonshine.flow "$APP/Contents/MacOS/MoonshineFlow"
codesign --force --sign - --deep "$APP"

echo "built $APP"

if [[ "$DO_INSTALL" -eq 1 ]]; then
	mkdir -p "$HOME/Applications" "$LAUNCH_AGENT_LOG_DIR"

	# Unload any existing agent before overwriting the bundle, otherwise
	# launchd may hold the old binary open and the copy misses files.
	uninstall_agent

	rm -rf "$INSTALLED_APP"
	cp -R "$APP" "$INSTALLED_APP"
	echo "installed $INSTALLED_APP"

	cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCH_AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${INSTALLED_APP}/Contents/MacOS/MoonshineFlow</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
		<key>Crashed</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>${LAUNCH_AGENT_LOG_DIR}/stdout.log</string>
	<key>StandardErrorPath</key>
	<string>${LAUNCH_AGENT_LOG_DIR}/stderr.log</string>
</dict>
</plist>
PLIST

	launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
	launchctl enable "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
	echo "loaded launch agent $LAUNCH_AGENT_PLIST"
	echo ""
	echo "First run — grant Input Monitoring to $INSTALLED_APP"
	echo "(System Settings → Privacy & Security → Input Monitoring → +)"
	exit 0
fi

if [[ "$OPEN_AFTER" -eq 1 ]]; then
	# Close any running instance so the new binary loads.
	pkill -x MoonshineFlow 2>/dev/null || true
	open "$APP"
	echo "launched $APP"
fi
