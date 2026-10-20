#!/bin/bash
# Dev loop: build, install over /Applications/Tatakan.app, relaunch the running app.
# Settings (UserDefaults), login item and macOS permissions carry over: same bundle ID,
# same path, and a stable "Puteran Local Signing" identity (shared) (see build.sh).
#   Tools/dev.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Applications/Tatakan.app
BACKUP="$HOME/Backups/Tatakan/Tatakan-reihan-original.zip"

./build.sh 2>&1 | grep -E "error|BUILD OK" || true
[ -x build/Tatakan.app/Contents/MacOS/Tatakan ] || { echo "build failed"; exit 1; }

# one-time: keep Reihan's original install before we overwrite it
if [ -d "$DEST" ] && [ ! -f "$BACKUP" ]; then
  mkdir -p "$(dirname "$BACKUP")"
  ditto -c -k --keepParent "$DEST" "$BACKUP"
  echo "backed up original -> $BACKUP"
fi

# graceful quit (SIGTERM is routed to NSApp.terminate), wait up to 5 s
if pgrep -x Tatakan >/dev/null; then
  pkill -TERM -x Tatakan || true
  for _ in $(seq 1 25); do pgrep -x Tatakan >/dev/null || break; sleep 0.2; done
  pkill -KILL -x Tatakan 2>/dev/null || true
fi

rm -rf "$DEST"
ditto build/Tatakan.app "$DEST"
# LaunchServices can still hold the old instance for a moment (-600): retry briefly
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  open "$DEST" 2>/dev/null && break
done
sleep 1
pgrep -x Tatakan >/dev/null && echo "RELAUNCHED: $DEST (pid $(pgrep -x Tatakan))" || { echo "launch failed"; exit 1; }
