#!/bin/zsh
# Packages build/NotchAgent.app into a distributable NotchAgent.dmg with a
# drag-to-Applications layout. Run build.sh first.
set -e
cd "$(dirname "$0")"

APP=build/NotchAgent.app
DMG=build/NotchAgent.dmg
STAGE=build/dmg-stage

[ -d "$APP" ] || { echo "error: $APP not found, run ./build.sh first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "NotchAgent" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"
echo "Built $DMG"
