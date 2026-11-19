#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Maintenance tool: regenerate the pre-generated brand icons in files/pixmaps/
# from the source images in sources/. Not called by build.sh.
#
# Usage:
#   ./generate-icons.sh          # regenerate files/pixmaps/* from sources/*
#
# Requires ImageMagick (convert). Run this only when the brand assets change,
# then commit the generated files/pixmaps/* into git.

set -e

# switch to script dir, so all relative paths are stable
cd "$(dirname "$0")" || exit 1

command -v convert >/dev/null 2>&1 || {
    echo "ImageMagick convert is required to regenerate icons" >&2
    exit 1
}
command -v base64 >/dev/null 2>&1 || {
    echo "base64 is required to regenerate SVG icons" >&2
    exit 1
}
command -v file >/dev/null 2>&1 || {
    echo "file is required to verify generated icons" >&2
    exit 1
}

short=sources/zhento-short.png
full=sources/zhento-full.png
out=files/pixmaps

for src in "$short" "$full"; do
    [ -f "$src" ] || {
        echo "Source image not found: $src" >&2
        exit 1
    }
done
mkdir -p "$out"

# Create a valid SVG that embeds a small PNG via a base64 data URI.
# $1=output.svg  $2=embedded.png  $3=width  $4=height  $5=viewBox
svg_from_png() {
    _svg=$1
    _png=$2
    _w=$3
    _h=$4
    _vb=$5
    _b64=$(base64 "$_png" | tr -d '\n')
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%s" height="%s" viewBox="%s" preserveAspectRatio="xMidYMid meet"><image width="100%%" height="100%%" xlink:href="data:image/png;base64,%s"/></svg>\n' \
        "$_w" "$_h" "$_vb" "$_b64" >"$_svg"
}

# -- short icon (548x545 RGBA, near-square) ---------------------------------
# debian-logo.png: keep transparency, pad to a square so it never distorts
convert "$short" -resize 48x48 -background none -gravity center -extent 48x48 \
    "$out/debian-logo.png"

# debian-logo.bmp: BMP has no alpha, flatten onto white
convert "$short" -resize 48x48 -background white -gravity center -extent 48x48 \
    -flatten -type truecolor "$out/debian-logo.bmp"

# Temporary workspace for intermediate thumbnails: keep it outside the repo so
# regenerating never leaves stray files in files/pixmaps/.
WORKTMP=$(mktemp -d)
trap 'rm -rf "$WORKTMP"' EXIT

# 32x32 thumbnail embedded in ubuntu-logo.svg
convert "$short" -resize 32x32 -background none -gravity center -extent 32x32 \
    "$WORKTMP/embed-short.png"

# -- full banner (1774x887 RGB, 2:1) ----------------------------------------
# Text logo slot is 187x72 in the original theme; 187x94 keeps the 2:1 ratio
# instead of squashing the handwritten lettering.
convert "$full" -resize 187x94 "$out/ubuntu-logo-text.png"
cp -f "$out/ubuntu-logo-text.png" "$out/ubuntu-logo-text-dark.png"

# -- SVG slots (valid SVG with embedded PNG, never raw PNG bytes) ------------
svg_from_png "$out/ubuntu-logo.svg"            "$WORKTMP/embed-short.png"    32 32  '0 0 32 32'
svg_from_png "$out/ubuntu-logo-text.svg"       "$out/ubuntu-logo-text.png"  187 94 '0 0 1774 887'
svg_from_png "$out/ubuntu-logo-text-dark.svg"  "$out/ubuntu-logo-text.png"  187 94 '0 0 1774 887'

# -- verify formats ---------------------------------------------------------
for f in "$out"/*; do
    file "$f"
done

echo "Done! Regenerated icons in $out"
