#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift Tools/make-icon.swift "$WORK/icon.png"
mkdir "$WORK/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
