#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://github.com/zitzhen/zhento-desktop-install
# OS-repository: https://github.com/zitzhen/zhento-desktop-install
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# 依赖脚本按自身所在目录定位，避免调用方 cwd 不是本目录时找不到
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Dependent projects
sh "$SCRIPT_DIR/curl.sh"

VERSION="1.0.0"
SNAP_FILE="ubuntu-desktop-bootstrap_${VERSION}-1-g21e8ae6a1_amd64.snap"
BASE_URL="https://github.com/zitzhen/zhento-desktop-install/releases/download/v${VERSION}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fL -o "$WORK_DIR/$SNAP_FILE" "$BASE_URL/$SNAP_FILE"
curl -fL -o "$WORK_DIR/$SNAP_FILE.sha256" "$BASE_URL/$SNAP_FILE.sha256"

(cd "$WORK_DIR" && sha256sum -c "$SNAP_FILE.sha256")

SNAP_NAME="ubuntu-desktop-bootstrap"

# snapd 正在运行（真实系统）：直接安装
if [ -S /run/snapd.socket ]; then
    if snap list "$SNAP_NAME" >/dev/null 2>&1; then
        snap remove "$SNAP_NAME"
    fi
    snap install --dangerous "$WORK_DIR/$SNAP_FILE"
    exit 0
fi

# chroot 内 snapd 未运行，且本地 --dangerous 的 snap 无法写 seed 预置：
# 把 snap 留在镜像里，首次开机由 systemd 单元安装，装完自动清理并自禁用
SNAP_STORE=/var/lib/zhento/snaps
UNIT=/etc/systemd/system/zhento-install-snap.service

install -d -m 0755 "$SNAP_STORE"
install -m 0644 "$WORK_DIR/$SNAP_FILE" "$SNAP_STORE/$SNAP_FILE"

cat > "$UNIT" <<EOS
[Unit]
Description=Install preinstalled snap: ${SNAP_NAME}
After=snapd.service
Wants=snapd.service
ConditionPathExists=${SNAP_STORE}/${SNAP_FILE}

[Service]
Type=oneshot
ExecStartPre=/usr/bin/snap wait system seed.loaded
ExecStart=/usr/bin/snap install --dangerous ${SNAP_STORE}/${SNAP_FILE}
ExecStartPost=/bin/rm -f ${SNAP_STORE}/${SNAP_FILE}

[Install]
WantedBy=multi-user.target
EOS

install -d /etc/systemd/system/multi-user.target.wants
ln -sf "$UNIT" /etc/systemd/system/multi-user.target.wants/zhento-install-snap.service
