#!/bin/bash
# Frame-by-frame capture of the Nook closing (tray tab): catches ghosting/shadow artifacts.
#   Tools/closecap.sh [tab]
cd "$(dirname "$0")/.."
OUT=build/closecap; rm -rf $OUT; mkdir -p $OUT
F1="$(cd ..; pwd)/docs/screenshots/nook-home.png"; F2="$(cd ..; pwd)/Tatakan_Icon.svg"
pkill -x Tatakan 2>/dev/null; sleep 0.4
build/Tatakan.app/Contents/MacOS/Tatakan --demo "$F1" "$F2" --nook "${1:-tray}" --autoclose 2.5 >/dev/null 2>&1 &
PID=$!
sleep ${DELAY:-1.5}
screencapture -x -v -V 5 -R480,0,840,300 $OUT/close.mov
kill $PID 2>/dev/null
ffmpeg -loglevel error -i $OUT/close.mov -vf "fps=30" $OUT/f%03d.png && ls $OUT | wc -l
