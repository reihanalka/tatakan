#!/bin/bash
# Build Tatakan.app without Xcode (Command Line Tools only).
# Icons are regenerated from ../Tatakan_Icon.svg + ../Tatakan_Icon_2.svg on every build.
#
#   ./build.sh                 build for this Mac's CPU, local signing identity if present
#   UNIVERSAL=1 ./build.sh     Apple Silicon + Intel in one app (used for releases)
#   SIGN=- ./build.sh          force ad-hoc signing (used for releases)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Tatakan.app
LOGO="../Tatakan_Icon.svg"
LOGO_MONO="../Tatakan_Icon_2.svg"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCHS="arm64 x86_64"
else
  ARCHS="$(uname -m)"
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Resources/Icons"

# --- asset tool (host CPU only, used at build time) ------------------------
if [ ! -x Tools/assettool ] || [ Tools/assettool.swift -nt Tools/assettool ]; then
  swiftc -O Tools/assettool.swift -o Tools/assettool
fi

# --- icons -----------------------------------------------------------------
# App icon  : ../Tatakan_Icon.svg   (colour) on Puteran's #EAEAEA tile, macOS icon grid.
# Menu bar  : ../Tatakan_Icon_2.svg (mono)   → black template glyph, cropped tight like Puteran.
TMP=$(mktemp -d)
python3 - "$LOGO" "$LOGO_MONO" "$TMP/appicon.svg" "$TMP/menubar.svg" <<'PY'
import re, sys
app = open(sys.argv[1]).read()
app = re.sub(r'<rect[^>]*/>', '<rect width="1024" height="1024" fill="#eaeaea"/>', app, count=1)
open(sys.argv[3], "w").write(app)
mono = open(sys.argv[2]).read()
mono = re.sub(r'<rect[^>]*/>', '', mono)                                  # drop white background
mono = re.sub(r'fill:\s*#[0-9a-fA-F]{3,6}', 'fill: #000000', mono)       # template = solid black
mono = mono.replace('viewBox="0 0 1024 1024"', 'viewBox="168 168 688 688"')  # crop to the glyph
open(sys.argv[4], "w").write(mono)
PY
ISET="$TMP/AppIcon.iconset"; mkdir -p "$ISET"
for s in 16 32 128 256 512; do
  Tools/assettool render "$TMP/appicon.svg" "$ISET/icon_${s}x${s}.png" $s appicon >/dev/null
  Tools/assettool render "$TMP/appicon.svg" "$ISET/icon_${s}x${s}@2x.png" $((s*2)) appicon >/dev/null
done
iconutil -c icns "$ISET" -o Resources/AppIcon.icns
cp "$TMP/menubar.svg" Resources/Icons/menubar.svg
Tools/assettool render Resources/Icons/menubar.svg Resources/Icons/menubar.png 36 >/dev/null

# --- compile ---------------------------------------------------------------
SLICES=()
ARCH_FLAGS=()
for a in $ARCHS; do
  swiftc -O -swift-version 5 -target "$a-apple-macos14.0" \
    -o "$TMP/Tatakan-$a" Sources/*.swift
  SLICES+=("$TMP/Tatakan-$a")
  ARCH_FLAGS+=(-arch "$a")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Tatakan"

cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Fonts/*.ttf Resources/Fonts/*.txt "$APP/Contents/Resources/Fonts/"
cp Resources/Icons/menubar.png "$APP/Contents/Resources/Icons/"
# Now-playing adapter (loaded by Apple's /usr/bin/perl, which macOS still lets read MediaRemote).
clang -dynamiclib -fobjc-arc -O2 "${ARCH_FLAGS[@]}" -framework Foundation \
  Resources/MediaAdapter.m -o "$APP/Contents/Resources/libTatakanMedia.dylib"
rm -rf "$TMP"

# --- sign ------------------------------------------------------------------
# Default: reuse the stable local identity (keeps macOS permissions across rebuilds).
IDENT="${SIGN:-Puteran Local Signing}"
if [ "$IDENT" != "-" ] && security find-identity -p codesigning | grep -q "$IDENT"; then
  codesign --force --deep -s "$IDENT" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign -v "$APP"
echo "BUILD OK ($ARCHS): $(pwd)/$APP"
