#!/bin/bash
# Regenerate the Windows icons from the same SVGs the Mac build uses (run on a Mac).
#   app.ico         colour logo on the #EAEAEA tile (same as the Mac app icon)
#   tray-dark.ico   white glyph for dark taskbars
#   tray-light.ico  black glyph for light taskbars
#   logo-*.png      in-app / installer artwork
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/windows/Tatakan/Assets"
TOOL="$ROOT/Tatakan/Tools/assettool"
[ -x "$TOOL" ] || swiftc -O "$ROOT/Tatakan/Tools/assettool.swift" -o "$TOOL"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

python3 - "$ROOT/Tatakan_Icon.svg" "$ROOT/Tatakan_Icon_2.svg" "$TMP" <<'PY'
import re, sys
app = open(sys.argv[1]).read()
app = re.sub(r'<rect[^>]*/>', '<rect width="1024" height="1024" fill="#eaeaea"/>', app, count=1)
open(sys.argv[3] + "/app.svg", "w").write(app)
mono = open(sys.argv[2]).read()
mono = re.sub(r'<rect[^>]*/>', '', mono)
mono = mono.replace('viewBox="0 0 1024 1024"', 'viewBox="168 168 688 688"')
open(sys.argv[3] + "/tray-light.svg", "w").write(re.sub(r'fill:\s*#[0-9a-fA-F]{3,6}', 'fill: #000000', mono))
open(sys.argv[3] + "/tray-dark.svg", "w").write(re.sub(r'fill:\s*#[0-9a-fA-F]{3,6}', 'fill: #ffffff', mono))
PY

for s in 16 20 24 32 40 48 64 256; do
  "$TOOL" render "$TMP/app.svg" "$TMP/app-$s.png" $s appicon >/dev/null
done
for v in light dark; do
  for s in 16 20 24 32 40 48 64; do
    "$TOOL" render "$TMP/tray-$v.svg" "$TMP/tray-$v-$s.png" $s >/dev/null
  done
done
"$TOOL" render "$TMP/app.svg" "$OUT/logo-256.png" 256 appicon >/dev/null

python3 - "$TMP" "$OUT" <<'PY'
import struct, sys, os
tmp, out = sys.argv[1], sys.argv[2]
def ico(name, sizes, dest):
    blobs = [open(f"{tmp}/{name}-{s}.png", "rb").read() for s in sizes]
    head = struct.pack("<HHH", 0, 1, len(sizes))
    off = 6 + 16 * len(sizes); dirs = b""
    for s, b in zip(sizes, blobs):
        dirs += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), off); off += len(b)
    open(dest, "wb").write(head + dirs + b"".join(blobs))
ico("app", [16, 20, 24, 32, 40, 48, 64, 256], f"{out}/app.ico")
ico("tray-light", [16, 20, 24, 32, 40, 48, 64], f"{out}/tray-light.ico")
ico("tray-dark", [16, 20, 24, 32, 40, 48, 64], f"{out}/tray-dark.ico")
PY

# Installer artwork (Inno Setup wants BMP): small 55px logo + 164x314 side panel.
INST="$ROOT/windows/installer"; mkdir -p "$INST"
"$TOOL" render "$TMP/app.svg" "$TMP/small.png" 110 appicon >/dev/null
python3 "$ROOT/windows/tools/png2bmp.py" "$TMP/small.png" "$INST/wizard-small.bmp" 255,255,255
python3 - "$TMP/app.svg" "$TMP/side.svg" <<'PY'
import sys, re
inner = open(sys.argv[1]).read()
inner = re.sub(r'<\?xml[^>]*\?>', '', inner)
inner = inner.replace('<svg ', '<svg x="22" y="97" width="120" height="120" ', 1)
inner = inner.replace('fill="#eaeaea"/>', 'fill="#eaeaea" rx="230"/>', 1)
# Square canvas (assettool renders squares); the 328-wide strip sits in the centre and gets cropped out.
side = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 628 628">
<g transform="translate(150 0)">
<rect width="328" height="628" fill="#161616"/>
<g transform="scale(2)">{inner}</g>
<rect x="48" y="560" width="48" height="8" rx="4" fill="#F07A42"/>
</g>
</svg>'''
open(sys.argv[2], "w").write(side)
PY
"$TOOL" render "$TMP/side.svg" "$TMP/side.png" 628 >/dev/null
sips -c 628 328 "$TMP/side.png" --out "$TMP/side-crop.png" >/dev/null
python3 "$ROOT/windows/tools/png2bmp.py" "$TMP/side-crop.png" "$INST/wizard-side.bmp" 22,22,22
echo "icons → $OUT"
