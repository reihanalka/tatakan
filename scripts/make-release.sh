#!/bin/bash
# Build a Universal (Apple Silicon + Intel) Tatakan release and package it three ways:
#   dist/Tatakan-<ver>.pkg   double-click installer (recommended)
#   dist/Tatakan-<ver>.dmg   drag-to-Applications disk image
#   dist/Tatakan-<ver>.zip   plain app bundle (used by scripts/install.sh)
set -euo pipefail
export COPYFILE_DISABLE=1   # no ._ AppleDouble files in the payload
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Tatakan/Info.plist)
DIST="$ROOT/dist"
APP="$ROOT/Tatakan/build/Tatakan.app"
rm -rf "$DIST"; mkdir -p "$DIST"

echo "==> Building Tatakan $VER (universal, ad-hoc signed)"
UNIVERSAL=1 SIGN=- ./Tatakan/build.sh 2>&1 | grep -v -E "warning|DeprecatedDeclaration|^\s*[0-9]+ \||^\s*\||^\s*$" || true
[ -d "$APP" ] || { echo "build failed"; exit 1; }
lipo -info "$APP/Contents/MacOS/Tatakan"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# --- zip -------------------------------------------------------------------
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$DIST/Tatakan-$VER.zip"

# --- dmg -------------------------------------------------------------------
mkdir -p "$STAGE/dmg"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/dmg/Tatakan.app"
ln -s /Applications "$STAGE/dmg/Applications"
cp "$ROOT/installer/READ-ME-FIRST.txt" "$STAGE/dmg/READ ME FIRST.txt"
hdiutil create -volname "Tatakan $VER" -srcfolder "$STAGE/dmg" -fs HFS+ \
  -format UDZO -ov "$DIST/Tatakan-$VER.dmg" >/dev/null 2>&1

# --- pkg -------------------------------------------------------------------
mkdir -p "$STAGE/root/Applications"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/root/Applications/Tatakan.app"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/component.plist" >/dev/null
# Always install to /Applications, even if an older copy lives somewhere else.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$STAGE/component.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$STAGE/component.plist"
pkgbuild --root "$STAGE/root" \
  --component-plist "$STAGE/component.plist" \
  --scripts "$ROOT/installer/scripts" \
  --identifier com.reihan.tatakan.pkg \
  --version "$VER" \
  --install-location / \
  "$STAGE/Tatakan-component.pkg" >/dev/null
sed "s/__VERSION__/$VER/g" "$ROOT/installer/distribution.xml" > "$STAGE/distribution.xml"
productbuild --distribution "$STAGE/distribution.xml" \
  --resources "$ROOT/installer/resources" \
  --package-path "$STAGE" \
  "$DIST/Tatakan-$VER.pkg" >/dev/null

( cd "$DIST" && shasum -a 256 Tatakan-* > SHA256SUMS.txt )
echo "==> Done"
ls -lh "$DIST"
