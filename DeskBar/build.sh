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
# Command Line Tools. Without it every @State fails to expand. So only when the
# active SDK is 27+ and the plugin isn't in any of the toolchain's plugin dirs,
# fall back to the newest pre-27 SDK installed alongside (the CLT keep older
# SDKs around); the deployment target is 13.0 so nothing is lost. Checking the
# known dirs directly keeps this instant — no walking all of Xcode.app.
SDK_ARGS=()
SDK_MAJOR="$(xcrun --show-sdk-version | cut -d. -f1)"
if (( SDK_MAJOR >= 27 )); then
    DEV_DIR="$(xcode-select -p)"
    SDK_PATH="$(xcrun --show-sdk-path)"
    HAVE_PLUGIN=0
    for dir in "$DEV_DIR/usr/lib/swift/host/plugins" \
               "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins" \
               "$DEV_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
               "$SDK_PATH/usr/lib/swift/host/plugins"; do
        if compgen -G "$dir/*SwiftUIMacros*" >/dev/null; then HAVE_PLUGIN=1; break; fi
    done
    if (( ! HAVE_PLUGIN )); then
        # Versioned SDKs only (MacOSX15.5.sdk, MacOSX26.sdk…), majors below 27.
        # Versions jumped 15 → 26, so compare numerically rather than by glob.
        FALLBACK_SDK="$(
            for sdk in "$(dirname "$SDK_PATH")"/MacOSX[0-9]*.sdk; do
                [[ -e "$sdk" ]] || continue
                v="${sdk##*/MacOSX}"; v="${v%.sdk}"
                if (( ${v%%.*} < 27 )); then printf '%s\t%s\n' "$v" "$sdk"; fi
            done | sort -V -k1,1 | tail -1 | cut -f2
        )"
        if [[ -n "$FALLBACK_SDK" ]]; then
            echo "SwiftUIMacros plugin not found — building against $(basename "$FALLBACK_SDK")"
            SDK_ARGS=(-sdk "$FALLBACK_SDK")
        else
            echo "warning: SwiftUIMacros plugin not found and no pre-27 SDK available;" >&2
            echo "         install full Xcode or an older Command Line Tools SDK." >&2
        fi
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
