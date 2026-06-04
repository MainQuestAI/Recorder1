#!/bin/bash
set -e

# Build & bundle the Recorder menu-bar app as an ad-hoc-signed .app
# Run from the repo root.

cd "$(dirname "$0")"

APP="Recorder.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp ".build/release/Recorder" "$MACOS/Recorder"
cp "Info.plist" "$CONTENTS/Info.plist"

# PkgInfo: 4-char type + 4-char creator
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> codesign (ad-hoc, non-sandboxed entitlements)"
codesign --force --sign - --entitlements "Recorder.entitlements" "$APP"

echo "done"
