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
    -framework UserNotifications -framework IOKit \
    -target arm64-apple-macos13.0

echo "Installing Info.plist…"
cp Info.plist "$APP/Contents/Info.plist"

echo "Installing app icon…"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# PkgInfo helps Launch Services recognise the bundle.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Ad-hoc signing…"
codesign --force --deep --sign - \
    --options runtime \
    "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "Done → $(pwd)/$APP"
echo "Launch with:  open \"$(pwd)/$APP\""

# Spotlight's search UI only surfaces apps living in /Applications,
# ~/Applications, or /System/Applications — a dev-folder build is indexed in
# the raw metadata DB (mdfind can see it) but filtered out of that UI. Pass
# --install to actually install the app so Spotlight picks it up.
if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/$APP"
    echo "Installing to $DEST …"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$DEST"
    mdimport "$DEST" 2>/dev/null || true
    echo "Installed → $DEST (should now appear in Spotlight)"
fi
