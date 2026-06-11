#!/bin/bash
set -e

# Build & bundle the Recorder menu-bar app as a signed .app
# Run from the repo root.
#
# Signing identity: set CODESIGN_IDENTITY to a certificate name (e.g.
# "Apple Development: you@example.com" or a "Developer ID Application: …") to
# sign with a stable identity — this keeps the app's Microphone / Audio-capture /
# Calendar TCC grants sticky across rebuilds. Defaults to "-" (ad-hoc), which
# works for a quick local build but re-prompts for permissions on every rebuild.
#   CODESIGN_IDENTITY="Apple Development: you@example.com" ./build.sh

cd "$(dirname "$0")"

APP="Recorder.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp ".build/release/Recorder" "$MACOS/Recorder"
cp "Info.plist" "$CONTENTS/Info.plist"

# App icon (built from icon.swift via make-icon.sh). Optional: skip if absent.
if [ -f "Recorder.icns" ]; then
    cp "Recorder.icns" "$RESOURCES/Recorder.icns"
else
    echo "    (no Recorder.icns — run ./make-icon.sh to generate it)"
fi

# PkgInfo: 4-char type + 4-char creator
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ "$IDENTITY" = "-" ]; then
    echo "==> codesign (ad-hoc, non-sandboxed entitlements)"
else
    echo "==> codesign (\"$IDENTITY\", non-sandboxed entitlements)"
fi
codesign --force --sign "$IDENTITY" --entitlements "Recorder.entitlements" "$APP"

echo "done"
