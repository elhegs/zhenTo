#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

# 用法：
#   sudo ./replace-grub.sh                 # 自动定位本机 /boot/grub/grub.cfg
#   sudo ./replace-grub.sh <目标grub.cfg>   # 指定目标（如解包后的 ISO 树）

set -e

# switch to script dir, so the relative grub.cfg path always works
cd "$(dirname "$0")" || exit 1

if [ ! -f grub.cfg ]; then
    echo "grub.cfg 404 exit" >&2
    exit 1
fi

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

# 目标：优先使用参数，否则自动探测本机 grub.cfg
if [ -n "${1:-}" ]; then
    target=$1
    if [ ! -f "$target" ]; then
        echo "目标不存在：$target" >&2
        exit 1
    fi
elif [ -f /boot/grub/grub.cfg ]; then
    target=/boot/grub/grub.cfg
elif [ -f /boot/grub2/grub.cfg ]; then
    target=/boot/grub2/grub.cfg
else
    echo "/boot/grub/grub.cfg 404 exit" >&2
    exit 1
fi

# 备份原文件，便于出错回滚
backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$target" "$backup" || { echo "backup fail error!" >&2; exit 1; }

cp -f grub.cfg "$target" || { echo "copy fail error!" >&2; exit 1; }
sync

echo "已备份：$backup"
echo "✅Done! Replace grub.cfg OK! -> $target"
