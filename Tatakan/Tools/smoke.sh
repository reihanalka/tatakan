#!/bin/bash
# Smoke test: every demo scenario must still be alive after N seconds (catches AppKit layout-loop crashes).
#   Tools/smoke.sh [seconds]
cd "$(dirname "$0")/.."
S=${1:-6}
for a in "--nook tray --drophover" "--nook home" "--nook cal" "--nook timer" "--nook notes" "--pair" "--activity"; do
  r=$(Tools/repro.sh "$S" $a 2>/dev/null | grep -E "ALIVE|DIED")
  echo "$a -> $r"
done
grep -iE "gradient stop|must be ordered" build/repro.log | head -3
