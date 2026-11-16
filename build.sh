#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# ZhenTo ISO 构建脚本（UEFI-only，不再依赖 Cubic）
#
#   sudo ./build.sh              解包官方 ISO -> chroot 装 APP -> 重打包 -> 直出 ISO
#   sudo ./build.sh --apps-only  只执行 install-app/*.sh（chroot 内部或真实系统使用）
#
# 可用环境变量覆盖：
#   BASE_ISO      基础 ISO（默认 /home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso）
#   VERSION       版本号（默认 0.1.0）
#   VOLID         光盘卷标（默认 "ZhenTo <VERSION> amd64"）
#   WORK_DIR      中间产物目录（默认 <repo>/work，需约 35G 可用空间）
#   OUT_DIR       产物目录（默认 <repo>/out）
#   PATCH_LAYERS  auto 或空格分隔的 casper 层文件名
#   KEEP_WORK     1 保留中间产物，便于排查
#   SQUASHFS_COMP 重打包压缩算法（默认沿用原层，如 xz；改用 zstd 会快很多）
#   SQUASHFS_BLOCK 重打包块大小（默认沿用原层，通常 131072）
#
# 说明：Ubuntu 26.04 桌面盘使用分层 squashfs（casper/install-sources.yaml 描述）。
# 默认只改「默认安装源」的基底层，语言层和 enhanced-secureboot 覆盖层保持原样。

set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

BASE_ISO=${BASE_ISO:-/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso}
VERSION=${VERSION:-0.1.0}
VOLID=${VOLID:-"ZhenTo ${VERSION} amd64"}
WORK_DIR=${WORK_DIR:-"$SELF_DIR/work"}
OUT_DIR=${OUT_DIR:-"$SELF_DIR/out"}
PATCH_LAYERS=${PATCH_LAYERS:-auto}
KEEP_WORK=${KEEP_WORK:-0}
SQUASHFS_COMP=${SQUASHFS_COMP:-}
SQUASHFS_BLOCK=${SQUASHFS_BLOCK:-}

ISO_NAME="zhenTo-${VERSION}-amd64.iso"
ISO_DIR="$WORK_DIR/iso"
ROOT_DIR="$WORK_DIR/root"
EFI_IMG="$WORK_DIR/efi.img"

RESOLV_RESTORE=""

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'XX  %s\n' "$*" >&2; exit 1; }

human() {
    awk -v b="$1" 'BEGIN { printf "%.1fG", b / 1024 / 1024 / 1024 }'
}

# ---------------------------------------------------------------------------
# 预装 APP：在真实系统或 chroot 内执行 install-app/ 下的脚本
# ---------------------------------------------------------------------------
install_apps() {
    local app
    local found=0

    cd "$SELF_DIR"
    echo "==> Installing preinstalled applications..."

    for app in install-app/*.sh; do
        [ -e "$app" ] || continue
        found=1
        echo "==> Running ${app}"
        sh "$app"
    done

    [ "$found" -eq 1 ] || echo "==> install-app/ 下没有脚本"
    echo "==> All applications installed."
}

if [ "${1:-}" = "--apps-only" ]; then
    install_apps
    exit 0
fi

# ---------------------------------------------------------------------------
# 清理：卸载挂载点、恢复 resolv.conf
# ---------------------------------------------------------------------------
cleanup() {
    local m
    set +e
    if [ -d "$ROOT_DIR" ]; then
        for m in cdrom run sys proc dev/pts dev; do
            if mountpoint -q "$ROOT_DIR/$m" 2>/dev/null; then
                umount -R "$ROOT_DIR/$m" 2>/dev/null || umount -l "$ROOT_DIR/$m" 2>/dev/null
            fi
        done
        if [ -n "${RESOLV_RESTORE:-}" ]; then
            rm -f "$ROOT_DIR/etc/resolv.conf"
            ln -s "$RESOLV_RESTORE" "$ROOT_DIR/etc/resolv.conf" 2>/dev/null
            RESOLV_RESTORE=""
        fi
    fi
    set -e
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 读取 install-sources.yaml 中默认安装源的基底层
# ---------------------------------------------------------------------------
detect_default_layer() {
    awk '
        /^- default: true/  { def = 1; next }
        /^- default: false/ { def = 0; next }
        def && /^  path: /  { sub(/^  path: /, ""); print; exit }
    ' "$ISO_DIR/casper/install-sources.yaml"
}

# ---------------------------------------------------------------------------
# 往 chroot 里注入构建期使用的辅助命令（不会被带进最终镜像）
# ---------------------------------------------------------------------------
write_chroot_helpers() {
    local bin="$ROOT_DIR/opt/zhento-build/bin"
    install -d "$bin"

    cat > "$bin/zhento-flatpak" <<'EOS'
#!/bin/sh
# 构建期预装 flatpak 应用：zhento-flatpak <app-id> [...]
set -e
export DEBIAN_FRONTEND=noninteractive

command -v flatpak >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends flatpak ca-certificates
}

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

[ "$#" -gt 0 ] || { echo "用法: zhento-flatpak <app-id>..." >&2; exit 2; }

for id in "$@"; do
    flatpak install --system -y --noninteractive flathub "$id"
done
EOS

    cat > "$bin/zhento-snap" <<'EOS'
#!/bin/sh
# 构建期预置 snap：chroot 内没有运行 snapd，因此写 seed 而不是 snap install。
# 注意：只在镜像自带 seed.yaml 时可用，否则会报错退出。
set -e
export DEBIAN_FRONTEND=noninteractive

command -v snap >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends snapd
}

SEED=/var/lib/snapd/seed
CHANNEL=${SNAP_CHANNEL:-stable}

[ -f "$SEED/seed.yaml" ] || {
    echo "XX  镜像内没有 $SEED/seed.yaml，无法预置 snap；请改用 apt 或 flatpak" >&2
    exit 1
}

[ "$#" -gt 0 ] || { echo "用法: zhento-snap <snap-name>..." >&2; exit 2; }

for name in "$@"; do
    tmp=$(mktemp -d)
    (
        cd "$tmp"
        snap download "$name" --channel="$CHANNEL"
    )
    snapfile=$(ls "$tmp"/*.snap | head -n1)
    assertfile=$(ls "$tmp"/*.assert | head -n1)
    base=$(basename "$snapfile")

    install -m 0644 "$snapfile" "$SEED/snaps/$base"
    install -m 0644 "$assertfile" "$SEED/assertions/$(basename "$assertfile")"

    if grep -q "^  - name: ${name}$" "$SEED/seed.yaml"; then
        rm -rf "$tmp"
        continue
    fi

    entry=$(printf '  - name: %s\n    channel: %s\n    file: %s\n' "$name" "$CHANNEL" "$base")
    awk -v block="$entry" '
        /^[a-zA-Z]/ && !done { print block; done = 1 }
        { print }
        END { if (!done) print block }
    ' "$SEED/seed.yaml" > "$SEED/seed.yaml.new"
    mv "$SEED/seed.yaml.new" "$SEED/seed.yaml"

    rm -rf "$tmp"
done
EOS

    chmod 0755 "$bin/zhento-flatpak" "$bin/zhento-snap"
}

# ---------------------------------------------------------------------------
# 品牌信息：把 edit-os-release/ 注入 chroot 并执行，改写镜像的 os-release
# ---------------------------------------------------------------------------
apply_os_release() {
    local src="$SELF_DIR/edit-os-release"
    local dst=/opt/zhento-build/edit-os-release

    [ -d "$src" ] || { warn "缺少 edit-os-release/，跳过 os-release"; return 0; }

    log "写入 os-release"
    rm -rf "$ROOT_DIR$dst"
    cp -a "$src" "$ROOT_DIR$dst"
    chroot "$ROOT_DIR" /bin/sh "$dst/edit.sh" || die "写入 os-release 失败"
}

# ---------------------------------------------------------------------------
# 启动菜单：用 edit-grub/ 里的配置替换 ISO 树的 boot/grub/grub.cfg
# ---------------------------------------------------------------------------
apply_grub() {
    local src="$SELF_DIR/edit-grub"
    local dst="$ISO_DIR/boot/grub/grub.cfg"

    [ -f "$src/grub.cfg" ] || { warn "缺少 edit-grub/grub.cfg，跳过启动菜单"; return 0; }
    [ -f "$dst" ] || { warn "ISO 树里没有 boot/grub/grub.cfg，跳过启动菜单"; return 0; }

    log "替换启动菜单 grub.cfg"
    sh "$src/replace-grub.sh" "$dst" || die "替换 grub.cfg 失败"

    # 备份文件是给真实系统回滚用的，不能被打进 ISO
    rm -f "$dst".bak.*
}

# ---------------------------------------------------------------------------
# 处理单个 casper 层：解包 -> chroot 装 APP -> 重打包 -> 更新元数据
# ---------------------------------------------------------------------------
patch_layer() {
    local layer="$1"
    local sfs="$ISO_DIR/casper/$layer"
    local size_file="$ISO_DIR/casper/${layer%.squashfs}.size"
    local comp block old_size new_size avail need
    local -a env_args

    [ -f "$sfs" ] || die "找不到层文件：$sfs"

    comp=$(unsquashfs -s "$sfs" | awk '/^Compression /{print $2}')
    block=$(unsquashfs -s "$sfs" | awk '/^Block size /{print $3}')
    [ -n "$comp" ] && [ -n "$block" ] || die "无法读取 squashfs 参数：$sfs"
    comp=${SQUASHFS_COMP:-$comp}
    block=${SQUASHFS_BLOCK:-$block}

    # 空间检查：解包体积 + 新层（基础 ISO 已在磁盘上，不重复计入）
    need=$(( $(stat -c%s "$sfs") * 3 / 2 ))
    if [ -f "$size_file" ]; then
        need=$(( need + $(tr -d '\n' < "$size_file") ))
    fi
    avail=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4 * 1024}')
    if [ "$avail" -lt "$need" ]; then
        die "空间不足：$WORK_DIR 需要约 $(human "$need")，当前可用 $(human "$avail")。请把 WORK_DIR 指到大容量磁盘"
    fi

    log "解包 $layer（$comp / ${block} 块）"
    rm -rf "$ROOT_DIR"
    unsquashfs -no-progress -d "$ROOT_DIR" "$sfs" > /dev/null

    log "准备 chroot"
    install -d "$ROOT_DIR/opt/zhento-build" "$ROOT_DIR/dev" "$ROOT_DIR/dev/pts" \
        "$ROOT_DIR/proc" "$ROOT_DIR/sys" "$ROOT_DIR/run"
    cp -f "$SELF" "$ROOT_DIR/opt/zhento-build/build.sh"
    rm -rf "$ROOT_DIR/opt/zhento-build/install-app"
    cp -a "$SELF_DIR/install-app" "$ROOT_DIR/opt/zhento-build/install-app"
    write_chroot_helpers

    mount --bind /dev "$ROOT_DIR/dev"
    mount -t devpts devpts "$ROOT_DIR/dev/pts" 2>/dev/null || true
    mount --bind /proc "$ROOT_DIR/proc"
    mount --bind /sys "$ROOT_DIR/sys"
    mount -t tmpfs tmpfs "$ROOT_DIR/run"

    # 镜像自带 file:/cdrom 的 apt 源（离线安装仓库），chroot 里没有 /cdrom 会让
    # apt update 直接失败；把 ISO 树挂进去，既修好索引又能用上离线仓库
    if [ -d "$ISO_DIR/dists" ]; then
        install -d "$ROOT_DIR/cdrom"
        mount --bind "$ISO_DIR" "$ROOT_DIR/cdrom"
    fi

    # chroot 内的 resolv.conf 通常是 systemd-resolved 的软链，先换成真实文件
    if [ -L "$ROOT_DIR/etc/resolv.conf" ]; then
        RESOLV_RESTORE=$(readlink "$ROOT_DIR/etc/resolv.conf")
        rm -f "$ROOT_DIR/etc/resolv.conf"
    fi
    cp -f /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"

    # 防止 postinst 在 chroot 里启动服务
    printf '#!/bin/sh\nexit 101\n' > "$ROOT_DIR/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOT_DIR/usr/sbin/policy-rc.d"

    log "在 chroot 内执行 build.sh --apps-only"
    env_args=(
        HOME=/root
        TERM=dumb
        LC_ALL=C.UTF-8
        DEBIAN_FRONTEND=noninteractive
        PATH=/opt/zhento-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    )
    local v
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
        [ -n "${!v:-}" ] && env_args+=("$v=${!v}")
    done
    chroot "$ROOT_DIR" /usr/bin/env -i "${env_args[@]}" \
        /bin/bash /opt/zhento-build/build.sh --apps-only

    apply_os_release

    log "清理构建期痕迹"
    rm -rf "$ROOT_DIR/opt/zhento-build"
    rm -f "$ROOT_DIR/usr/sbin/policy-rc.d"
    rm -f "$ROOT_DIR"/var/cache/apt/archives/*.deb 2>/dev/null || true

    cleanup

    log "重打包 $layer"
    mksquashfs "$ROOT_DIR" "$WORK_DIR/$layer" \
        -comp "$comp" -b "$block" -noappend -no-progress -quiet
    mv -f "$WORK_DIR/$layer" "$sfs"

    # 更新层体积（casper 用它计算 overlay 需要的内存）
    if [ -f "$size_file" ]; then
        old_size=$(tr -d '\n' < "$size_file")
        new_size=$(du -sb "$ROOT_DIR" | cut -f1)
        printf '%s\n' "$new_size" > "$size_file"
        sed -i "s/^  size: ${old_size}$/  size: ${new_size}/" \
            "$ISO_DIR/casper/install-sources.yaml"
    fi

    rm -rf "$ROOT_DIR"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    local layer start end interval report need avail
    local -a layer_list

    [ "$(id -u)" -eq 0 ] || die "需要 root 权限（chroot / mount）：sudo $0"
    for c in xorriso unsquashfs mksquashfs rsync dd awk; do
        command -v "$c" > /dev/null || die "缺少命令：$c"
    done
    [ -f "$BASE_ISO" ] || die "找不到基础 ISO：$BASE_ISO"

    mkdir -p "$OUT_DIR"
    rm -rf "$WORK_DIR"
    mkdir -p "$ISO_DIR"

    log "解包 ISO 树到 $ISO_DIR"
    xorriso -osirrox on:auto_chmod_on -indev "$BASE_ISO" -extract / "$ISO_DIR" > /dev/null

    [ -f "$ISO_DIR/casper/install-sources.yaml" ] || \
        die "该 ISO 没有 casper/install-sources.yaml，不是受支持的 Ubuntu 桌面镜像"

    # 取出 UEFI 启动用的 FAT 分区（原盘是“追加分区”，不是 efi.img 文件）
    log "提取 EFI 启动分区"
    report=$(LC_ALL=C xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null)
    interval=$(printf '%s\n' "$report" \
        | sed -n "s/.*--interval:local_fs:\([0-9][0-9]*\)d-\([0-9][0-9]*\)d.*/\1 \2/p" \
        | head -n1)
    [ -n "$interval" ] || die "无法从基础 ISO 解析 EFI 分区位置"
    start=${interval% *}
    end=${interval#* }
    dd if="$BASE_ISO" of="$EFI_IMG" bs=512 skip="$start" \
        count=$((end - start + 1)) status=none
    [ -s "$EFI_IMG" ] || die "EFI 分区提取失败"

    # 选择要改的层
    if [ "$PATCH_LAYERS" = "auto" ]; then
        layer=$(detect_default_layer)
        [ -n "$layer" ] || die "无法从 install-sources.yaml 确定默认安装源"
        layer_list=("$layer")
    else
        read -r -a layer_list <<< "$PATCH_LAYERS"
    fi

    log "待修改层：${layer_list[*]}"
    warn "只处理上述基底层；语言层与 enhanced-secureboot 覆盖层保持官方原样"
    warn "casper/*.manifest 未重新生成（仅影响安装器的包统计，不影响安装结果）"

    for layer in "${layer_list[@]}"; do
        patch_layer "$layer"
    done

    apply_grub

    # boot.catalog 由 xorriso 重新生成，删掉 ISO 树里的旧文件，避免 md5 记录过期内容
    rm -f "$ISO_DIR/boot.catalog"

    log "重建 md5sum.txt"
    (
        cd "$ISO_DIR"
        find . -type f ! -name md5sum.txt -print0 \
            | sort -z \
            | xargs -0 md5sum > md5sum.txt
    )

    need=$(( $(du -sb "$ISO_DIR" | cut -f1) * 105 / 100 ))
    avail=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4 * 1024}')
    [ "$avail" -ge "$need" ] || \
        die "输出目录空间不足：需要约 $(human "$need")，可用 $(human "$avail")"

    log "生成 UEFI-only ISO：$ISO_NAME"
    rm -f "$OUT_DIR/$ISO_NAME"
    xorriso -as mkisofs \
        -r -V "$VOLID" -J -joliet-long -l -iso-level 3 \
        -partition_offset 16 \
        --protective-msdos-label \
        -append_partition 2 0xef "$EFI_IMG" \
        -appended_part_as_gpt \
        -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
        -o "$OUT_DIR/$ISO_NAME" "$ISO_DIR"

    (
        cd "$OUT_DIR"
        md5sum "$ISO_NAME" > "zhenTo-${VERSION}-amd64.md5"
    )

    log "完成"
    printf '  ISO : %s (%s)\n' "$OUT_DIR/$ISO_NAME" "$(human "$(stat -c%s "$OUT_DIR/$ISO_NAME")")"
    printf '  MD5 : %s\n' "$OUT_DIR/zhenTo-${VERSION}-amd64.md5"
    xorriso -indev "$OUT_DIR/$ISO_NAME" -report_el_torito plain 2>/dev/null \
        | grep 'El Torito boot img' || true

    if [ "$KEEP_WORK" = "1" ]; then
        log "保留中间产物：$WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}

main "$@"
