#!/usr/bin/env bash
# uninstall.sh — 卸载 app-misc/egpu-workaround（并可选移除 overlay 里的包目录）
set -eu

PN="egpu-workaround"
OVERLAY="${OVERLAY:-/var/db/repos/local}"
DEST="$OVERLAY/app-misc/$PN"

[ "$(id -u)" = "0" ] || { echo "uninstall: 需要 root" >&2; exit 1; }

echo ">> emerge -C app-misc/$PN"
emerge -C "app-misc/$PN" || true

if [ "${KEEP_OVERLAY:-0}" != "1" ] && [ -d "$DEST" ]; then
	echo ">> 移除 overlay 包目录 $DEST （KEEP_OVERLAY=1 可保留）"
	rm -rf "$DEST"
fi

echo "done.  /etc/egpu.conf 若被修改过会保留（CONFIG_PROTECT）。"
