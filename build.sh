#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# install App
echo "==> Installing preinstalled applications..."

for app in install-app/*.sh; do
    echo "==> Running ${app}"
    sh "$app"
done

echo "==> All applications installed."