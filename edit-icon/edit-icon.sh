#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Install ZhenTo brand icons and wallpaper into an unpacked ISO root.
# Runs on the host against an explicit root path; never runs inside chroot
# and never ships in the final image.
#
# Usage:
#   sudo ./edit-icon.sh <unpacked-root-dir>   e.g. an unpacked ISO squashfs root
#
# Environment:
#   ICON_SRC_DIR   Brand source directory (default: <script-dir>/sources)
#                  Must contain zhento-short.png and zhento-full.png.

set -e

# switch to script dir, so relative paths always work
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

# target: unpacked root directory, required
root=${1:-}
if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "Usage: $0 <unpacked-root-dir>" >&2
    exit 2
fi

src_dir=${ICON_SRC_DIR:-"$PWD/sources"}
full="$src_dir/zhento-full.png"
short="$src_dir/zhento-short.png"

# Fail fast: verify every asset exists before writing anything, so a missing
# source never leaves a half-patched root tree.
for f in "$short" "$full"; do
    [ -f "$f" ] || {
        echo "Icon source not found: $f" >&2
        exit 1
    }
done
set -- files/pixmaps/*
if [ "$#" -eq 0 ] || [ ! -f "$1" ]; then
    echo "No generated icons in files/pixmaps/; run generate-icons.sh first" >&2
    exit 1
fi

pixmaps="$root/usr/share/pixmaps"
backgrounds="$root/usr/share/backgrounds"

mkdir -p "$pixmaps" "$backgrounds" || {
    echo "mkdir fail error!" >&2
    exit 1
}

# Replace only the brand slots; all other icons in the image stay untouched.
cp -f files/pixmaps/* "$pixmaps/" || {
    echo "copy pixmaps fail error!" >&2
    exit 1
}

# Add the full banner as a wallpaper; original wallpapers are left in place.
cp -f "$full" "$backgrounds/zhento.png" || {
    echo "copy wallpaper fail error!" >&2
    exit 1
}

echo "Done! Edit icons OK! -> $root"
