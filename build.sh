#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LidShot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LidShot "$APP/Contents/MacOS/LidShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LidShot || true
    rm -rf /Applications/LidShot.app
    cp -R "$APP" /Applications/
    open /Applications/LidShot.app
    echo "Installed to /Applications/LidShot.app"
else
    echo "Built $APP"
fi
