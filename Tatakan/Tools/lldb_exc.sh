#!/bin/bash
# Catch the Objective-C exception under lldb and print its reason + Swift-side backtrace.
#   Tools/lldb_exc.sh <demo args...>
cd "$(dirname "$0")/.."
F1="$(cd ..; pwd)/docs/screenshots/nook-home.png"; F2="$(cd ..; pwd)/Tatakan_Icon.svg"
pkill -x Tatakan 2>/dev/null; sleep 0.3
cat > build/lldb.cmds <<EOF
settings set auto-confirm true
breakpoint set -n objc_exception_throw
process launch -- --demo "$F1" "$F2" $*
expression -l objc -O -- (id)\$x0
bt 60
process kill
quit
EOF
lldb --batch -s build/lldb.cmds build/Tatakan.app/Contents/MacOS/Tatakan 2>&1 | tail -90
