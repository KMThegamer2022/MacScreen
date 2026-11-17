#!/bin/bash
# Builds distributable artifacts into dist/:  MacScreen.zip (for install.sh) and MacScreen-<version>.dmg
# Release builds are signed ad-hoc (no Apple Developer ID needed), so they run on any Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.4}"
rm -rf dist && mkdir -p dist
# Stage outside the project folder: iCloud-synced folders (e.g. ~/Documents) add attributes that break code signing.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Universal (Apple silicon + Intel) if the toolchain can do it, otherwise this Mac's architecture.
if ! ADHOC=1 UNIVERSAL=1 VERSION="$VERSION" OUT="$STAGE" ./build.sh; then
  echo "Universal build unavailable here — building for this Mac's architecture only"
  ADHOC=1 UNIVERSAL=0 VERSION="$VERSION" OUT="$STAGE" ./build.sh
fi
APP="$STAGE/MacScreen.app"
codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MacScreen")"

# zip used by install.sh (stable name so /releases/latest/download/MacScreen.zip always works)
ditto -c -k --keepParent --norsrc --noextattr "$APP" dist/MacScreen.zip

# DMG with drag-to-Applications layout
DMG_DIR="$STAGE/dmg"
mkdir -p "$DMG_DIR"
ditto --norsrc --noextattr --noqtn "$APP" "$DMG_DIR/MacScreen.app"
xattr -cr "$DMG_DIR/MacScreen.app" 2>/dev/null || true
codesign --verify --deep --strict "$DMG_DIR/MacScreen.app"
ln -s /Applications "$DMG_DIR/Applications"
cat > "$DMG_DIR/READ ME FIRST.txt" <<TXT
MacScreen $VERSION

1. Drag MacScreen into Applications.
2. The first time, macOS says it can't verify the developer (this app is not notarized).
   Open System Settings > Privacy & Security, scroll down and click "Open Anyway".
   (Or install with the one-line installer from the project page, which skips this prompt.)
3. Grant Screen Recording and Accessibility when asked, then press Start.
TXT
hdiutil create -volname "MacScreen" -srcfolder "$DMG_DIR" -ov -format UDZO "$STAGE/MacScreen-$VERSION.dmg" >/dev/null
cp "$STAGE/MacScreen-$VERSION.dmg" dist/
( cd dist && shasum -a 256 MacScreen.zip "MacScreen-$VERSION.dmg" > SHA256SUMS.txt )
ls -lh dist
