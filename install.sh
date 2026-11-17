#!/bin/bash
# MacScreen one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/KMThegamer2022/MacScreen/main/install.sh | bash
# Downloads the latest release with curl (no macOS quarantine flag, so no "unidentified developer" prompt).
set -euo pipefail
REPO="${MACSCREEN_REPO:-KMThegamer2022/MacScreen}"
URL="${MACSCREEN_ZIP_URL:-https://github.com/$REPO/releases/latest/download/MacScreen.zip}"
DEST="${MACSCREEN_DEST:-/Applications}"

[ "$(uname)" = "Darwin" ] || { echo "MacScreen only runs on macOS."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || { echo "MacScreen needs macOS 13 or newer (you have $(sw_vers -productVersion))."; exit 1; }
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "Downloading MacScreen…"
curl -fL --progress-bar "$URL" -o "$tmp/MacScreen.zip"
ditto -x -k "$tmp/MacScreen.zip" "$tmp/x"
[ -d "$tmp/x/MacScreen.app" ] || { echo "Download didn't contain MacScreen.app"; exit 1; }

pkill -x MacScreen 2>/dev/null || true
rm -rf "$DEST/MacScreen.app"
ditto "$tmp/x/MacScreen.app" "$DEST/MacScreen.app"
xattr -dr com.apple.quarantine "$DEST/MacScreen.app" 2>/dev/null || true
echo "Installed to $DEST/MacScreen.app"
[ "${MACSCREEN_NO_OPEN:-0}" = "1" ] || open "$DEST/MacScreen.app"
