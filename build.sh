#!/bin/bash
# Builds MacScreen.app (no Xcode needed — Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.1}"
OUT="${OUT:-build}"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Two single-arch builds merged with lipo (works with just the Command Line Tools)
  swift build -c release --triple arm64-apple-macosx13.0 --build-path .build-arm64
  swift build -c release --triple x86_64-apple-macosx13.0 --build-path .build-x86_64
  mkdir -p .build-universal
  lipo -create -output .build-universal/MacScreen \
    .build-arm64/arm64-apple-macosx/release/MacScreen .build-x86_64/x86_64-apple-macosx/release/MacScreen
  BIN=.build-universal/MacScreen
else
  swift build -c release
  BIN=.build/release/MacScreen
fi
APP="$OUT/MacScreen.app"
rm -rf "$APP"
mkdir -p "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacScreen"
cp web/receiver.html "$APP/Contents/Resources/receiver.html"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacScreen</string>
  <key>CFBundleIdentifier</key><string>org.kmtg.MacScreen</string>
  <key>CFBundleName</key><string>MacScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>MacScreen captures its virtual second screen to stream it to your Chromebook.</string>
  <key>NSLocalNetworkUsageDescription</key><string>MacScreen streams the second screen to receivers on your network.</string>
  <key>NSBonjourServices</key><array><string>_http._tcp</string></array>
</dict></plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/" "$APP/Contents/Info.plist"
ID=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/{print $2; exit}')
if [ "${ADHOC:-0}" = "1" ]; then ID=""; fi
if [ -n "${ID:-}" ]; then codesign --force --deep --sign "$ID" "$APP"; echo "Signed with stable identity"; else codesign --force --deep --sign - "$APP"; echo "Signed ad-hoc (permissions reset on rebuild)"; fi
echo "Built $APP"
