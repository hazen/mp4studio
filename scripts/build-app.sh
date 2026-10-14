#!/bin/zsh
# Builds MP4Studio.app (Apple silicon) into ./build. Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools' macOS 27 SDK needs Xcode's SwiftUI macro plugin; the 26.5 SDK doesn't.
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MP4Studio"

APP=build/MP4Studio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MP4Studio"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A local Resources/AppIcon.icns (not in git) wins; otherwise generate the default icon.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  if [[ ! -f build/DefaultIcon.icns ]]; then
    swift scripts/make-icon.swift build/DefaultIcon.iconset
    iconutil -c icns build/DefaultIcon.iconset -o build/DefaultIcon.icns
    rm -rf build/DefaultIcon.iconset
  fi
  cp build/DefaultIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MP4Studio"))"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/MP4Studio.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/MP4Studio.app"
fi
