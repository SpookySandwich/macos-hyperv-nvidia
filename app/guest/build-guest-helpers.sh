#!/bin/bash
# Build the small macOS helpers that the Windows app copies into the guest over SSH.
# Run on macOS (the guest) with the Xcode command-line tools, from this directory:
#   ./build-guest-helpers.sh [<out-dir>]
# Then copy macos-bridge, macos-display and macos-audio.tar.gz into
# app/src/MacOS.App/Guest/ on Windows before running app/build.ps1.
#
# These compile lines were reconstructed for publication; the original helpers
# were built by hand. Flags beyond the frameworks are not significant.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/out}
mkdir -p "$OUT"

# Clipboard bridge (JSON lines on stdin/stdout).
xcrun clang -fobjc-arc -O2 -o "$OUT/macos-bridge" "$HERE/clipboard.m" -framework AppKit
# Display mode matcher for the Hyper-V/NVIDIA framebuffer.
xcrun clang -fobjc-arc -O2 -o "$OUT/macos-display" "$HERE/display.m" \
  -framework Foundation -framework CoreGraphics -framework IOKit
codesign -f -s - "$OUT/macos-bridge" "$OUT/macos-display"

# Audio forwarder: a background app (needs microphone consent for BlackHole capture).
app="$OUT/stage/AudioBridge.app"
rm -rf "$OUT/stage"; mkdir -p "$app/Contents/MacOS"
xcrun clang++ -std=c++17 -fobjc-arc -O2 -DAUDIO_GUI -o "$app/Contents/MacOS/AudioBridge" "$HERE/audio.mm" \
  -framework CoreAudio -framework AudioToolbox -framework AppKit -framework AVFoundation
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>macOS Audio</string>
	<key>CFBundleExecutable</key>
	<string>AudioBridge</string>
	<key>CFBundleIdentifier</key>
	<string>org.local.MacHyperVAudioBridge</string>
	<key>CFBundleName</key>
	<string>macOS Audio</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0</string>
	<key>CFBundleVersion</key>
	<string>2.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Forward macOS sound from the BlackHole virtual audio device to your Windows speakers or headphones. No physical microphone is captured.</string>
</dict>
</plist>
PLIST
codesign -f -s - "$app"
cp "$HERE/audio-client.py" "$OUT/stage/"
tar -czf "$OUT/macos-audio.tar.gz" -C "$OUT/stage" AudioBridge.app audio-client.py
echo "built: $OUT/macos-bridge $OUT/macos-display $OUT/macos-audio.tar.gz"
