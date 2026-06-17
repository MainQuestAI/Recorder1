#!/bin/bash
set -e

# Build & bundle the Recorder1 menu-bar app as a signed .app
# Run from the repo root.
#
# Signing identity: set CODESIGN_IDENTITY to a certificate name to
# sign with a stable identity — this keeps the app's Microphone / Audio-capture /
# Calendar TCC grants sticky across rebuilds. Defaults to "-" (ad-hoc), which
# works for unattended local builds. A local self-signed certificate can still
# trigger Keychain confirmation when the Mac is locked or the certificate is not
# trusted, so we only use it when explicitly requested.
#   CODESIGN_IDENTITY="Your Signing Identity" ./build.sh
#   CODESIGN_IDENTITY="Your Signing Identity" CODESIGN_KEYCHAIN="/path/to.keychain-db" ./build.sh

cd "$(dirname "$0")"

APP="Recorder1.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
else
    IDENTITY="-"
fi

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp ".build/release/Recorder" "$MACOS/Recorder"
cp "Info.plist" "$CONTENTS/Info.plist"

# App icon (built from assets/recorder1-logo.svg via make-icon.sh). Optional: skip if absent.
if [ -f "Recorder.icns" ]; then
    cp "Recorder.icns" "$RESOURCES/Recorder.icns"
else
    echo "    (no Recorder.icns — run ./make-icon.sh to generate it)"
fi

# PkgInfo: 4-char type + 4-char creator
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ "$IDENTITY" = "-" ]; then
    echo "==> codesign (ad-hoc, non-sandboxed entitlements)"
    SIGNING_OPTIONS=()
else
    echo "==> codesign (\"$IDENTITY\", non-sandboxed entitlements)"
    SIGNING_OPTIONS=(--options runtime)
fi
if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    SIGNING_OPTIONS+=(--keychain "$CODESIGN_KEYCHAIN")
fi
codesign --force "${SIGNING_OPTIONS[@]}" --sign "$IDENTITY" --entitlements "Recorder.entitlements" "$APP"

echo "done"
