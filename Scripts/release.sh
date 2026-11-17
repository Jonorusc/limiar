#!/bin/bash
# Packages build/Limiar.app into a zip and a drag-to-Applications dmg.
# Usage: Scripts/release.sh <version>   (called by `make release`)
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
BUILD="build"
APP="$BUILD/Limiar.app"
ZIP="$BUILD/Limiar-$VERSION.zip"
DMG="$BUILD/Limiar-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"

[[ -d "$APP" ]] || { echo "Missing $APP. Run 'make app' first." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Limiar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Limiar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

shasum -a 256 "$ZIP" "$DMG"
echo "Release artifacts ready in $BUILD/"
