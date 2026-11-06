#!/bin/zsh
# Builds the app and packages it as build/MP4Studio-<version>-<build>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
PLIST=build/MP4Studio.app/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
DMG="build/MP4Studio-$VERSION-$BUILD.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/MP4Studio.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "MP4Studio" "$STAGE" "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
