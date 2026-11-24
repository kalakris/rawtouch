#!/bin/bash
# Renders resources/RawTouch.icns from the SVG sources in resources/icon/.
#
#   ./scripts/make-icon.sh
#
# Two sources: RawTouch.svg is the full artwork; RawTouch-small.svg is the
# simplified version for the 16 px and 32 px slots (fewer, fatter frames —
# the full trail vanishes below about 2 px per dot). The .icns is committed,
# so only icon edits need this script (and its one dependency, rsvg-convert:
# `brew install librsvg`).
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/RawTouch.iconset"
mkdir -p "$SET"

render() {  # render <svg> <pixels> <iconset filename>
    rsvg-convert -w "$2" -h "$2" "resources/icon/$1" -o "$SET/$3"
}
render RawTouch-small.svg   16 icon_16x16.png
render RawTouch-small.svg   32 icon_16x16@2x.png
render RawTouch-small.svg   32 icon_32x32.png
render RawTouch.svg         64 icon_32x32@2x.png
render RawTouch.svg        128 icon_128x128.png
render RawTouch.svg        256 icon_128x128@2x.png
render RawTouch.svg        256 icon_256x256.png
render RawTouch.svg        512 icon_256x256@2x.png
render RawTouch.svg        512 icon_512x512.png
render RawTouch.svg       1024 icon_512x512@2x.png

iconutil --convert icns "$SET" --output resources/RawTouch.icns
echo "Wrote resources/RawTouch.icns"
