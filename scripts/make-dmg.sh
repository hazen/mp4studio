#!/bin/zsh
# Builds the app and packages it as build/MP4Studio-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/MP4Studio-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/MP4Studio.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "MP4Studio" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
