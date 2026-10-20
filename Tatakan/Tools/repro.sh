#!/bin/bash
# Run one demo scenario with stderr captured (exception reasons are redacted in the unified log).
#   Tools/repro.sh <seconds> <demo args...>
cd "$(dirname "$0")/.."
SECS=$1; shift
F1="$(cd ..; pwd)/docs/screenshots/nook-home.png"; F2="$(cd ..; pwd)/Tatakan_Icon.svg"
pkill -x Tatakan 2>/dev/null; sleep 0.3
build/Tatakan.app/Contents/MacOS/Tatakan --demo "$F1" "$F2" "$@" > build/repro.log 2>&1 &
PID=$!
for _ in $(seq 1 $((SECS*5))); do kill -0 $PID 2>/dev/null || break; sleep 0.2; done
if kill -0 $PID 2>/dev/null; then echo "ALIVE after ${SECS}s"; kill $PID; else echo "DIED"; fi
grep -v "^\s*$" build/repro.log | head -60
