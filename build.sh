#!/bin/zsh
# Builds WattBar and assembles WattBar.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=WattBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/WattBar "$APP/Contents/MacOS/WattBar"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP — launch with: open $APP"
