#!/bin/bash
set -e

# Render the Recorder1 SVG logo and bundle it into Recorder.icns.
#
# Recorder.icns is committed so regular builds do not need SVG tooling. Run this
# script only when the source logo changes.

cd "$(dirname "$0")"

SOURCE="assets/recorder1-logo.svg"
MASTER="Recorder-1024.png"
SET="Recorder.iconset"

if [ ! -f "$SOURCE" ]; then
    echo "missing $SOURCE" >&2
    exit 1
fi

echo "==> rendering $MASTER from $SOURCE"
if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$SOURCE" -o "$MASTER"
elif command -v magick >/dev/null 2>&1; then
    magick "$SOURCE" -resize 1024x1024 "$MASTER"
elif command -v convert >/dev/null 2>&1; then
    convert "$SOURCE" -resize 1024x1024 "$MASTER"
else
    echo "install librsvg or ImageMagick to regenerate Recorder.icns" >&2
    exit 1
fi

echo "==> building $SET"
rm -rf "$SET"
mkdir "$SET"
sips -z 16  16   "$MASTER" --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32  32   "$MASTER" --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32  32   "$MASTER" --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64  64   "$MASTER" --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128  "$MASTER" --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256 256  "$MASTER" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256 256  "$MASTER" --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512 512  "$MASTER" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512 512  "$MASTER" --out "$SET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o Recorder.icns
echo "==> wrote Recorder.icns"
