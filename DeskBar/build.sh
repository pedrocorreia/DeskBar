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

# From the macOS 27 SDK on, SwiftUI's @State is a macro backed by the
# SwiftUIMacros compiler plugin — which ships with Xcode but NOT with the
# Command Line Tools. Without it every @State fails to expand. If the plugin
# is missing, fall back to the newest pre-27 SDK installed alongside (the CLT
# keep older SDKs around); the deployment target is 13.0 so nothing is lost.
SDK_ARGS=()
DEV_DIR="$(xcode-select -p)"
if [[ -z "$(find "$DEV_DIR" -path '*host/plugins/*SwiftUIMacros*' -print -quit 2>/dev/null)" ]]; then
    SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
    FALLBACK_SDK="$(ls -d "$SDK_DIR"/MacOSX2[0-6]*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$FALLBACK_SDK" ]]; then
        echo "SwiftUIMacros plugin not found — building against $(basename "$FALLBACK_SDK")"
        SDK_ARGS=(-sdk "$FALLBACK_SDK")
    else
        echo "warning: SwiftUIMacros plugin not found and no pre-27 SDK available;" >&2
        echo "         install full Xcode or an older Command Line Tools SDK." >&2
    fi
fi

echo "Compiling Swift sources…"
swiftc -O \
    ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} \
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
