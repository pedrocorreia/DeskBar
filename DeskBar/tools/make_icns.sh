#!/bin/bash
# Regenerate AppIcon.icns from make_icon.swift. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."   # → DeskBar/ (the app source dir)

TMP="$(mktemp -d)"
MASTER="$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "Rendering master 1024×1024…"
swift tools/make_icon.swift "$MASTER"

echo "Generating iconset sizes…"
render() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

echo "Packing .icns…"
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$TMP"
echo "wrote $(pwd)/AppIcon.icns"
