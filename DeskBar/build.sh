#!/bin/bash
# Build DeskBar.app from source using swiftc (no full Xcode required — Command
# Line Tools are enough). Produces a menu-bar .app bundle, ad-hoc signed so
# macOS remembers the Bluetooth permission.
set -euo pipefail
cd "$(dirname "$0")"

APP="DeskBar.app"
BIN="$APP/Contents/MacOS/DeskBar"

echo "Cleaning previous build…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Swift sources…"
swiftc -O \
    -o "$BIN" \
    Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Carbon \
    -target arm64-apple-macos13.0

echo "Installing Info.plist…"
cp Info.plist "$APP/Contents/Info.plist"
# PkgInfo helps Launch Services recognise the bundle.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Ad-hoc signing…"
codesign --force --deep --sign - \
    --options runtime \
    "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "Done → $(pwd)/$APP"
echo "Launch with:  open \"$(pwd)/$APP\""
