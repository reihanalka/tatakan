#!/bin/bash
# One-line installer for Tatakan:
#   curl -fsSL https://raw.githubusercontent.com/reihanalka/tatakan/main/scripts/install.sh | bash
# Downloads the latest release, puts Tatakan.app in /Applications and opens it.
set -euo pipefail

REPO="reihanalka/tatakan"
DEST="${TATAKAN_DEST:-/Applications}"   # override only for testing

if [ "$(uname)" != "Darwin" ]; then
  echo "Tatakan is a macOS app. It can't run on $(uname)." >&2; exit 1
fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 14 ]; then
  echo "Tatakan needs macOS 14 Sonoma or newer (you have $(sw_vers -productVersion))." >&2; exit 1
fi

echo "Finding the latest Tatakan release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[ -n "$URL" ] || { echo "Couldn't find a release zip on github.com/$REPO." >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "Downloading $(basename "$URL")…"
curl -fL --progress-bar "$URL" -o "$TMP/Tatakan.zip"
ditto -x -k "$TMP/Tatakan.zip" "$TMP"

[ -n "${TATAKAN_DEST:-}" ] || { pkill -x Tatakan 2>/dev/null && sleep 1 || true; }

SUDO=""
[ -w "$DEST" ] || SUDO="sudo"
$SUDO rm -rf "$DEST/Tatakan.app"
$SUDO ditto "$TMP/Tatakan.app" "$DEST/Tatakan.app"
$SUDO xattr -dr com.apple.quarantine "$DEST/Tatakan.app" 2>/dev/null || true

[ -n "${TATAKAN_DEST:-}" ] || open "$DEST/Tatakan.app"
echo "Done. Tatakan is in the menu bar."
