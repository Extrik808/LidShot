#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LidShot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LidShot "$APP/Contents/MacOS/LidShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="LidShot Local Signing"
if ! codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "Could not sign with \"$SIGN_ID\", using ad-hoc signature; screen-recording permission will reset on every build"
    codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LidShot || true
    rm -rf /Applications/LidShot.app
    cp -R "$APP" /Applications/
    open /Applications/LidShot.app
    echo "Installed to /Applications/LidShot.app"
else
    echo "Built $APP"
fi
