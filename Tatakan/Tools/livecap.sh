#!/bin/bash
# Live visual QA: launch the built app in demo mode and screen-capture the glass + glow states.
#   Tools/livecap.sh [outdir]      (needs Screen Recording permission for the calling terminal)
# Glass/glow are window-server effects; ImageRenderer snapshots can't show them, so this is the check.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/livecap}"; mkdir -p "$OUT"; rm -f "$OUT"/*.png
BIN=build/Tatakan.app/Contents/MacOS/Tatakan
F1="$(cd ..; pwd)/docs/screenshots/nook-home.png"
F2="$(cd ..; pwd)/Tatakan_Icon.svg"
pkill -x Tatakan 2>/dev/null; sleep 0.3
# one file per display (main first); the Nook lives on the notch display
cap() { screencapture -x "$OUT/$1-d1.png" "$OUT/$1-d2.png"; }

"$BIN" --demo "$F1" "$F2" --nook home >/dev/null 2>&1 &
PID=$!
sleep 1.55; cap nook-burst-a
sleep 0.35; cap nook-burst-b
sleep 3;    cap nook-settled
kill $PID 2>/dev/null; sleep 0.6

"$BIN" --demo "$F1" "$F2" --nook tray --drophover >/dev/null 2>&1 &
PID=$!
sleep 3; cap nook-drophover
kill $PID 2>/dev/null; sleep 0.6

"$BIN" --demo "$F1" "$F2" --activity >/dev/null 2>&1 &
PID=$!
sleep 1.6; cap island-activity
kill $PID 2>/dev/null; sleep 0.6

"$BIN" --demo "$F1" "$F2" --pair >/dev/null 2>&1 &
PID=$!
sleep 0.4; cap shelf-burst
sleep 3;   cap shelf-settled
kill $PID 2>/dev/null
ls "$OUT"
