#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

copy_usr(){
    cp -f os-release /usr/lib/os-release || { echo "copy fail error!" >&2; exit 1; }
}

copy_etc(){
    cp -f os-release /etc/os-release || { echo "copy fail error!" >&2; exit 1; }
}

if [ ! -f /etc/os-release ]; then
    echo "/etc/os-release 404 exit" >&2
    exit 1
fi

if [ -L "/etc/os-release" ]; then
    copy_usr
else
    copy_etc
fi

echo "✅Done! Edit os-release OK!"